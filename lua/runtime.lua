-- curse LuaJIT runtime: the shared `sh` shell state that BOTH the interpreter
-- and the transpiled (compiled) code mutate. Because they share one table, the
-- tier handoff transfers no state — the compiled code just keeps using `sh`.
--
-- Integer arithmetic is 64-bit two's-complement via LuaJIT int64 cdata (FFI),
-- the exact analogue of curse's JS BigInt + asIntN(64): overflow wraps like
-- bash, and LuaJIT sinks the cdata boxing inside hot traces so it costs nothing.
local ffi = require("ffi")
local i64 = ffi.typeof("int64_t")

local M = {}
M.i64 = i64

local Shell = {}
Shell.__index = Shell
M.Shell = Shell

local seeded = false
function Shell.new()
  if not seeded then math.randomseed(os.time() + tonumber(ffi.C.getpid and ffi.C.getpid() or 0)); seeded = true end
  local sh = setmetatable({
    vars = {},       -- name -> { s = string?, n = int64? }  (lazy: fill on demand)
    status = 0,      -- $?
    argv0 = "bash",  -- $0 (set by the CLI/daemon to the script/shell name)
    start_time = os.time(), -- for $SECONDS
    opt_e = false,   -- set -e (errexit)
    opt_u = false,   -- set -u (nounset)
    opt_pipefail = false,
    aliases = {},    -- name -> replacement text (alias builtin)
    shopt = {},      -- shopt option name -> bool (expand_aliases, nullglob, …)
    traps = {},      -- canonical signal name (EXIT, SIGINT, …) -> handler string
    noerr = 0,       -- >0 = errexit suppressed (inside a condition / negation)
    params = {},     -- positional $1..
    out = io.write,  -- stdout sink (swappable for capture)
    forstate = {},   -- loop id -> { list = {strings}, idx } for `for x in`; kept
                     -- in `sh` so a mid-loop OSR resumes the SAME expansion+index
    functions = {},  -- name -> AST body (interpreter); the compiled module has
                     -- its own closures
    -- Function-call plumbing with NO per-call allocation: positional args go into
    -- a per-depth POOL array (reused across calls at that depth), the count is
    -- tracked explicitly (nparams), and the save-stacks reuse their slots.
    params = {},     -- current $@ array (may be an oversized pool array)
    nparams = 0,     -- current $# (params[1..nparams] are live)
    pd = 0,          -- call/param depth
    paramstack = {}, -- saved `params` per depth
    npstack = {},    -- saved `nparams` per depth
    argpool = {},    -- reusable args array per depth
    savedstack = {}, -- `local`-shadow record per depth (false until a local shadows)
    calldepth = 0,   -- interpreter-only OSR gate (managed at the interp call site)
  }, Shell)
  sh:import_env()
  return sh
end

