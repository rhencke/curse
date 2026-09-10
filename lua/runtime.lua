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

function Shell.new()
  return setmetatable({
    vars = {},       -- name -> { s = string?, n = int64? }  (lazy: fill on demand)
    status = 0,      -- $?
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
end

-- positional parameters ($# is read directly as sh.nparams)
function Shell:param(n) return (n <= self.nparams) and self.params[n] or "" end
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

-- int64 -> decimal string with no cdata "LL" suffix (what bash would print).
local function i64_to_str(n)
  return (tostring(n):gsub("LL$", ""))
end
M.i64_to_str = i64_to_str

-- String value of a var (materialize from the cached int64 if needed).
function Shell:get(name)
  local b = self.vars[name]
  if b == nil then return "" end
  if b.s == nil then
    if b.n == nil then return "" end
    b.s = i64_to_str(b.n)
  end
  return b.s
end

-- int64 value of a var for arithmetic (use the cache, else parse the string).
function Shell:aget(name)
  local b = self.vars[name]
  if b == nil then return i64(0) end
  if b.n == nil then b.n = str_to_i64(b.s) end
  return b.n
end

function Shell:set_str(name, s)
  local b = box(name, self.vars)
  b.s = s; b.n = nil
end

-- Arithmetic write: store the int64, defer the string (lazy).
function Shell:aset(name, n)
  local b = box(name, self.vars)
  b.n = i64(n); b.s = nil
  return b.n
end

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

-- Apply a ${…} operator. `arg`/`arg2` are already word-expanded by the caller.
function Shell:expand_param(pe, arg, arg2)
  local name, op = pe.name, pe.op
  local val, isset
  if name:match("^%d+$") then
    local nn = tonumber(name); val = self:param(nn); isset = (nn <= self.nparams)
  elseif name == "@" or name == "*" then
    val = self:paramsJoin(" "); isset = self.nparams > 0
  else
    isset = self.vars[name] ~= nil; val = self:get(name)
  end
  arg = arg or ""
  if op == "len" then return tostring(#val) end
  if op == ":-" then return val ~= "" and val or arg end
  if op == "-" then return isset and val or arg end
  if op == ":+" then return val ~= "" and arg or "" end
  if op == "+" then return isset and arg or "" end
  if op == ":=" then if val == "" then self:set_str(name, arg); return arg end return val end
  if op == "=" then if not isset then self:set_str(name, arg); return arg end return val end
  if op == ":?" then if val == "" then error({ __curse_exit = 1 }) end return val end
  if op == "?" then if not isset then error({ __curse_exit = 1 }) end return val end
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
