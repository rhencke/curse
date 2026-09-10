-- Persistent compiled-artifact cache: the spine that makes curse worth it for
-- repeated workloads (make builds, boot, anything that runs the same scripts
-- over and over). Keyed by a CONTENT hash of the script bytes — not the path —
-- so the same script at two paths shares one artifact, a changed script is
-- automatically a new key (no invalidation dance), and `make`'s `sh -c '…'`
-- (which has no file at all) caches fine.
--
-- What we cache is the EMITTED LUA SOURCE (emit.lua's output), which is portable
-- and cheap to (re)generate. We deliberately do NOT cache LuaJIT machine-code
-- traces — stock LuaJIT can't persist them — so a one-shot process still pays
-- interpreter speed on the cached Lua; the win there is skipping parse+emit.
-- (The real speed for high-count short invocations comes later from a warm
-- daemon whose forked workers inherit traces via CoW — see README/roadmap.)
--
-- HARD INVARIANT: the cache is an optimization. ANY failure in it — no space
-- (ENOSPC), read-only fs (EROFS, e.g. early boot before /var is rw), no perms,
-- a corrupt or version-mismatched artifact — must fall back to running, never
-- fail execution. Every fs op here is best-effort and swallows its error.
local ffi = require("ffi")
local bit = require("bit")

local P = require("parser")
local E = require("emit")
local I = require("interp")

local M = {}

ffi.cdef [[
  int mkdir(const char *path, unsigned int mode);
  int open(const char *path, int flags, unsigned int mode);
  int flock(int fd, int operation);
  int close(int fd);
]]
local C = ffi.C
local O_CREAT, O_RDWR = 64, 2   -- Linux x86-64 values
local LOCK_EX, LOCK_NB = 2, 4

-- Artifact validity is scoped to the exact toolchain: the curse emitter version,
-- the LuaJIT version, and the arch. A mismatch just lands in a different dir, so
-- old entries become clean misses (and get LRU'd later) instead of miscompiling.
M.CURSE_VERSION = "0.1"
local stamp = ("curse%s-%s-%s"):format(M.CURSE_VERSION,
  (jit and jit.version or _VERSION):gsub("%s+", ""), (jit and jit.arch or "?"))
M.stamp = stamp

-- FNV-1a 64-bit over the raw bytes (fast, non-cryptographic). Fine for a per-uid
-- cache; a shared/root-owned prewarm cache that crosses a trust boundary should
-- move to a crypto hash to resist deliberate collisions.
local u64 = ffi.typeof("uint64_t")
local FNV_OFFSET = u64(14695981039346656037ULL)
local FNV_PRIME = u64(1099511628211ULL)
function M.hash(s)
  local p = ffi.cast("const uint8_t*", s)
  local h = FNV_OFFSET
  for i = 0, #s - 1 do
    h = bit.bxor(h, u64(p[i])) * FNV_PRIME
  end
  local hi = tonumber(bit.band(bit.rshift(h, 32), 0xffffffffULL))
  local lo = tonumber(bit.band(h, 0xffffffffULL))
  return ("%08x%08x"):format(hi, lo)
end

-- Cache root: $XDG_CACHE_HOME/curse or ~/.cache/curse, then the stamp subdir.
-- Returns nil if we can't even name a home (→ caller runs without caching).
local function cache_root()
  local base = os.getenv("XDG_CACHE_HOME")
  if not base or base == "" then
    local home = os.getenv("HOME")
    if not home or home == "" then return nil end
    base = home .. "/.cache"
  end
  return base .. "/curse"
end

-- mkdir each path component 0700 (own the subtree; ignore EEXIST and any error —
-- if the dir can't be made, store() will simply fail and we run uncached).
local function mkdirs(path)
  local acc = ""
  for part in path:gmatch("[^/]+") do
    acc = acc .. "/" .. part
    C.mkdir(acc, 448) -- 0700; returns -1/EEXIST on an existing dir, which is fine
  end
end

-- Absolute artifact path for a source string, or nil if uncacheable.
function M.artifact_path(src)
  local root = cache_root()
  if not root then return nil end
  return root .. "/" .. stamp .. "/" .. M.hash(src) .. ".lua"
end

-- Load a cached artifact into a module { run, loopPc, stmtPc }, or nil on any
-- problem (absent, unreadable, corrupt, wrong version → won't `load`). Safe.
function M.load(path)
  if not path then return nil end
  local chunk = loadfile(path)
  if not chunk then return nil end
  local ok, mod = pcall(chunk)
  if ok and type(mod) == "table" and mod.run then return mod end
  return nil
end

-- Publish `code` at `path` atomically, guarded so concurrent curse processes
-- don't both compile the same script. Best-effort: returns true on publish,
-- false on anything (lock held elsewhere, disk full, read-only fs, …).
function M.store(path, code)
  if not path then return false end
  local dir = path:match("^(.*)/[^/]+$")
  mkdirs(dir)
  -- flock a per-artifact lockfile. flock is tied to the open file description and
  -- released by the kernel on process death, so a crashed compiler leaves no
  -- stale lock. LOCK_NB: if someone else holds it, they're compiling — we bail.
  local lockfd = C.open(path .. ".lock", O_CREAT + O_RDWR, 384) -- 0600
  if lockfd < 0 then return false end
  local locked = C.flock(lockfd, LOCK_EX + LOCK_NB) == 0
  if not locked then C.close(lockfd); return false end
  -- double-checked: someone may have finished between our load() miss and here.
  local ok = false
  local f = io.open(path, "r")
  if f then
    f:close(); ok = true -- already published; nothing to do
  else
    -- temp MUST be in the same dir as `path` (rename is atomic only within a
    -- filesystem); we hold the exclusive lock, so the fd alone makes it unique.
    local tmp = path .. ".tmp." .. tostring(lockfd)
    local o = io.open(tmp, "w")
    if o then
      local wrote = o:write(code)
      o:close()
      if wrote then ok = os.rename(tmp, path) and true or false end
      if not ok then os.remove(tmp) end
    end
  end
  C.flock(lockfd, 8) -- LOCK_UN (also released on close, but be explicit)
  C.close(lockfd)
  return ok
end

-- Run `src` against `sh`, using the cache. Returns (sh, how) where how is one of
-- "warm" (ran a cached artifact), "cold" (compiled fresh, then cached), or
-- "interp" (the compiler couldn't handle it — ran the tree-walker). Never fails
-- for a cache reason.
function M.run(src, sh)
  local path = M.artifact_path(src)

  local mod = M.load(path)          -- warm hit: skip parse AND emit
  if mod then
    mod.run(sh, nil)
    return sh, "warm"
  end

  -- Cold: parse + emit in-process (cheap — emit is pure string building). If the
  -- emitter can't handle this script, fall back to the interpreter (the oracle).
  local ok, code = pcall(function() return E.emit(P.parse(src)) end)
  if ok then
    local chunk, lerr = load(code, "=curse:compiled")
    if chunk then
      local built, m = pcall(chunk)
      if built and type(m) == "table" and m.run then
        M.store(path, code)          -- populate for next time (best-effort)
        m.run(sh, nil)
        return sh, "cold"
      end
    end
  end

  I.run(sh, P.parse(src))            -- fallback: always correct
  return sh, "interp"
end

return M
