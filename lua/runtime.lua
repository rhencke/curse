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

-- Run an external command via fork + execvp + waitpid (FFI/libc directly — NOT
-- /bin/sh, which would recurse when curse IS /bin/sh, and would lose signal
-- info). argv... are already-expanded strings. stdout is captured through a pipe
-- and written to sh.out (so it composes with $(...) capture); $? is the exact
-- exit status, or 128+signum when the command is killed — like bash. (stderr is
-- inherited for now; redirection via dup2 comes with the fd model.)
local ffi = require("ffi")
local bit = require("bit")
ffi.cdef [[
  int fork(void);
  int execvp(const char *file, char *const argv[]);
  int waitpid(int pid, int *wstatus, int options);
  int pipe(int fildes[2]);
  int close(int fd);
  int dup2(int oldfd, int newfd);
  long read(int fd, void *buf, unsigned long count);
  void _exit(int status);
]]
local C = ffi.C

function Shell:exec(...)
  local args = { ... }
  local n = #args
  if n == 0 or args[1] == "" then self.status = 127; return end
  -- build argv in the PARENT (no Lua allocation in the child after fork)
  local argv = ffi.new("const char*[?]", n + 1)
  local anchor = {} -- keep the Lua strings alive while argv points into them
  for i = 1, n do anchor[i] = tostring(args[i]); argv[i - 1] = anchor[i] end
  argv[n] = nil
  local fds = ffi.new("int[2]")
  if C.pipe(fds) ~= 0 then self.status = 127; return end
  local rfd, wfd = fds[0], fds[1]
  local pid = C.fork()
  if pid == 0 then -- child: stdout -> pipe, then exec. This block must NEVER
    -- return into the interpreter (that would fork-bomb: a child that keeps
    -- running the script), so guard it — ANY failure ends in _exit, not unwind.
    pcall(function()
      C.dup2(wfd, 1); C.close(rfd); C.close(wfd)
      C.execvp(args[1], ffi.cast("char *const *", argv)) -- replaces the process on success
    end)
    C._exit(127) -- reached only if exec failed (command not found / threw)
  end
  C.close(wfd)
  local buf = ffi.new("char[65536]")
  local chunks = {}
  while true do
    local nr = C.read(rfd, buf, 65536)
    if nr <= 0 then break end
    chunks[#chunks + 1] = ffi.string(buf, nr)
  end
  C.close(rfd)
  local st = ffi.new("int[1]")
  C.waitpid(pid, st, 0)
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