-- positional parameters ($# is read directly as sh.nparams). $0 is the script/
-- shell name (not a positional; not affected by set/shift).
function Shell:param(n)
  if n == 0 then return self.argv0 or "bash" end
  return (n <= self.nparams) and self.params[n] or ""
end
function Shell:paramsJoin(sep) return table.concat(self.params, sep or " ", 1, self.nparams) end

-- Positional-only call boundary: push args (varargs) into the depth pool — no
-- table allocation per call after warmup.
function Shell:pushParams(...)
  local d = self.pd + 1; self.pd = d
  self.paramstack[d] = self.params
  self.npstack[d] = self.nparams
  local a = self.argpool[d]; if not a then a = {}; self.argpool[d] = a end
  local n = select("#", ...)
  for i = 1, n do a[i] = (select(i, ...)) end
  self.params = a; self.nparams = n
end
function Shell:popParams()
  local d = self.pd; self.pd = d - 1
  self.params = self.paramstack[d]; self.nparams = self.npstack[d]
end

-- Full call boundary (functions that use `local`): params pool + a lazy shadow
-- record (allocated only if a `local` actually shadows something).
function Shell:pushCall(...)
  self:pushParams(...)
  self.savedstack[self.pd] = false
end
function Shell:popCall()
  local d = self.pd
  local saved = self.savedstack[d]
  if saved then
    for name, old in pairs(saved) do self.vars[name] = old or nil end -- false => was absent
    self.savedstack[d] = false
  end
  self:popParams()
end
-- `local name`: shadow the variable within the current call frame (restored on
-- return). Records the prior box once so it can be put back.
function Shell:localVar(name)
  local d = self.pd
  local saved = self.savedstack[d]
  if not saved then saved = {}; self.savedstack[d] = saved end
  if saved[name] == nil then saved[name] = self.vars[name] or false end
  self.vars[name] = {}
end

-- one `local` operand: `name` or `name=value` (value already expanded).
function Shell:localAssign(arg)
  local nm, val = arg:match("^([%a_][%w_]*)=(.*)$")
  if nm then self:localVar(nm); self:set_str(nm, val) else self:localVar(arg) end
end

-- Split on default-IFS whitespace (no empty fields), for unquoted `$var` in a
-- `for x in $list` word list. (Custom IFS comes with the fuller word engine.)
function Shell:split(s)
  local out = {}
  for w in s:gmatch("%S+") do out[#out + 1] = w end
  return out
end

-- Bash-correct standalone IFS split (for `read`): whitespace-IFS runs collapse and
-- trim edges; each non-whitespace-IFS char delimits (empty fields allowed), with a
-- trailing delimiter not adding a trailing empty.
function M.ifs_split(ifs, s)
  local fields, cur = {}, nil
  local function isws(c) return c == " " or c == "\t" or c == "\n" end
  local function inifs(c) return c ~= "" and ifs:find(c, 1, true) ~= nil end
  local function brk() if cur ~= nil then fields[#fields + 1] = cur; cur = nil end end
  local i, n = 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if inifs(c) then
      if isws(c) then
        if cur ~= nil then brk() end
        i = i + 1; while i <= n and isws(s:sub(i, i)) do i = i + 1 end
        if i <= n and inifs(s:sub(i, i)) and not isws(s:sub(i, i)) then
          i = i + 1; while i <= n and isws(s:sub(i, i)) do i = i + 1 end
        end
      else
        if cur == nil then cur = "" end; brk()
        i = i + 1; while i <= n and isws(s:sub(i, i)) do i = i + 1 end
      end
    else cur = (cur or "") .. c; i = i + 1 end
  end
  brk()
  return fields
end

-- Run an external command via posix_spawnp + waitpid (FFI/libc directly — NOT
-- /bin/sh, which would recurse when curse IS /bin/sh, and would lose signal
-- info). We use posix_spawn rather than a manual fork+execvp so spawning from a
-- big/warm heap (the daemon) doesn't pay a page-table copy: glibc routes it
-- through CLONE_VM|CLONE_VFORK, so it's ~as cheap from a fat process as a tiny
-- one. argv... are already-expanded strings. stdout is captured through a pipe
-- and written to sh.out (so it composes with $(...) capture); $? is the exact
-- exit status, or 128+signum when killed by a signal — like bash. (stderr is
-- inherited for now; redirection via file_actions comes with the fd model.)
local ffi = require("ffi")
local bit = require("bit")
ffi.cdef [[
  typedef int32_t curse_pid_t;
  int posix_spawnp(curse_pid_t *pid, const char *file, const void *file_actions,
                   const void *attrp, char *const argv[], char *const envp[]);
  int posix_spawn_file_actions_init(void *fa);
  int posix_spawn_file_actions_destroy(void *fa);
  int posix_spawn_file_actions_adddup2(void *fa, int fd, int newfd);
  int posix_spawn_file_actions_addclose(void *fa, int fd);
  int waitpid(int pid, int *wstatus, int options);
  int pipe(int fildes[2]);
  int close(int fd);
  long read(int fd, void *buf, unsigned long count);
  extern char **environ;
]]
local C = ffi.C

function Shell:exec(...)
  local args = { ... }
  local n = #args
  if n == 0 or args[1] == "" then self.status = 127; return end
  local argv = ffi.new("const char*[?]", n + 1)
  local anchor = {} -- keep the Lua strings alive while argv points into them
  for i = 1, n do anchor[i] = tostring(args[i]); argv[i - 1] = anchor[i] end
  argv[n] = nil
  local fds = ffi.new("int[2]")
  if C.pipe(fds) ~= 0 then self.status = 127; return end
  local rfd, wfd = fds[0], fds[1]
  -- opaque posix_spawn_file_actions_t (~80B on glibc; over-allocate to be safe):
  -- dup the pipe's write end onto the child's stdout, and close its read end.
  local fa = ffi.new("uint8_t[1024]")
  C.posix_spawn_file_actions_init(fa)
  C.posix_spawn_file_actions_adddup2(fa, wfd, 1)
  C.posix_spawn_file_actions_addclose(fa, rfd)
  local pidp = ffi.new("curse_pid_t[1]")
  local rc = C.posix_spawnp(pidp, args[1], fa, nil, ffi.cast("char *const *", argv), C.environ)
  C.posix_spawn_file_actions_destroy(fa)
  C.close(wfd)
  if rc ~= 0 then C.close(rfd); self.status = 127; return end -- e.g. ENOENT
  local buf = ffi.new("char[65536]")
  local chunks = {}
  while true do
    local nr = C.read(rfd, buf, 65536)
    if nr <= 0 then break end
    chunks[#chunks + 1] = ffi.string(buf, nr)
  end
  C.close(rfd)
  local st = ffi.new("int[1]")
  C.waitpid(pidp[0], st, 0)
  local s = st[0]
  local sig = bit.band(s, 0x7f)
  if sig ~= 0 and sig ~= 0x7f then
    self.status = 128 + sig                       -- killed by a signal
  else
    self.status = bit.rshift(bit.band(s, 0xff00), 8) -- WEXITSTATUS
  end
  local out = table.concat(chunks)
  if out ~= "" then self.out(out) end
end

-- Command substitution `$(...)`: run the inner program capturing stdout, with
-- trailing newlines stripped (bash). Interpreted (it's I/O-bound, not hot), so
-- it handles builtins, externals, and (in interp mode) functions uniformly.
function Shell:capture_src(src)
  local P = require("parser")
  local I = require("interp")
  local ast = P.parse(src)
  local buf = {}
  local saved = self.out
  self.out = function(x) buf[#buf + 1] = x end
  local ok, err = pcall(I.run, self, ast)
  self.out = saved
  if not ok then error(err) end
  return (table.concat(buf):gsub("\n+$", ""))
end

-- A variable box holds a string value and/or a cached int64. An arithmetic
-- write stores only the int64 (s = nil) and defers stringification until a
-- string context reads it — this is the per-iteration allocation curse's JS
-- runtime also learned to avoid.
local function box(name, vars)
  local b = vars[name]
  if b == nil then b = {}; vars[name] = b end
  return b
end

-- Parse a bash-ish scalar string to int64 (leading integer, else 0). bash's
-- real recursive/base rules come later; the arith-loop subset only needs this.
local function str_to_i64(s)
  if s == nil or s == "" then return i64(0) end
  local sign, digits = s:match("^%s*([%-+]?)(%d+)")
  if digits == nil then return i64(0) end
  local n = i64(0)
  for i = 1, #digits do n = n * 10LL + i64(digits:byte(i) - 48) end
  if sign == "-" then n = -n end
  return n
end
M.str_to_i64 = str_to_i64

-- Arithmetic numeric literal / value: like str_to_i64 but with bash arith bases —
-- base#digits (2-64), 0x/0X hex, leading-0 octal. Used ONLY in arithmetic
-- contexts ($(( )), arith var reads); `test` stays decimal (str_to_i64).
local function digit_val(ch)
  local b = ch:byte()
  if b >= 48 and b <= 57 then return b - 48 end        -- 0-9
  if b >= 97 and b <= 122 then return b - 97 + 10 end  -- a-z -> 10..35
  if b >= 65 and b <= 90 then return b - 65 + 10 end   -- A-Z -> 10..35 (base<=36)
  return nil
end
local function arith_num(s)
  if s == nil or s == "" then return i64(0) end
  s = s:match("^%s*(.-)%s*$")
  local sign = 1
  if s:sub(1, 1) == "-" then sign = -1; s = s:sub(2) elseif s:sub(1, 1) == "+" then s = s:sub(2) end
  local base, digits = 10, nil
  local b, d = s:match("^(%d+)#(.+)$")
  if b then base = tonumber(b); digits = d
  elseif s:sub(1, 2):lower() == "0x" then base = 16; digits = s:sub(3)
  elseif s:sub(1, 1) == "0" and s:match("^0[0-7]+$") then base = 8; digits = s:sub(2)
  else digits = s:match("^%d+") or "" end
  if digits == "" or base < 2 or base > 64 then return sign < 0 and -str_to_i64(s) or str_to_i64(s) end
  local n, B = i64(0), i64(base)
  for k = 1, #digits do
    local dv = digit_val(digits:sub(k, k))
    if not dv or dv >= base then break end
    n = n * B + i64(dv)
  end
  return sign < 0 and -n or n
end
M.arith_num = arith_num

-- int64 integer power (** operator), shared by interp and compiled.
function M.ipow(base, exp)
  local r, n = i64(1), tonumber(exp)
  for _ = 1, n do r = r * base end
  return r
end

-- int64 -> decimal string with no cdata "LL" suffix (what bash would print).
local function i64_to_str(n)
  return (tostring(n):gsub("LL$", ""))
end
M.i64_to_str = i64_to_str

-- Dynamic special variables (only when not explicitly set). Many spec cases just
-- check these "look like" a PID/uid/path, so exact values rarely matter.
ffi.cdef [[
  int getpid(void); int getppid(void); int getuid(void); int geteuid(void);
  char *getcwd(char *buf, unsigned long size);
]]
local scratch = ffi.new("char[4096]")
local pid_cache
function Shell:pid() if not pid_cache then pid_cache = tonumber(ffi.C.getpid()) end return pid_cache end
function Shell:special_get(name)
  if name == "RANDOM" then return tostring(math.random(0, 32767)) end
  if name == "PWD" then local p = ffi.C.getcwd(scratch, 4096); return p ~= nil and ffi.string(p) or "" end
  if name == "PPID" then return tostring(tonumber(ffi.C.getppid())) end
  if name == "UID" then return tostring(tonumber(ffi.C.getuid())) end
  if name == "EUID" then return tostring(tonumber(ffi.C.geteuid())) end
  if name == "BASHPID" then return tostring(self:pid()) end
  if name == "OSTYPE" then return "linux-gnu" end
  if name == "MACHTYPE" then return "x86_64-pc-linux-gnu" end
  if name == "HOSTTYPE" then return "x86_64" end
  if name == "SECONDS" then return tostring(os.time() - (self.start_time or os.time())) end
  if name == "LINENO" then return tostring(self.cur_line or 0) end
  return ""
end

-- Follow nameref (declare -n) chains to the effective variable name. A nameref
-- box has b.ref set and b.s holding the target's name (possibly with a subscript,
-- which is stripped here — element namerefs resolve to the base array).
function Shell:deref(name)
  for _ = 1, 100 do
    local b = self.vars[name]
    if not b or not b.ref or b.s == nil or b.s == "" then return name end
    local t = b.s
    local br = t:find("[", 1, true)
    name = br and t:sub(1, br - 1) or t
    if name == "" then return t end
  end
  return name
end
-- Mark `name` as a nameref (declare -n); target is the referenced variable name.
function Shell:make_nameref(name, target)
  local b = box(name, self.vars); b.ref = true
  if target ~= nil then b.s = target; b.n = nil; b.arr = nil end
end
function Shell:unref(name) local b = self.vars[name]; if b then b.ref = nil end end
function Shell:is_nameref(name) local b = self.vars[name]; return b and b.ref end

-- String value of a var (materialize from the cached int64 if needed).
function Shell:get(name)
  name = self:deref(name)
  local b = self.vars[name]
  if b == nil then return self:special_get(name) end
  if b.arr then return b.arr[0] or "" end -- $a == ${a[0]}
  if b.s == nil then
    if b.n == nil then return "" end
    b.s = i64_to_str(b.n)
  end
  return b.s
end

-- int64 value of a var for arithmetic (use the cache, else parse the string).
function Shell:aget(name)
  name = self:deref(name)
  local b = self.vars[name]
  if b == nil then return i64(0) end
  if b.n == nil then b.n = M.arith_num(b.s) end -- arith context: honor bases (0x, 010, N#)
  return b.n
end

function Shell:set_str(name, s)
  local b = box(self:deref(name), self.vars)
  b.s = s; b.n = nil
end

-- Inherit the process environment as shell variables (bash does this at startup).
-- PWD/OLDPWD stay dynamic (special_get uses getcwd) so they don't go stale on cd.
function Shell:import_env()
  local e = ffi.C.environ
  if e == nil then return end
  local i = 0
  while e[i] ~= nil do
    local s = ffi.string(e[i])
    local eq = s:find("=", 1, true)
    if eq then
      local k = s:sub(1, eq - 1)
      if k:match("^[%a_][%w_]*$") and k ~= "PWD" and k ~= "OLDPWD" then
        self:set_str(k, s:sub(eq + 1))
      end
    end
    i = i + 1
  end
end

-- Arithmetic write: store the int64, defer the string (lazy).
function Shell:aset(name, n)
  local b = box(self:deref(name), self.vars)
  b.n = i64(n); b.s = nil
  return b.n
end

-- ---- indexed arrays ----
-- Stored in the var box as b.arr = { [0]=…, [1]=… } (0-based, may be sparse, to
-- match bash). A plain scalar has no b.arr; reading $a is ${a[0]}.
local function arr_max(arr) local m = -1; for k in pairs(arr) do if k > m then m = k end end; return m end

-- `declare -A name`: mark as associative (string keys, insertion-order iteration —
-- note: real bash iterates in hash order; insertion order matches the common cases).
function Shell:declare_assoc(name)
  local b = box(self:deref(name), self.vars); b.assoc = true; b.arr = b.arr or {}; b.order = b.order or {}
  b.s = nil; b.n = nil
end
function Shell:is_assoc(name) local b = self.vars[self:deref(name)]; return b and b.assoc end

function Shell:array_assign(name, values, append)
  local b = box(self:deref(name), self.vars)
  if append and b.arr then
    local base = arr_max(b.arr) + 1
    for i = 1, #values do b.arr[base + i - 1] = values[i] end
  else
    b.arr = {}; b.s = nil; b.n = nil
    for i = 1, #values do b.arr[i - 1] = values[i] end
  end
end
-- Negative indexed subscripts count from the highest set index (bash: a[-1] is
-- the last element). Assoc keys (strings) are used as-is.
local function norm_key(b, key)
  if type(key) == "number" and key < 0 and not (b and b.assoc) then
    return (b and b.arr and arr_max(b.arr) or -1) + 1 + key
  end
  return key
end
function Shell:array_set(name, key, val, append)
  local b = box(self:deref(name), self.vars)
  if not b.arr then b.arr = {}; if b.s then b.arr[0] = b.s end; b.s = nil; b.n = nil end
  key = norm_key(b, key)
  if type(key) == "number" and key < 0 then return end -- out-of-bounds negative: bash rejects
  if b.assoc and b.arr[key] == nil then b.order[#b.order + 1] = key end
  if append then b.arr[key] = (b.arr[key] or "") .. val else b.arr[key] = val end
end
function Shell:array_get(name, key)
  local b = self.vars[self:deref(name)]
  if b and b.arr then return b.arr[norm_key(b, key)] or "" end
  if key == 0 then return self:get(name) end
  return ""
end
-- Sorted variable names beginning with `pfx` (for ${!pfx@} / ${!pfx*}).
function Shell:var_prefix_names(pfx)
  local t = {}
  for k in pairs(self.vars) do if k:sub(1, #pfx) == pfx then t[#t + 1] = k end end
  table.sort(t)
  return t
end
-- Is element [key] set? (distinct from "" — for [[ -v a[k] ]]).
function Shell:is_elem_set(name, key)
  local b = self.vars[self:deref(name)]
  if not b then return false end
  if b.arr then return b.arr[norm_key(b, key)] ~= nil end
  return key == 0 and (b.s ~= nil or b.n ~= nil)
end
-- unset a single element a[key] (negative allowed for indexed).
function Shell:array_unset(name, key)
  local b = self.vars[self:deref(name)]
  if b and b.arr then b.arr[norm_key(b, key)] = nil end
end
-- bash iterates an assoc array in HASH-TABLE order, not insertion order: the
-- key's FNV-1 32-bit hash (over its bytes) picks one of 1024 buckets, buckets are
-- walked ascending, and within a bucket the most-recently-inserted key comes
-- first (bash prepends to the chain). Reproduced exactly (ported from the TS
-- backend) so ${!m[@]} / ${m[@]} match bash. int64 keeps the 32-bit multiply
-- exact (a plain Lua double would lose precision past 2^53).
local FNV32_OFFSET, FNV32_PRIME, U32 = i64(2166136261), i64(16777619), i64(4294967296)
local function assoc_bucket(key)
  local h = FNV32_OFFSET
  for j = 1, #key do
    h = (h * FNV32_PRIME) % U32       -- FNV-1: multiply first…
    h = bit.bxor(h, i64(key:byte(j))) -- …then xor the byte
  end
  return tonumber(h % i64(1024))
end

function Shell:array_indices(name)
  local b = self.vars[self:deref(name)]
  if b and b.assoc then
    local live = {}
    for idx, k in ipairs(b.order) do
      if b.arr[k] ~= nil then live[#live + 1] = { k = k, i = idx, bkt = assoc_bucket(k) } end
    end
    table.sort(live, function(a, z)
      if a.bkt ~= z.bkt then return a.bkt < z.bkt else return a.i > z.i end
    end)
    local t = {}; for _, e in ipairs(live) do t[#t + 1] = e.k end
    return t
  end
  if b and b.arr then
    local t = {}; for k in pairs(b.arr) do t[#t + 1] = k end; table.sort(t); return t
  end
  if b and (b.s ~= nil or b.n ~= nil) then return { 0 } end
  return {}
end
function Shell:array_values(name)
  local idx = self:array_indices(name); local t = {}
  for i = 1, #idx do t[i] = self:array_get(name, idx[i]) end
  return t
end
function Shell:array_count(name) return #self:array_indices(name) end

-- ---- parameter expansion ${var OP arg} ----
-- Convert a shell glob to a Lua pattern fragment (for #/%/// operators). Handles
-- * ? and [..]/[!..]; escapes Lua-magic chars elsewhere.
local function glob_to_lpat(glob)
  local out, i = {}, 1
  while i <= #glob do
    local c = glob:sub(i, i)
    if c == "*" then out[#out + 1] = ".*"
    elseif c == "?" then out[#out + 1] = "."
    elseif c == "[" then
      local j = i + 1; local neg = false
      if glob:sub(j, j) == "!" or glob:sub(j, j) == "^" then neg = true; j = j + 1 end
      local cls = {}
      while j <= #glob and glob:sub(j, j) ~= "]" do cls[#cls + 1] = glob:sub(j, j); j = j + 1 end
      out[#out + 1] = "[" .. (neg and "^" or "") .. table.concat(cls) .. "]"
      i = j
    elseif c:match("[%(%)%.%%%+%-%^%$%]]") then out[#out + 1] = "%" .. c
    else out[#out + 1] = c end
    i = i + 1
  end
  return table.concat(out)
end
local function strip_prefix(val, glob, longest)
  local lp = "^" .. glob_to_lpat(glob) .. "$"
  if longest then
    for k = #val, 0, -1 do if val:sub(1, k):match(lp) then return val:sub(k + 1) end end
  else
    for k = 0, #val do if val:sub(1, k):match(lp) then return val:sub(k + 1) end end
  end
  return val
end
local function strip_suffix(val, glob, longest)
  local lp = "^" .. glob_to_lpat(glob) .. "$"
  if longest then
    for k = 1, #val + 1 do if val:sub(k):match(lp) then return val:sub(1, k - 1) end end
  else
    for k = #val + 1, 1, -1 do if val:sub(k):match(lp) then return val:sub(1, k - 1) end end
  end
  return val
end
local function subst(val, glob, repl, all)
  local lp = glob_to_lpat(glob)
  repl = repl:gsub("%%", "%%%%") -- literal repl
  if all then return (val:gsub(lp, repl)) end
  local s, e = val:find(lp)
  if s then return val:sub(1, s - 1) .. repl .. val:sub(e + 1) end
  return val
end
local function substr(val, off, len)
  local o = tonumber(off) or 0
  if o < 0 then o = #val + o end
  if o < 0 then o = 0 end
  local s = val:sub(o + 1)
  if len and len ~= "" then
    local l = tonumber(len) or 0
    if l < 0 then s = s:sub(1, #s + l) else s = s:sub(1, l) end
  end
  return s
end

-- ---- real regex via libc POSIX regcomp/regexec (for case globs, =~, and
-- pathname/glob expansion) — a real engine, unlike Lua patterns. ----
ffi.cdef [[
  int regcomp(void *preg, const char *regex, int cflags);
  int regexec(const void *preg, const char *s, unsigned long nmatch, void *pmatch, int eflags);
  void regfree(void *preg);
  void *opendir(const char *name);
  void *readdir(void *dirp);
  int closedir(void *dirp);
]]
local REG_EXTENDED, REG_NOSUB = 1, 8
local regbuf = ffi.new("char[512]") -- opaque regex_t (glibc ~64B; over-allocate)

-- Convert a shell glob to a POSIX ERE, anchored. Char classes carry over (with
-- [!..] -> [^..]); regex-special chars elsewhere are escaped.
-- Split `body` on top-level `|` (respecting nested parens) — extglob arms.
local function split_arms(body)
  local arms, depth, start = {}, 0, 1
  for k = 1, #body do
    local ch = body:sub(k, k)
    if ch == "(" then depth = depth + 1
    elseif ch == ")" then depth = depth - 1
    elseif ch == "|" and depth == 0 then arms[#arms + 1] = body:sub(start, k - 1); start = k + 1 end
  end
  arms[#arms + 1] = body:sub(start)
  return arms
end
-- Convert a glob (incl. extglob ?(..) *(..) +(..) @(..) !(..)) to an ERE body.
local EXTOP = { ["?"] = true, ["*"] = true, ["+"] = true, ["@"] = true, ["!"] = true }
local function glob_conv(glob)
  local out, i, n = {}, 1, #glob
  while i <= n do
    local c = glob:sub(i, i)
    if EXTOP[c] and glob:sub(i + 1, i + 1) == "(" then
      local d, j = 1, i + 2
      while j <= n and d > 0 do
        local cc = glob:sub(j, j)
        if cc == "(" then d = d + 1 elseif cc == ")" then d = d - 1; if d == 0 then break end end
        j = j + 1
      end
      local arms = split_arms(glob:sub(i + 2, j - 1))
      local conv = {}
      for _, a in ipairs(arms) do conv[#conv + 1] = glob_conv(a) end
      local group = "(" .. table.concat(conv, "|") .. ")"
      -- @ = exactly one; ? = 0/1; * = 0+; + = 1+; ! ≈ group (POSIX ERE can't negate)
      out[#out + 1] = (c == "?" and group .. "?") or (c == "*" and group .. "*")
        or (c == "+" and group .. "+") or group
      i = j + 1
    elseif c == "*" then out[#out + 1] = ".*"; i = i + 1
    elseif c == "?" then out[#out + 1] = "."; i = i + 1
    elseif c == "[" then
      local j, cls = i + 1, { "[" }
      if glob:sub(j, j) == "!" then cls[#cls + 1] = "^"; j = j + 1
      elseif glob:sub(j, j) == "^" then cls[#cls + 1] = "^"; j = j + 1 end
      while j <= n and glob:sub(j, j) ~= "]" do cls[#cls + 1] = glob:sub(j, j); j = j + 1 end
      cls[#cls + 1] = "]"; out[#out + 1] = table.concat(cls); i = j + 1
    elseif c:match("[%.%+%(%)%{%}%|%^%$\\]") then out[#out + 1] = "\\" .. c; i = i + 1
    else out[#out + 1] = c; i = i + 1 end
  end
  return table.concat(out)
end
local function glob_to_ere(glob)
  return "^" .. glob_conv(glob) .. "$"
end

-- Match `s` against a POSIX ERE. `anchored_glob` false = raw ERE (=~), true = a
-- glob already converted to an anchored ERE. Returns boolean.
function M.regex_match(s, ere)
  if ffi.C.regcomp(regbuf, ere, REG_EXTENDED + REG_NOSUB) ~= 0 then return false end
  local rc = ffi.C.regexec(regbuf, s, 0, nil, 0)
  ffi.C.regfree(regbuf)
  return rc == 0
end

-- Full (anchored) shell-glob match, for `case` patterns.
function M.glob_match(s, glob)
  return M.regex_match(s, glob_to_ere(glob))
end

-- Pathname (glob) expansion: return the sorted matching paths for `pattern`, or
-- nil if none (bash default: the word stays literal). Supports an optional
-- literal directory prefix (dir/*.c, /etc/*.conf); a glob in the directory part
-- (multi-level like */*.c) is not expanded (returns nil -> literal).
function M.glob_expand(pattern)
  local sl = pattern:find("/[^/]*$")
  local dirpart = sl and pattern:sub(1, sl) or ""
  local filepat = sl and pattern:sub(sl + 1) or pattern
  if dirpart:find("[*?%[]") then return nil end
  if not (filepat:find("[*?%[]") or filepat:find("[?*+@!]%(")) then return nil end
  local scan = dirpart == "" and "." or dirpart
  local d = ffi.C.opendir(scan); if d == nil then return nil end
  local ere = glob_to_ere(filepat)
  if ffi.C.regcomp(regbuf, ere, REG_EXTENDED + REG_NOSUB) ~= 0 then ffi.C.closedir(d); return nil end
  local hidden = filepat:sub(1, 1) == "."
  local matches = {}
  while true do
    local e = ffi.C.readdir(d); if e == nil then break end
    local name = ffi.string(ffi.cast("const char *", e) + 19) -- d_name @ 19 (glibc x86-64)
    if name ~= "." and name ~= ".." and (name:sub(1, 1) ~= "." or hidden) then
      if ffi.C.regexec(regbuf, name, 0, nil, 0) == 0 then matches[#matches + 1] = dirpart .. name end
    end
  end
  ffi.C.regfree(regbuf); ffi.C.closedir(d)
  if #matches == 0 then return nil end
  table.sort(matches)
  return matches
end

-- Apply a ${…} operator. `arg`/`arg2` are already word-expanded by the caller;
-- `idxnum` is the evaluated numeric subscript when pe.index is an expression.
function Shell:expand_param(pe, arg, arg2, idxnum)
  local name, op, index = pe.name, pe.op, pe.index
  -- ${!a[@]} / ${!a[*]}: the list of set indices
  if op == "indices" then
    local idx = self:array_indices(name)
    return table.concat(idx, " ")
  end
  if op == "prefix" then return table.concat(self:var_prefix_names(name), " ") end
  -- ${!name}: indirect. For a nameref, bash INVERTS this to yield the target NAME;
  -- otherwise it's the value of the variable named by $name.
  if op == "indirect" then
    local b = self.vars[name]
    if b and b.ref and b.s then return b.s end
    local target = idxnum and self:array_get(name, idxnum) or self:get(name)
    target = target:gsub("%[.*$", "") -- plain-var target (subscript targets rare)
    if target == "" then return "" end
    if target == "@" or target == "*" then return self:paramsJoin(" ") end
    if target:match("^%d+$") then return self:param(tonumber(target)) end
    if target == "?" then return tostring(self.status) end
    return self:get(target)
  end
  local val, isset
  if index == "@" or index == "*" then
    if op == "len" then return tostring(self:array_count(name)) end -- ${#a[@]}
    val = table.concat(self:array_values(name), " "); isset = self:array_count(name) > 0
  elseif index then
    val = self:array_get(name, idxnum or 0); isset = val ~= ""
  elseif name:match("^%d+$") then
    local nn = tonumber(name); val = self:param(nn); isset = (nn <= self.nparams)
  elseif name == "@" or name == "*" then
    val = self:paramsJoin(" "); isset = self.nparams > 0
  else
    isset = self.vars[self:deref(name)] ~= nil; val = self:get(name)
  end
  arg = arg or ""
  -- set -u (nounset): a bare reference to an unset variable errors and exits. The
  -- unset-handling ops (:- - :+ + := = :? ?) and $@/$* are exempt.
  if self.opt_u and not isset and not (name == "@" or name == "*")
    and index ~= "@" and index ~= "*"
    and op ~= ":-" and op ~= "-" and op ~= ":+" and op ~= "+"
    and op ~= ":=" and op ~= "=" and op ~= ":?" and op ~= "?"
    and self:special_get(name) == "" then
    io.stderr:write("curse: " .. name .. ": unbound variable\n"); error({ __curse_exit = 1 })
  end
  if op == "len" then return tostring(#val) end
  if op == ":-" then return val ~= "" and val or arg end
  if op == "-" then return isset and val or arg end
  if op == ":+" then return val ~= "" and arg or "" end
  if op == "+" then return isset and arg or "" end
  if op == ":=" then if val == "" then self:set_str(name, arg); return arg end return val end
  if op == "=" then if not isset then self:set_str(name, arg); return arg end return val end
  if op == ":?" then if val == "" then error({ __curse_exit = 1 }) end return val end
  if op == "?" then if not isset then error({ __curse_exit = 1 }) end return val end
  return self:apply_str_op(op, val, arg, arg2)
end

-- Shell-quote a string so it round-trips through eval (single-quote form).
local function shell_quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

-- The per-value string-transform operators (pattern strip, substitute, substring,
-- case, and the ${x@OP} transforms). Factored out so ${a[@]OP} can apply per element.
function Shell:apply_str_op(op, val, arg, arg2)
  arg = arg or ""
  if op == "@" then -- ${x@Q}/@U/@u/@L/@E (bash 5.1 transforms)
    if arg == "Q" then return shell_quote(val) end
    if arg == "U" then return val:upper() end
    if arg == "u" then return val:sub(1, 1):upper() .. val:sub(2) end
    if arg == "L" then return val:lower() end
    if arg == "E" then return M.ansi_unescape(val) end
    return val
  end
  if op == "#" then return strip_prefix(val, arg, false) end
  if op == "##" then return strip_prefix(val, arg, true) end
  if op == "%" then return strip_suffix(val, arg, false) end
  if op == "%%" then return strip_suffix(val, arg, true) end
  if op == "/" then return subst(val, arg, arg2 or "", false) end
  if op == "//" then return subst(val, arg, arg2 or "", true) end
  if op == "sub" then return substr(val, arg, arg2) end
  if op == "^^" then return val:upper() end
  if op == "^" then return val:sub(1, 1):upper() .. val:sub(2) end
  if op == ",," then return val:lower() end
  if op == "," then return val:sub(1, 1):lower() .. val:sub(2) end
  return val
end

-- Interpret backslash escapes for `echo -e` and ANSI-C `$'…'` quoting.
function M.ansi_unescape(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == "\\" and i < n then
      local d = s:sub(i + 1, i + 1)
      if d == "n" then out[#out + 1] = "\n"; i = i + 2
      elseif d == "t" then out[#out + 1] = "\t"; i = i + 2
      elseif d == "r" then out[#out + 1] = "\r"; i = i + 2
      elseif d == "\\" then out[#out + 1] = "\\"; i = i + 2
      elseif d == "'" then out[#out + 1] = "'"; i = i + 2
      elseif d == '"' then out[#out + 1] = '"'; i = i + 2
      elseif d == "a" then out[#out + 1] = "\7"; i = i + 2
      elseif d == "b" then out[#out + 1] = "\8"; i = i + 2
      elseif d == "e" or d == "E" then out[#out + 1] = "\27"; i = i + 2
      elseif d == "f" then out[#out + 1] = "\12"; i = i + 2
      elseif d == "v" then out[#out + 1] = "\11"; i = i + 2
      elseif d == "x" then
        local hex = s:match("^%x%x?", i + 2)
        if hex then out[#out + 1] = string.char(tonumber(hex, 16)); i = i + 2 + #hex
        else out[#out + 1] = "\\x"; i = i + 2 end
      elseif d:match("[0-7]") then -- octal \NNN (1-3 digits)
        local oct = s:match("^[0-7][0-7]?[0-7]?", i + 1)
        out[#out + 1] = string.char(tonumber(oct, 8) % 256); i = i + 1 + #oct
      elseif d == "c" then return table.concat(out) -- \c: stop output
      else out[#out + 1] = "\\" .. d; i = i + 2 end
    else out[#out + 1] = c; i = i + 1 end
  end
  return table.concat(out)
end

function Shell:echo(...)
  local n = select("#", ...)
  for i = 1, n do
    if i > 1 then self.out(" ") end
    self.out(tostring((select(i, ...))))
  end
  self.out("\n")
  self.status = 0
end

return M
