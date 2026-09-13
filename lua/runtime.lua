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
-- Single-quote a string for reuse as shell input: 'x' with embedded ' -> '\''.
-- (Used by ${x@Q}/@A/@K, declare -p, set, and procsub's inner `sh -c`.)
-- Quote a string so it re-reads as itself. A control char or high byte forces
-- ANSI-C $'…' form (\n \t \r, \NNN octal for other bytes), like bash's ${x@Q}
-- and `set`/`declare` output; otherwise plain single-quoting.
-- Quote a string the way bash's ${x@Q} / printf %q do. A PRINTABLE string (even
-- with multibyte chars) uses a plain single-quote; only a control/non-printable
-- byte forces the $'…' form, and inside it printable codepoints stay raw (per the
-- locale via iswprint) while control/bad bytes are escaped. Byte-identical to bash.
function M.shell_quote(s)
  if not s:find("[%z\1-\31\127-\255]") then
    return "'" .. s:gsub("'", "'\\''") .. "'"
  end
  -- there is a high/low byte: decide char-by-char whether $'…' is really needed
  local chars = M.mb_chars(s)
  local needc = false
  for _, ch in ipairs(chars) do
    if not ch.wc or ch.wc < 32 or ch.wc == 127 or M.iswprint(ch.wc) == 0 then needc = true; break end
  end
  if not needc then return "'" .. s:gsub("'", "'\\''") .. "'" end -- all printable (e.g. `'μ'`)
  local out = { "$'" }
  for _, ch in ipairs(chars) do
    if ch.wc and ch.wc >= 32 and ch.wc ~= 127 and M.iswprint(ch.wc) ~= 0 then
      if ch.s == "'" then out[#out + 1] = "\\'"
      elseif ch.s == "\\" then out[#out + 1] = "\\\\"
      else out[#out + 1] = ch.s end -- printable codepoint: keep the raw bytes
    else
      for i = 1, #ch.s do -- control char / non-printable / bad byte: escape each byte
        local b = ch.s:byte(i)
        if b == 10 then out[#out + 1] = "\\n"
        elseif b == 9 then out[#out + 1] = "\\t"
        elseif b == 13 then out[#out + 1] = "\\r"
        elseif b == 92 then out[#out + 1] = "\\\\"
        elseif b == 39 then out[#out + 1] = "\\'"
        elseif b >= 32 and b < 127 then out[#out + 1] = string.char(b)
        else out[#out + 1] = ("\\%03o"):format(b) end
      end
    end
  end
  out[#out + 1] = "'"; return table.concat(out)
end

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
    shellname = "bash", -- the shell we're mimicking, from our invocation basename
                        -- (\s prompt escape, posix-when-sh). Set by the CLI.
    start_time = os.time(), -- for $SECONDS
    opt_e = false,   -- set -e (errexit)
    opt_u = false,   -- set -u (nounset)
    opt_C = false,   -- set -C (noclobber)
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
    tenv = {},       -- tempenv shadow stack: {name, box, env, consumed, seq} per
                     -- `x=v cmd` binding; `unset` peels the highest-seq shadow layer
                     -- (tenv entry OR a `local` shadow), matching bash dynamic scope.
    vseq = 0,        -- monotonic counter ordering local/tempenv shadow layers
    calldepth = 0,   -- interpreter-only OSR gate (managed at the interp call site)
  }, Shell)
  sh:import_env()
  M.reset_locale(sh) -- adopt $LANG/$LC_* (bash calls setlocale at startup)
  if sh.vars["OPTIND"] == nil then sh:set_str("OPTIND", "1") end -- bash: OPTIND starts at 1
  if sh.vars["HOSTNAME"] == nil then sh:set_str("HOSTNAME", M.hostname()) end
  -- curse identifies as bash (see shellname/basename); advertise a version so
  -- feature-detection (`test -n "$BASH_VERSION"`, `[[ $BASH_VERSION == 5* ]]`)
  -- works. A normal var: scripts can reassign or `unset` it (bash).
  if sh.vars["BASH_VERSION"] == nil then sh:set_str("BASH_VERSION", "5.2.0(1)-release") end
  return sh
end

-- positional parameters ($# is read directly as sh.nparams). $0 is the script/
-- shell name (not a positional; not affected by set/shift).
function Shell:param(n)
  if n == 0 then return self.argv0 or "bash" end
  return (n <= self.nparams) and self.params[n] or ""
end
function Shell:paramsJoin(sep) return table.concat(self.params, sep or " ", 1, self.nparams) end
-- "$*" in a string context: params joined by IFS[0] (space if IFS unset, nothing
-- if IFS is set but empty) — bash. "$@" always joins by a literal space.
function Shell:paramsStar() return self:paramsJoin(self.vars["IFS"] and self:get("IFS"):sub(1, 1) or " ") end

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

-- $FUNCNAME / $BASH_LINENO / $BASH_SOURCE maintenance for the compiled tier: push the
-- running function's name, the CALL-site line, and the source file (innermost at [1],
-- matching interp's run_function). The compiled call site emits these around fn_x only
-- when the program reads one of those vars (else zero cost).
function Shell:enterFunc(name, line)
  local fs = self.funcstack; if not fs then fs = {}; self.funcstack = fs end
  table.insert(fs, 1, name)
  local ls = self.linestack; if not ls then ls = {}; self.linestack = ls end
  table.insert(ls, 1, line or 0)
  local ss = self.srcstack; if not ss then ss = {}; self.srcstack = ss end
  table.insert(ss, 1, self.cur_source or self.argv0 or "")
end
function Shell:leaveFunc()
  if self.funcstack then table.remove(self.funcstack, 1) end
  if self.linestack then table.remove(self.linestack, 1) end
  if self.srcstack then table.remove(self.srcstack, 1) end
end
function Shell:popCall()
  local d = self.pd
  local saved = self.savedstack[d]
  if saved then
    for name, rec in pairs(saved) do
      local old = rec.box -- rec = { box = <prior box>|false, seq = N }
      local cur = self.vars[name]
      self.vars[name] = old or nil -- false => was absent
      -- An exported local (`local x; export x`) had a function-scoped env entry;
      -- revert it on return — restore the outer var's env value, or drop it (bash).
      if cur and cur.exported then
        if old and old.exported then ffi.C.setenv(name, self:get(name) or "", 1)
        else ffi.C.unsetenv(name) end
      end
    end
    self.savedstack[d] = false
  end
  self:popParams()
end
-- `local name`: shadow the variable within the current call frame (restored on
-- return). Records the prior box once so it can be put back.
function Shell:localVar(name, has_init)
  local d = self.pd
  local saved = self.savedstack[d]
  if not saved then saved = {}; self.savedstack[d] = saved end
  -- Only shadow on the FIRST `local name` in this scope; a repeat (`local foo;
  -- local foo`) keeps the value already established here (bash).
  if saved[name] == nil then
    -- An active tempenv binding for `name` interacts with `local` two ways (bash):
    --  * INHERIT: a no-initializer `local x` takes the tempenv's current value
    --    (dynamically scoped — any active tempenv, even from an enclosing call);
    --    never the plain global/exported value.
    --  * ABSORB: only when the tempenv is THIS call's own prefix (te.frame == pd)
    --    does the local take over its slot — the box we shadow is then what the
    --    tempenv shadowed (e.g. the global), and the tempenv stops restoring on its
    --    own. A tempenv from `eval`/an enclosing call is NOT absorbed: the local
    --    shadows the tempenv value normally, so `unset` later reveals the tempenv.
    local te
    for k = #self.tenv, 1, -1 do
      local e = self.tenv[k]
      if not e.consumed and e.name == name then te = e; break end
    end
    self.vseq = self.vseq + 1
    if te and te.frame == self.pd then
      saved[name] = { box = te.box, seq = self.vseq }; te.consumed = true
    else
      saved[name] = { box = self.vars[name] or false, seq = self.vseq }
    end
    if te and not has_init then -- inherit the tempenv value
      local b = self.vars[name]
      self.vars[name] = b and { s = b.s, n = b.n, arr = b.arr, assoc = b.assoc, order = b.order } or {}
    else
      self.vars[name] = {}
    end
  end
end

-- one `local` operand: `name`, `name=value`, or `name+=value` (value expanded).
-- `+=` appends to the value AFTER localizing (bash: appends to the new local, not
-- the shadowed outer one).
function Shell:localAssign(arg)
  local nm, op, val = arg:match("^([%a_][%w_]*)(%+?=)(.*)$")
  if nm then
    self:localVar(nm, true)
    self:set_str(nm, op == "+=" and (self:get(nm) .. val) or val)
  else self:localVar(arg) end
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
    if c == "\1" and i < n then -- CTLESC: next char is literal (read backslash-escape)
      cur = (cur or "") .. s:sub(i + 1, i + 1); i = i + 2
    elseif inifs(c) then
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
  int posix_spawnattr_init(void *attr);
  int posix_spawnattr_destroy(void *attr);
  int posix_spawnattr_setflags(void *attr, short flags);
  int posix_spawnattr_setsigmask(void *attr, const void *sigmask);
  int sigemptyset(void *set);
  int sigprocmask(int how, const void *set, void *oldset);
  int waitpid(int pid, int *wstatus, int options);
  int pipe(int fildes[2]);
  int close(int fd);
  int dup2(int oldfd, int newfd);
  int dup(int oldfd);
  int open(const char *path, int flags, int mode);
  int fcntl(int fd, int cmd, ...);
  int fork(void);
  void _exit(int status);
  int access(const char *path, int mode);
  long read(int fd, void *buf, unsigned long count);
  int setenv(const char *name, const char *value, int overwrite);
  int unsetenv(const char *name);
  extern char **environ;
  /* Locale — delegate every multibyte/collation/case op to glibc, exactly as bash
     does, so curse matches bash under ANY locale (UTF-8, ISO-8859-*, EUC, GB18030,
     locale-specific collation/case), not just byte/UTF-8. */
  char *setlocale(int category, const char *locale);
  size_t __ctype_get_mb_cur_max(void);
  typedef struct { int __count; unsigned int __value; } curse_mbstate_t;
  size_t mbrtowc(int *pwc, const char *s, size_t n, curse_mbstate_t *ps);
  size_t wcrtomb(char *s, int wc, curse_mbstate_t *ps);
  int towupper(int wc);
  int towlower(int wc);
  int iswprint(int wc);
  int iswctype(int wc, unsigned long desc);
  unsigned long wctype(const char *name);
  int wcwidth(int wc);
  int strcoll(const char *s1, const char *s2);
  size_t strxfrm(char *dest, const char *src, size_t n);
  char *ttyname(int fd);
]]
local C = ffi.C

-- ---- Locale (glibc-delegated, like bash) ----------------------------------
-- A C program starts in the "C" locale until setlocale(LC_ALL,"") is called, so
-- $LANG/$LC_* have no effect on mbrtowc/towupper/strcoll until we opt in. bash
-- calls setlocale at startup AND whenever a locale variable changes; we mirror
-- that so curse tracks the locale live (`LC_COLLATE=…; echo [a-z]*` mid-script).
-- glibc category numbers (locale.h): CTYPE 0, NUMERIC 1, TIME 2, COLLATE 3,
-- MONETARY 4, MESSAGES 5, ALL 6.
local LC_CATEGORIES = { LC_CTYPE = 0, LC_NUMERIC = 1, LC_TIME = 2, LC_COLLATE = 3, LC_MONETARY = 4, LC_MESSAGES = 5 }
local lc_mb_cur_max = 1 -- module-global: setlocale is process-wide
M.lc_mb_cur_max = function() return lc_mb_cur_max end
-- Re-apply the shell's locale variables to the C library, honoring bash/POSIX
-- precedence per category: LC_ALL overrides; else LC_<category>; else LANG. An
-- invalid locale name makes setlocale return NULL and leaves the prior locale in
-- place (bash warns and continues) — so we never clobber a good locale.
function M.reset_locale(sh)
  local all = sh.vars["LC_ALL"] and sh:get("LC_ALL")
  local lang = sh.vars["LANG"] and sh:get("LANG")
  for name, cat in pairs(LC_CATEGORIES) do
    -- Precedence LC_ALL > LC_<cat> > LANG > "C". An INVALID name makes setlocale
    -- return NULL; bash then falls through to the next candidate (so LC_CTYPE=invalid
    -- with LANG=C.UTF-8 still gives a UTF-8 ctype). Take the first that SUCCEEDS.
    local cands
    if all and all ~= "" then cands = { all, "C" }
    else
      local b = sh.vars[name]; local lv = b and sh:get(name)
      cands = {}
      if lv and lv ~= "" then cands[#cands + 1] = lv end
      if lang and lang ~= "" then cands[#cands + 1] = lang end
      cands[#cands + 1] = "C"
    end
    for _, v in ipairs(cands) do if C.setlocale(cat, v) ~= nil then break end end
  end
  lc_mb_cur_max = tonumber(C.__ctype_get_mb_cur_max()) or 1
end
M.LC_CATEGORIES = LC_CATEGORIES

-- Count CHARACTERS (codepoints) in a byte string using the current LC_CTYPE, the
-- way bash's MB_STRLEN does: single-byte locale -> byte length; else walk with
-- mbrtowc, counting an invalid/incomplete byte as one char and resyncing by one.
local _mb_wc = ffi.new("int[1]")
local _mb_st = ffi.new("curse_mbstate_t")
function M.mb_strlen(s)
  if lc_mb_cur_max <= 1 then return #s end
  ffi.fill(_mb_st, ffi.sizeof(_mb_st))
  local ptr, i, n, count = ffi.cast("const char *", s), 0, #s, 0
  while i < n do
    local r = tonumber(C.mbrtowc(_mb_wc, ptr + i, n - i, _mb_st))
    if r == 0 or r > (n - i) then r = 1 end -- NUL / invalid / incomplete: one char, one byte
    i = i + r; count = count + 1
  end
  return count
end

-- Decode a byte string into a list of { s = <the raw bytes of this char>, wc =
-- <codepoint or nil for a bad byte> } — the char granularity bash uses for
-- case-folding and other per-character operations. Single-byte locale => one
-- entry per byte (wc = the byte value).
function M.mb_chars(s)
  local out, n = {}, #s
  if lc_mb_cur_max <= 1 then
    for k = 1, n do out[k] = { s = s:sub(k, k), wc = s:byte(k) } end
    return out
  end
  ffi.fill(_mb_st, ffi.sizeof(_mb_st))
  local ptr, i = ffi.cast("const char *", s), 0
  while i < n do
    local r = tonumber(C.mbrtowc(_mb_wc, ptr + i, n - i, _mb_st))
    local wc = _mb_wc[0]
    if r == 0 or r > (n - i) then r = 1; wc = nil end -- bad byte: no codepoint
    out[#out + 1] = { s = s:sub(i + 1, i + r), wc = wc }
    i = i + r
  end
  return out
end

-- Byte length of the character starting at byte index `i` (1-based) of `s`: 1 for
-- ASCII or a single-byte locale, else the multibyte length via mbrtowc (a bad or
-- incomplete byte counts as 1). Lets the hot IFS-split path stay byte-fast for
-- ASCII while handling a multibyte IFS delimiter (`IFS=ç`) correctly.
function M.mb_charlen(s, i)
  local b = s:byte(i)
  if not b or b < 0x80 or lc_mb_cur_max <= 1 then return 1 end
  ffi.fill(_mb_st, ffi.sizeof(_mb_st))
  local r = tonumber(C.mbrtowc(_mb_wc, ffi.cast("const char *", s) + (i - 1), #s - i + 1, _mb_st))
  if r <= 0 or r > (#s - i + 1) then return 1 end
  return r
end

-- Re-encode a codepoint to bytes in the current locale (wcrtomb); on failure keep
-- the original bytes. Used to write back a case-folded character.
local _mb_buf = ffi.new("char[16]")
function M.wc_to_bytes(wc, orig)
  if lc_mb_cur_max <= 1 then return string.char(wc % 256) end
  ffi.fill(_mb_st, ffi.sizeof(_mb_st))
  local r = tonumber(C.wcrtomb(_mb_buf, wc, _mb_st))
  if r <= 0 or r > 16 then return orig end
  return ffi.string(_mb_buf, r)
end
M.towupper = function(wc) return tonumber(C.towupper(wc)) end
M.towlower = function(wc) return tonumber(C.towlower(wc)) end
M.iswprint = function(wc) return tonumber(C.iswprint(wc)) end
-- Collation order per LC_COLLATE (glob-result sort, [[ < ]] compare), with a
-- byte-order tiebreak so equal-weight strings keep a stable total order like bash.
-- Under LC_COLLATE=C this is plain byte order (strcoll == strcmp), so it is a
-- no-op there; only a real collating locale reorders.
function M.coll_lt(a, b)
  local c = tonumber(C.strcoll(a, b))
  if c ~= 0 then return c < 0 end
  return a < b
end
-- Subshell fork helpers for the COMPILED path: a `( … )` is compiled as fork + a
-- bounded body sub-CFG that _exits at its boundary (so it never runs the top-level
-- continuation), while the parent waits — the same design as the interp subshell,
-- so a forked child running the body honors interp/bg-compile/OSR like any code.
function M.subshell_fork(sh) -- returns pid (0 in the child, which is set up here)
  io.flush() -- flush buffered parent stdout so the fork doesn't duplicate it
  local pid = C.fork()
  if pid == 0 then
    sh.in_subprogram = (sh.in_subprogram or 0) + 1 -- ERR trap won't fire here (sans errtrace)
    sh.loopdepth = 0 -- an enclosing loop isn't ours to break/continue
    sh.out = io.write
  end
  return pid
end
local _ss_st = ffi.new("int[1]")
function M.subshell_wait(pid) C.waitpid(pid, _ss_st, 0); return M.wexit(_ss_st[0]) end
function M.subshell_exit(status) io.flush(); C._exit(status or 0) end

-- Redirections, GENUINELY COMPILED. The compiler knows each redirect's operator +
-- fd at compile time and computes its target natively, then calls this with the
-- computed operands — real syscalls, not an AST re-walk. redir_apply backs up each
-- touched fd into `saves` and installs the redirect; redir_restore puts them back.
-- A failure (open error, ambiguous/unopened dup target) returns false: the command
-- is skipped with $?=1, like bash. The compiler only hands us monomorphic cases
-- (literal file target, digit/`-` dup target, heredoc/herestring body); dynamic
-- field-engine targets, `exec` (which must PERSIST), and fd moves are delegated.
local _redir_stat = ffi.new("char[144]") -- struct stat scratch (st_mode at +24)
local function _temp_fd(content) -- write body to a temp file, return an O_RDONLY fd
  local tmp = os.tmpname()
  local w = io.open(tmp, "w"); if not w then return -1 end
  w:write(content); w:close()
  local f = C.open(tmp, 0, 0) -- O_RDONLY
  os.remove(tmp) -- the open fd keeps the inode alive
  return f
end
function M.redir_apply(sh, op, fd, target, saves)
  io.flush() -- flush buffered stdout before moving fds (else it lands in the new target)
  local function backup(f) saves[#saves + 1] = { fd = f, saved = C.dup(f) } end
  local function open_out(path) -- honor noclobber (set -C) for a truncating '>'
    if not sh.opt_C then return C.open(path, 577, 438) end -- O_WRONLY|O_CREAT|O_TRUNC
    local h = C.open(path, 705, 438) -- + O_EXCL
    if h >= 0 then return h end
    if C.curse_rt_stat(path, _redir_stat) == 0
        and bit.band(ffi.cast("uint32_t *", _redir_stat + 24)[0], 0xF000) ~= 0x8000 then
      return C.open(path, 1, 438) -- existing NON-regular (e.g. /dev/null): plain O_WRONLY
    end
    return -1
  end
  if op == "out" or op == "clobber" then
    backup(fd); local h = (op == "out") and open_out(target) or C.open(target, 577, 438)
    if h < 0 then return false end; if h ~= fd then C.dup2(h, fd); C.close(h) end
  elseif op == "app" then
    backup(fd); local h = C.open(target, 1089, 438) -- O_WRONLY|O_CREAT|O_APPEND
    if h < 0 then return false end; if h ~= fd then C.dup2(h, fd); C.close(h) end
  elseif op == "in" then
    backup(fd); local h = C.open(target, 0, 0) -- O_RDONLY
    if h < 0 then return false end; if h ~= fd then C.dup2(h, fd); C.close(h) end
  elseif op == "rw" then
    backup(fd); local h = C.open(target, 66, 438) -- O_RDWR|O_CREAT
    if h < 0 then return false end; if h ~= fd then C.dup2(h, fd); C.close(h) end
  elseif op == "dup" or op == "dupin" then -- N>&M / N<&M / N>&-
    if target == "-" then backup(fd); C.close(fd)
    else
      local tf = tonumber(target); if not tf then return false end
      if C.fcntl(tf, 1) == -1 then return false end -- F_GETFD: target fd not open -> bash fails
      backup(fd); C.dup2(tf, fd)
    end
  elseif op == "outboth" or op == "appboth" then -- &> / &>>
    backup(1); backup(2)
    local h = (op == "appboth") and C.open(target, 1089, 438) or open_out(target)
    if h < 0 then return false end; C.dup2(h, 1); C.dup2(h, 2); C.close(h)
  elseif op == "heredoc" or op == "herestring" then
    backup(fd); local h = _temp_fd(target) -- target = the already-built body text
    if h < 0 then return false end; if h ~= fd then C.dup2(h, fd); C.close(h) end
  else return nil end -- op the compiler shouldn't have handed us
  return true
end
function M.redir_restore(saves)
  io.flush()
  for i = #saves, 1, -1 do local s = saves[i]; C.dup2(s.saved, s.fd); C.close(s.saved) end
end
-- bash values are C strings: a NUL byte terminates them. Truncate at the first NUL
-- wherever a byte string becomes a variable value or an argv entry (assignment,
-- fields/argv, for-lists). I/O streams (echo/printf output, pipes) keep raw NULs —
-- those never pass through this. Fast no-op when there is no NUL (the common case).
function M.cstr(s)
  local z = s:find("\0", 1, true)
  return z and s:sub(1, z - 1) or s
end

-- Decode a waitpid status word into a bash exit code: 128+signum when killed by
-- a signal, else the WEXITSTATUS byte. (Shared by Shell:exec, wait, subshell,
-- pipeline.)
function M.wexit(s)
  local sig = bit.band(s, 0x7f)
  if sig ~= 0 and sig ~= 0x7f then return 128 + sig end
  return bit.rshift(bit.band(s, 0xff00), 8)
end

-- Child side of the ENOEXEC fallback: an executable file with no shebang is a
-- shell script (bash runs it as one), so resolve it via $PATH exactly as the
-- failed execvp would, then run it through our own interpreter and _exit. fd 1
-- must already point where the script's stdout should go. Never returns.
function Shell:exec_script_child(path, args, n)
  -- This forked child inherited the parent's blocked signal mask (set while a
  -- trap is active). Reset to empty so the child is interruptible.
  if self.sigtraps and next(self.sigtraps) then
    local set = ffi.new("uint8_t[1024]"); C.sigemptyset(set)
    C.sigprocmask(2, set, nil) -- SIG_SETMASK
  end
  local f = io.open(path, "r"); local src = f and f:read("*a") or ""; if f then f:close() end
  -- A no-shebang script is exec'd as a FRESH process: it sees only the exported
  -- environment, NOT the parent's in-memory shell vars/functions/traps. Build a
  -- new shell (import_env populates it from the environment) rather than reusing
  -- self, so a non-exported `x=1; ./script` doesn't leak x into the script.
  local child = Shell.new()
  child.argv0, child.out = args[1], io.write
  for k = 2, n do child.nparams = child.nparams + 1; child.params[child.nparams] = args[k] end
  pcall(require("interp").run_lazy, child, src)
  io.flush(); C._exit(child.status or 0)
end

-- ENOEXEC fallback for the streaming (non-capturing) path: fd 1 is already the
-- destination, so just fork a child that runs the script and inherits fd 1.
function Shell:run_noexec(path, args, n)
  local pid = C.fork()
  if pid == 0 then self:exec_script_child(path, args, n) end
  local st = ffi.new("int[1]"); C.waitpid(pid, st, 0); self.status = M.wexit(st[0])
end

-- When signal traps are active the shell BLOCKS the trapped signals (so it can
-- poll them at safepoints instead of running Lua from an async handler). A
-- posix_spawn child inherits that blocked mask, which would make a foreground
-- external command uninterruptible by the very signal the user trapped (e.g.
-- Ctrl-C during `sleep 100`). Reset the child's mask to empty — like a bash
-- child — via a spawnattr with SETSIGMASK. Returns the attr (kept alive by the
-- caller until after the spawn, then destroyed) or nil when no trap is active.
local SPAWN_SETSIGMASK = 0x08 -- POSIX_SPAWN_SETSIGMASK (glibc)
local function child_spawnattr(self)
  if not (self.sigtraps and next(self.sigtraps)) then return nil end
  local attr = ffi.new("uint8_t[1024]") -- opaque posix_spawnattr_t; over-allocate
  if C.posix_spawnattr_init(attr) ~= 0 then return nil end
  local set = ffi.new("uint8_t[1024]") -- copied into attr by setsigmask; needn't outlive it
  C.sigemptyset(set)
  C.posix_spawnattr_setsigmask(attr, set)
  C.posix_spawnattr_setflags(attr, SPAWN_SETSIGMASK)
  return attr
end

function Shell:exec(...)
  local args = { ... }
  local n = #args
  if n == 0 or args[1] == "" then self.status = 127; return end
  -- Resolve a bare name to its (cached) $PATH location, but keep argv[0] = the
  -- name as typed. A command with a `/` is exec'd directly.
  local execpath = args[1]
  if not args[1]:find("/", 1, true) then
    execpath = self:resolve_cmd(args[1])
    if not execpath then
      self:errmsg("curse: " .. args[1] .. ": command not found\n"); self.status = 127; return
    end
  end
  local argv = ffi.new("const char*[?]", n + 1)
  local anchor = {} -- keep the Lua strings alive while argv points into them
  for i = 1, n do anchor[i] = tostring(args[i]); argv[i - 1] = anchor[i] end
  argv[n] = nil
  if self.exec_argv0 then anchor.a0 = tostring(self.exec_argv0); argv[0] = anchor.a0 end -- exec -a NAME
  -- Not capturing (self.out is the real fd 1, e.g. a top-level command or a
  -- pipeline stage): let the child write STRAIGHT to fd 1 (inherit fds) instead
  -- of buffering all its output — so an unbounded producer (`cat /dev/zero | …`)
  -- streams and SIGPIPE propagates, and there's no 2x-memory capture.
  if self.out == io.write then
    io.flush() -- our own buffered stdout must reach fd 1 before the child writes
    local pidp = ffi.new("curse_pid_t[1]")
    local attr = child_spawnattr(self)
    local rc = C.posix_spawnp(pidp, execpath, nil, attr, ffi.cast("char *const *", argv), C.environ)
    if attr then C.posix_spawnattr_destroy(attr) end
    if rc == 8 then return self:run_noexec(execpath, args, n) end -- no shebang: run as a script
    if rc ~= 0 then
      self:errmsg("curse: " .. tostring(args[1]) .. (rc == 2 and ": command not found\n" or ": Permission denied\n"))
      self.status = (rc == 2) and 127 or 126; return
    end
    local st = ffi.new("int[1]"); C.waitpid(pidp[0], st, 0); self.status = M.wexit(st[0]); return
  end
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
  local attr = child_spawnattr(self)
  local rc = C.posix_spawnp(pidp, execpath, fa, attr, ffi.cast("char *const *", argv), C.environ)
  if attr then C.posix_spawnattr_destroy(attr) end
  C.posix_spawn_file_actions_destroy(fa)
  local pid = pidp[0]
  if rc == 8 then -- ENOEXEC: no-shebang script — run it through our interpreter in a
    pid = C.fork()  -- child, with its stdout dup'd onto the capture pipe's write end.
    if pid == 0 then
      C.dup2(wfd, 1); C.close(wfd); C.close(rfd)
      self:exec_script_child(execpath, args, n)
    end
  end
  C.close(wfd)
  if rc ~= 0 and rc ~= 8 then -- ENOENT -> "command not found" (127); else can't-execute (126)
    C.close(rfd)
    self:errmsg("curse: " .. tostring(args[1]) .. (rc == 2 and ": command not found\n" or ": Permission denied\n"))
    self.status = (rc == 2) and 127 or 126
    return
  end
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
  self.status = M.wexit(st[0])
  local out = table.concat(chunks)
  if out ~= "" then self.out(out) end
end

-- Command substitution `$(...)`: run the inner program capturing stdout, with
-- trailing newlines stripped (bash). Interpreted (it's I/O-bound, not hot), so
-- it handles builtins, externals, and (in interp mode) functions uniformly.
-- `$(…)` runs in a forked child (CoW — the child already holds all state), so it
-- gets FULL subshell isolation for free (vars, set-flags, fds, cwd, umask, traps,
-- functions, $BASHPID) exactly like bash — which manual in-process save/restore
-- can't reliably do. Output is captured through a pipe, like the subshell path.
function Shell:capture_forked(ast)
  local I = require("interp")
  io.flush()
  local pfd = ffi.new("int[2]")
  if C.pipe(pfd) ~= 0 then return nil end -- caller falls back to in-process
  local pid = C.fork()
  if pid == 0 then
    C.close(pfd[0]); C.dup2(pfd[1], 1); C.close(pfd[1])
    self.out = io.write
    self.in_subprogram = (self.in_subprogram or 0) + 1
    local ok, err = pcall(I.exec_list, self, ast.stmts, function() end, true)
    if not ok and type(err) == "table" and (err.__curse_exit or err.__curse_return) then
      self.status = err.__curse_exit or err.__curse_return
    end
    io.flush(); C._exit(self.status or 0)
  end
  C.close(pfd[1])
  local chunks, rbuf = {}, ffi.new("char[8192]")
  while true do
    local nr = tonumber(C.read(pfd[0], rbuf, 8192))
    if not nr or nr <= 0 then break end
    chunks[#chunks + 1] = ffi.string(rbuf, nr)
  end
  C.close(pfd[0])
  local stbuf = ffi.new("int[1]"); C.waitpid(pid, stbuf, 0)
  self.status = M.wexit(stbuf[0])
  return (table.concat(chunks):gsub("%z", ""):gsub("\n+$", ""))
end
-- A `$(…)` body is "pure" (no shell-state side effects, so safe to run in-process
-- for speed) when every command is a plain external/non-mutating-builtin call with
-- no assignments, no mutating builtin, no user-function call, and no control flow.
-- Anything else forks for full isolation. (A file redirect like `>f` is fine — the
-- write happens either way; only `exec` rewires shell fds, and it's listed here.)
local CAPTURE_IMPURE = { cd = 1, set = 1, shopt = 1, unset = 1, export = 1,
  declare = 1, typeset = 1, ["local"] = 1, readonly = 1, trap = 1, umask = 1,
  exec = 1, eval = 1, source = 1, ["."] = 1, pushd = 1, popd = 1, hash = 1,
  shift = 1, read = 1, mapfile = 1, readarray = 1, let = 1, getopts = 1,
  ulimit = 1, disown = 1, ["return"] = 1, ["set-o"] = 1 }
local function capture_pure(sh, st)
  local t = st.t
  if t == "andor" then
    for _, it in ipairs(st.items) do if not capture_pure(sh, it.cmd) then return false end end
    return true
  elseif t == "pipeline" then
    for _, c in ipairs(st.cmds) do if not capture_pure(sh, c) then return false end end
    return true
  elseif t == "simple" then
    if st.assigns or st.arrayargs then return false end -- prefix/array assignment mutates
    local w = st.words and st.words[1]
    local lit = w and w.parts and #w.parts == 1 and w.parts[1].lit
    if not lit then return false end -- dynamic/compound command name: be safe, fork
    if CAPTURE_IMPURE[lit] or sh.functions[lit] then return false end
    return true
  end
  return false -- if/while/for/case/subshell/group/funcdef/background/arithcmd: fork
end

function Shell:capture_src(src)
  local P = require("parser")
  local I = require("interp")
  local ast = P.parse(src, self) -- self: $()/`` expand aliases from the live table
  -- $(< file) / `< file`: bash reads the file's contents (a faster $(cat file)) —
  -- a pure read, no isolation needed, so keep it in-process.
  if #ast.stmts == 1 then
    local st = ast.stmts[1]
    if st.t == "simple" and (not st.words or #st.words == 0)
        and st.redirs and #st.redirs == 1 and st.redirs[1].op == "in" then
      local path = I.expand_assign_word(self, P.parse_word(st.redirs[1].target or ""))
      local f = path ~= "" and io.open(path, "r")
      if f then local c = f:read("*a") or ""; f:close(); self.status = 0
        return (c:gsub("%z", ""):gsub("\n+$", "")) end
      io.stderr:write("curse: " .. path .. ": No such file or directory\n"); self.status = 1; return ""
    end
  end
  -- Fork for full subshell isolation (bash) UNLESS the body is provably pure — a
  -- pure body has no shell-state side effects to leak, so it runs in-process for
  -- speed (the common `$(cmd)`/`$(echo …)` case). Fall back to in-process if the
  -- fork/pipe itself fails.
  -- $BASHPID reads the child's pid, so it needs a real fork even with no mutation.
  local forkit = src:find("BASHPID", 1, true) ~= nil
  local has_perr = false
  for _, st in ipairs(ast.stmts) do
    if st.t == "parse_error" then has_perr = true end
    if not capture_pure(self, st) then forkit = true end
  end
  -- A SYNTAX error in the body is fatal to the CONTAINING command (bash), which the
  -- in-process path propagates via __curse_parseerr — so never fork a parse-error
  -- body (a forked child would only surface it as an exit status, which `echo $(…)`
  -- would then ignore). Otherwise fork impure bodies for full isolation.
  if forkit and not has_perr then
    local out = self:capture_forked(ast)
    if out ~= nil then return out end
  end
  local buf = {}
  local saved = self.out
  self.out = function(x) buf[#buf + 1] = x end
  local saved_cap = self.capturing; self.capturing = true -- last pipeline stage drains into buf
  self.in_subprogram = (self.in_subprogram or 0) + 1 -- $(...) is a subprogram: ERR trap suppressed
  local saved_ld = self.loopdepth; self.loopdepth = 0 -- break/continue don't cross into $(...)
  -- errexit is NOT inherited into a command sub (unless inherit_errexit): a failing
  -- middle command doesn't abort — only the cmdsub's final status propagates out.
  local savede = self.opt_e
  if not (self.shopt and self.shopt.inherit_errexit) then self.opt_e = false end
  local saved_line = self.cur_line -- $LINENO: the sub's internal lines don't leak out
  -- $() is a child: it INHERITS the parent's aliases but its own alias/unalias
  -- do not leak back out (bash). Give it an independent copy, restored after.
  local saved_aliases = self.aliases
  do local c = {}; for k, v in pairs(saved_aliases) do c[k] = v end; self.aliases = c end
  -- Run via exec_list (NOT interp.run): an `exit`/`return` inside $() ends only
  -- the sub (sets its status), and the parent's EXIT trap must NOT fire here.
  local ok, err = pcall(I.exec_list, self, ast.stmts, function() end, true)
  self.aliases = saved_aliases -- discard aliases defined inside $()
  self.cur_line = saved_line
  self.opt_e = savede
  self.loopdepth = saved_ld
  self.in_subprogram = self.in_subprogram - 1
  self.capturing = saved_cap
  self.out = saved
  if not ok then
    if type(err) == "table" and err.__curse_parseerr then
      error(err) -- a SYNTAX error inside $(…) is fatal to the whole containing command (bash)
    elseif type(err) == "table" and (err.__curse_exit or err.__curse_return) then
      self.status = err.__curse_exit or err.__curse_return
    else error(err) end
  end
  self.last_cmdsub_status = self.status -- for a command whose argv is empty after expansion
  -- bash strips NUL bytes from command-substitution output ("ignored null byte")
  return (table.concat(buf):gsub("%z", ""):gsub("\n+$", ""))
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
local function digit_val(ch, base)
  local b = ch:byte()
  if b >= 48 and b <= 57 then return b - 48 end        -- 0-9
  if base and base > 36 then                            -- bases 37-64 (zsh/bash):
    if b >= 97 and b <= 122 then return b - 97 + 10 end -- a-z -> 10..35
    if b >= 65 and b <= 90 then return b - 65 + 36 end  -- A-Z -> 36..61
    if ch == "@" then return 62 end
    if ch == "_" then return 63 end
    return nil
  end
  if b >= 97 and b <= 122 then return b - 97 + 10 end  -- a-z -> 10..35 (case-insensitive)
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
  if b then
    -- explicit N#digits: the base must not have a leading zero, and every digit
    -- must be valid for it (bash errors otherwise, unlike the lenient forms below).
    if (b:sub(1, 1) == "0" and #b > 1) or tonumber(b) < 2 or tonumber(b) > 64 then
      error({ __curse_exit = 1, __curse_matherr = true, __curse_experr = true })
    end
    base = tonumber(b); digits = d
    for k = 1, #d do local dv = digit_val(d:sub(k, k), base)
      if not dv or dv >= base then error({ __curse_exit = 1, __curse_matherr = true, __curse_experr = true }) end end
  elseif s:sub(1, 2):lower() == "0x" then base = 16; digits = s:sub(3)
  elseif s:sub(1, 1) == "0" and s:match("^0[0-7]+$") then base = 8; digits = s:sub(2)
  else digits = s:match("^%d+") or "" end
  if digits == "" or base < 2 or base > 64 then return sign < 0 and -str_to_i64(s) or str_to_i64(s) end
  local n, B = i64(0), i64(base)
  for k = 1, #digits do
    local dv = digit_val(digits:sub(k, k), base)
    if not dv or dv >= base then break end
    n = n * B + i64(dv)
  end
  return sign < 0 and -n or n
end
M.arith_num = arith_num

-- int64 integer power (** operator) for the compiled backend (interp inlines its
-- own, guarding the negative exponent before it reaches here). bash disallows a
-- negative exponent: throw the same non-fatal matherr div0 does (lineabort so a
-- word-context $(( )) aborts the command; matherr so a (( )) pcall maps it to $?=1).
function M.ipow(base, exp)
  local n = tonumber(exp)
  if n < 0 then
    io.stderr:write("curse: exponent less than 0\n")
    error({ __curse_exit = 1, __curse_matherr = true, __curse_lineabort = true })
  end
  local r = i64(1)
  for _ = 1, n do r = r * base end
  return r
end

-- Division/modulo with bash's fatal divide-by-zero (aborts the command, status 1).
-- __curse_matherr lets a protected caller (compgen -F) recover; __curse_lineabort
-- makes run_lazy fast-forward past the rest of the current input LINE (bash's
-- line-oriented abort). Shared by both tiers so the compiled path faults alike.
local function div0()
  io.stderr:write("curse: division by 0\n")
  error({ __curse_exit = 1, __curse_matherr = true, __curse_lineabort = true })
end
function M.idiv(l, r) if r == i64(0) then div0() end; return l / r end
function M.imod(l, r) if r == i64(0) then div0() end; return l % r end

-- int64 -> decimal string with no cdata "LL" suffix (what bash would print).
local function i64_to_str(n)
  return (tostring(n):gsub("LL$", ""))
end
M.i64_to_str = i64_to_str

-- Indexed-array KEYS. LuaJIT's LUA_NUMBER is a double, so a Lua-number key loses
-- precision above 2^53 (distinct huge int64 indices would collide). Key by a plain
-- NUMBER in the exact-double range (the common, fast case — numeric hashing, no
-- string churn) and by the canonical decimal STRING only beyond it (exact). The
-- two key spaces never overlap (t[5] vs t["5"] differ), and a given index always
-- maps to the same key, so writes and reads agree.
local I64_EXACT = 0x20000000000000LL -- 2^53
local function to_arr_key(v) -- v: int64 -> number|string key
  if v >= -I64_EXACT and v <= I64_EXACT then return tonumber(v) end
  return i64_to_str(v)
end
local function key_i64(k) -- either key form -> int64 (for compare/arith)
  return type(k) == "string" and str_to_i64(k) or i64(k)
end
M.to_arr_key, M.key_i64 = to_arr_key, key_i64

-- Dynamic special variables (only when not explicitly set). Many spec cases just
-- check these "look like" a PID/uid/path, so exact values rarely matter.
ffi.cdef [[
  int getpid(void); int getppid(void); int getuid(void); int geteuid(void);
  char *getcwd(char *buf, unsigned long size);
  int curse_rt_stat(const char *path, void *buf) asm("stat");
  struct curse_pw { char *pw_name; char *pw_passwd; unsigned int pw_uid; unsigned int pw_gid; char *pw_gecos; char *pw_dir; char *pw_shell; };
  struct curse_pw *getpwuid(unsigned int uid);
]]
local scratch = ffi.new("char[4096]")
local stbuf_a, stbuf_b = ffi.new("uint8_t[144]"), ffi.new("uint8_t[144]")
-- Do two paths name the same directory (same device + inode)? Used to validate an
-- inherited $PWD against the real cwd on startup (bash keeps a symlinked $PWD only
-- if it still refers to the current directory).
local function same_file(a, b)
  if ffi.C.curse_rt_stat(a, stbuf_a) ~= 0 then return false end
  if ffi.C.curse_rt_stat(b, stbuf_b) ~= 0 then return false end
  return ffi.cast("uint64_t *", stbuf_a)[0] == ffi.cast("uint64_t *", stbuf_b)[0]        -- st_dev @0
     and ffi.cast("uint64_t *", stbuf_a + 8)[0] == ffi.cast("uint64_t *", stbuf_b + 8)[0] -- st_ino @8
end
-- Resolve a bare command NAME to an absolute path via $PATH — the first
-- executable, non-directory match (like execvp) — and cache it (bash's command
-- hash). The cache survives filesystem changes under a STABLE $PATH (only
-- `hash -r` clears it then), but CHANGING $PATH invalidates it — bash rehashes.
function Shell:resolve_cmd(name)
  local curpath = self:get("PATH")
  if self.hashpath and self.hashpath ~= curpath then self.hashcache = {} end -- PATH changed: rehash
  self.hashpath = curpath
  local c = self.hashcache and self.hashcache[name]
  if c then c.hits = c.hits + 1; return c.path end
  for dir in (curpath .. ":"):gmatch("([^:]*):") do
    local cand = (dir == "" and "." or dir) .. "/" .. name
    if ffi.C.access(cand, 1) == 0 and ffi.C.curse_rt_stat(cand, stbuf_a) == 0 -- 1 == X_OK
        and bit.band(ffi.cast("uint32_t *", stbuf_a + 24)[0], 0xF000) ~= 0x4000 then -- not a dir
      self.hashcache = self.hashcache or {}
      self.hashcache[name] = { path = cand, hits = 1 }
      return cand
    end
  end
  return nil
end
function Shell:phys_cwd()
  local p = ffi.C.getcwd(scratch, 4096); return p ~= nil and ffi.string(p) or ""
end
-- Logical current directory: the tracked $PWD (may keep a symlinked name), else
-- the physical cwd. `pwd`, `cd`'s bookkeeping, tilde `~+` and prompts use this.
function Shell:pwd()
  local b = self.vars["PWD"]
  if b and b.s and b.s ~= "" then return b.s end
  return self:phys_cwd()
end
local pid_cache
function Shell:pid() if not pid_cache then pid_cache = tonumber(ffi.C.getpid()) end return pid_cache end
function Shell:special_get(name)
  -- $# as a base value for an operator form (`${##2}` = $# with a `#2` strip); the
  -- bare ${#}/${#@} count and ${#var} length go through their own dedicated nodes.
  if name == "#" then return tostring(self.nparams) end
  if name == "RANDOM" then return tostring(math.random(0, 32767)) end
  -- $PWD is a real tracked variable (see :pwd / import_env); once unset it reads
  -- empty like any other var, so special_get does NOT fall back to getcwd here.
  if name == "PPID" then return tostring(tonumber(ffi.C.getppid())) end
  if name == "UID" then return tostring(tonumber(ffi.C.getuid())) end
  if name == "EUID" then return tostring(tonumber(ffi.C.geteuid())) end
  if name == "BASHPID" then return tostring(tonumber(ffi.C.getpid())) end -- fresh: changes in subshells
  if name == "FUNCNAME" then return (self.funcstack and self.funcstack[1]) or "" end
  if name == "BASH_SOURCE" then return self:bash_source_array()[1] or "" end -- [0]: current source
  if name == "BASH_LINENO" then return self:bash_lineno_array()[1] or "0" end -- [0]: caller's line
  if name == "SHELLOPTS" and self.shellopts then return self:shellopts() end -- live set -o list
  if name == "BASHOPTS" and self.bashopts then return self:bashopts() end -- live shopt list
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
  local seen
  for _ = 1, 100 do
    local b = self.vars[name]
    if not b or not b.ref or b.s == nil or b.s == "" then return name end
    local t = b.s
    local br = t:find("[", 1, true)
    local tname = br and t:sub(1, br - 1) or t
    -- An invalid target name (e.g. `#`, `1`, `$1`) isn't a real reference: reading
    -- the nameref yields its own stored string, so resolve to the nameref itself.
    if not tname:match("^[%a_][%w_]*$") then return name end
    -- mutually recursive namerefs (ref1->ref2->ref1) resolve to nothing in bash
    if seen and seen[tname] then return "" end
    seen = seen or {}; seen[name] = true
    name = tname
  end
  return name
end
-- Mark `name` as a nameref (declare -n); target is the referenced variable name.
-- A nameref target (when one is given) must be a plain identifier, optionally
-- with a subscript (`ref`, `a[0]`, `a[@]`); bash rejects `@`, `*`, `1`, `a b`,
-- `a-b`, empty, … as "invalid variable name for name reference". Returns false
-- (leaving the var untouched) so the caller can report the error + status 1. A
-- nil target (`typeset -n ref` converting an existing var) is NOT validated.
function Shell:make_nameref(name, target)
  local function valid(t) return t:match("^[%a_][%w_]*$") or t:match("^[%a_][%w_]*%[.+%]$") end
  if target ~= nil then
    if not valid(target) then return false end -- explicit target (empty/@/*/1/… rejected)
  else
    -- converting an existing var: its current value becomes the target — bash
    -- rejects the conversion if that value is not a valid target (a non-empty
    -- invalid one; an unset/empty var makes a valid deferred nameref).
    local b = self.vars[name]
    if b and b.s and b.s ~= "" and not valid(b.s) then return false end
  end
  local b = box(name, self.vars); b.ref = true
  if target ~= nil then b.s = target; b.n = nil; b.arr = nil end
  return true
end
function Shell:unref(name) local b = self.vars[name]; if b then b.ref = nil end end
function Shell:is_nameref(name) local b = self.vars[name]; return b and b.ref end
-- ${var@a}: the variable's attribute flags, in bash's order (aA r x i l u n).
function Shell:attr_string(name)
  local b = self.vars[self:deref(name)]
  if not b then return "" end
  local s = ""
  if b.assoc then s = s .. "A" elseif b.arr then s = s .. "a" end
  if b.ro then s = s .. "r" end
  if b.exported then s = s .. "x" end
  if b.int then s = s .. "i" end
  if b.lower then s = s .. "l" end
  if b.upper then s = s .. "u" end
  if b.ref then s = s .. "n" end
  return s
end

-- String value of a var (materialize from the cached int64 if needed).
function Shell:get(name)
  name = self:deref(name)
  local b = self.vars[name]
  if b == nil then return self:special_get(name) end
  -- $a == ${a[0]}: indexed arrays key on the number 0; assoc arrays on "0".
  if b.arr then return (b.assoc and b.arr["0"] or b.arr[0]) or "" end
  if b.s == nil then
    if b.n == nil then return "" end
    b.s = i64_to_str(b.n)
  end
  return b.s
end

-- Like :get, but enforces `set -u` (nounset) for a user-level $var reference.
-- The compiled backend uses this for word expansion so it matches the interp,
-- which checks nounset at the same point. (:get itself is used for internal
-- reads like IFS/HOME that must not trip nounset.)
function Shell:get_u(name)
  -- A declared-but-value-less box (`local foo` / `declare x`) is still UNSET for
  -- nounset purposes, so treat it like a missing var.
  local b = self.vars[self:deref(name)]
  local unset = b == nil or (b.s == nil and b.n == nil and b.arr == nil)
  if self.opt_u and unset and self:special_get(name) == ""
      and name ~= "@" and name ~= "*" then
    io.stderr:write("curse: " .. name .. ": unbound variable\n"); error({ __curse_exit = self.opt_c and 127 or 1, __curse_lineabort = self.opt_i or nil })
  end
  return self:get(name)
end
-- Capture-aware error write: inside a `$(...)` capture with `2>&1` active, route
-- the message into the capture buffer (self.out) so it's captured like bash;
-- otherwise to real stderr. Mirrors interp's sherr for runtime-side messages.
function Shell:errmsg(msg)
  if self.capturing and (self.err2out or 0) > 0 then self.out(msg) else io.stderr:write(msg) end
end

-- int64 value of a var for arithmetic (use the cache, else parse the string).
function Shell:aget(name)
  name = self:deref(name)
  local b = self.vars[name]
  if b == nil then return i64(0) end
  if b.arr then return M.arith_num(b.arr[0] or b.arr["0"] or "0") end -- decays to [0]/["0"]
  if b.n == nil then b.n = M.arith_num(b.s) end -- arith context: honor bases (0x, 010, N#)
  return b.n
end

-- Locale variables: assigning/unsetting any of these re-applies setlocale (bash).
local LOCALE_VARS = { LANG = 1, LC_ALL = 1, LC_CTYPE = 1, LC_NUMERIC = 1,
  LC_TIME = 1, LC_COLLATE = 1, LC_MONETARY = 1, LC_MESSAGES = 1 }
M.LOCALE_VARS = LOCALE_VARS

function Shell:set_str(name, s)
  if s:find("\0", 1, true) then s = M.cstr(s) end -- bash vars are C strings: cut at NUL
  local dn = self:deref(name)
  local b = box(dn, self.vars)
  b.s = s; b.n = nil
  if b.exported then C.setenv(dn, s, 1) end -- keep the env in sync
  if LOCALE_VARS[dn] then M.reset_locale(self) end -- track the locale live, like bash
end

-- Set a variable AND mark it exported (updating the process env). Used for
-- PWD/OLDPWD, which `cd`/pushd/popd must keep in the environment for children.
function Shell:export_str(name, val)
  self:set_str(name, val); self.vars[name].exported = true; C.setenv(name, val, 1)
end

-- Inherit the process environment as shell variables (bash does this at startup).
-- PWD/OLDPWD are handled specially below: PWD is initialized (and kept logical),
-- OLDPWD inherited if present; `cd` maintains both thereafter.
function Shell:import_env()
  local e = ffi.C.environ
  if e == nil then return end
  local i, env_pwd, env_oldpwd = 0, nil, nil
  while e[i] ~= nil do
    local s = ffi.string(e[i])
    local eq = s:find("=", 1, true)
    if eq then
      local k = s:sub(1, eq - 1)
      if k == "PWD" then env_pwd = s:sub(eq + 1)
      elseif k == "OLDPWD" then env_oldpwd = s:sub(eq + 1)
      elseif k == "UID" or k == "EUID" or k == "PPID" -- shell-computed, not from env
        or k == "BASHOPTS" then -- readonly, derived live from the option state
      elseif k == "SHELLOPTS" then -- inherited set -o options: enable them (bash), keep exported
        self.shellopts_import = s:sub(eq + 1); self.shellopts_exported = true
      elseif k:match("^[%a_][%w_]*$") then
        self:set_str(k, s:sub(eq + 1))
        self.vars[k].exported = true -- inherited env vars are exported (bash)
      end
    end
    i = i + 1
  end
  -- Initialize $PWD: keep an inherited absolute $PWD only if it still names the
  -- current directory (so a symlinked path survives); otherwise use getcwd.
  local phys = self:phys_cwd()
  local pwd = (env_pwd and env_pwd:sub(1, 1) == "/" and same_file(env_pwd, phys)) and env_pwd or phys
  self:set_str("PWD", pwd); self.vars["PWD"].exported = true
  if env_oldpwd then self:set_str("OLDPWD", env_oldpwd); self.vars["OLDPWD"].exported = true end
  -- bash provides a default $PATH when none is inherited (e.g. `unset PATH; sh -c …`).
  if self.vars["PATH"] == nil then
    self:set_str("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
  end
  -- Shell-maintained vars bash always defines even with `env -i` and no rc file.
  if self.vars["IFS"] == nil then self:set_str("IFS", " \t\n") end
  if self.vars["PS4"] == nil then self:set_str("PS4", "+ ") end
  -- $SHELL: bash sets it from the passwd entry (the login shell) when not inherited.
  if self.vars["SHELL"] == nil then
    local pw = ffi.C.getpwuid(ffi.C.geteuid())
    if pw ~= nil and pw.pw_shell ~= nil then self:set_str("SHELL", ffi.string(pw.pw_shell)) end
  end
  -- SHELLOPTS/BASHOPTS are NOT stored: special_get derives them live from the
  -- current set -o / shopt state (and they're readonly), matching bash.
end

-- Arithmetic write: store the int64, defer the string (lazy).
function Shell:aset(name, n)
  local b = box(self:deref(name), self.vars)
  if b.arr then b.arr[b.assoc and "0" or 0] = i64_to_str(i64(n)); return i64(n) end -- (( a = n )) hits a[0]
  b.n = i64(n); b.s = nil
  return b.n
end

-- ---- indexed arrays ----
-- Stored in the var box as b.arr = { [0]=…, [1]=… } (0-based, may be sparse, to
-- match bash). A plain scalar has no b.arr; reading $a is ${a[0]}.
local function arr_max(arr) local m = i64(-1); for k in pairs(arr) do local ki = key_i64(k); if ki > m then m = ki end end; return m end

-- `declare -A name`: mark as associative (string keys, insertion-order iteration —
-- note: real bash iterates in hash order; insertion order matches the common cases).
function Shell:declare_assoc(name)
  local b = box(self:deref(name), self.vars); b.assoc = true; b.arr = b.arr or {}; b.order = b.order or {}
  if b.s ~= nil then b.arr["0"] = b.s; b.order[#b.order + 1] = "0" end -- a scalar becomes [0] (bash)
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
    local mx = (b and b.arr) and arr_max(b.arr) or i64(-1) -- int64 highest index
    return to_arr_key(mx + 1 + key) -- resolve from end, then re-key (number|string)
  end
  return key
end
function Shell:array_set(name, key, val, append)
  if val:find("\0", 1, true) then val = M.cstr(val) end -- C-string element: cut at NUL
  local b = box(self:deref(name), self.vars)
  if not b.arr then b.arr = {}; if b.s then b.arr[0] = b.s end; b.s = nil; b.n = nil end
  key = norm_key(b, key)
  if type(key) == "number" and key < 0 then return false end -- out-of-range negative: bash errors
  if b.assoc and b.arr[key] == nil then b.order[#b.order + 1] = key end
  if append then b.arr[key] = (b.arr[key] or "") .. val else b.arr[key] = val end
  return true
end
-- FUNCNAME is a virtual array: the call stack innermost-first, then "main"
-- (empty at the top level). funcstack[1] is the innermost function.
function Shell:funcname_array()
  local fs = self.funcstack
  if not fs or #fs == 0 then return {} end
  local t = {}
  for i = 1, #fs do t[i] = fs[i] end
  -- a script (or stdin) has a "main" bottom frame; `sh -c` has none (bash).
  if not self.opt_c then t[#t + 1] = "main" end
  return t
end
-- ${BASH_SOURCE[@]} / ${BASH_LINENO[@]}: parallel to the call stack. BASH_SOURCE[0]
-- is the current source; BASH_LINENO[0] is where the current function was called.
-- The bottom frame is the main script / line 0. (Single-file scripts: all the
-- sources are the main script path — curse doesn't track per-function def files.)
function Shell:bash_source_array()
  local t = { self.cur_source or self.argv0 or "" }
  local ss = self.srcstack or {}
  for i = 1, #ss do t[#t + 1] = ss[i] end
  return t
end
function Shell:bash_lineno_array()
  local t = {}
  local ls = self.linestack or {}
  for i = 1, #ls do t[i] = tostring(ls[i]) end
  t[#t + 1] = "0"
  return t
end
local VIRT_ARR = { FUNCNAME = "funcname_array", BASH_SOURCE = "bash_source_array", BASH_LINENO = "bash_lineno_array" }
function Shell:array_get(name, key)
  if VIRT_ARR[name] then return self[VIRT_ARR[name]](self)[(tonumber(key) or 0) + 1] or "" end
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
-- unset a single element a[key]; returns false on an out-of-range negative index
-- (bash: `unset a[-2]` on a 1-element array is an error).
function Shell:array_unset(name, key)
  local b = self.vars[self:deref(name)]
  if not (b and b.arr) then return true end
  local k = norm_key(b, key)
  if type(k) == "number" and k < 0 then return false end
  b.arr[k] = nil
  return true
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
  if VIRT_ARR[name] then
    local a = self[VIRT_ARR[name]](self); local t = {}; for i = 1, #a do t[i] = i - 1 end; return t
  end
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
    local t = {}; for k in pairs(b.arr) do t[#t + 1] = k end
    table.sort(t, function(a, z) return key_i64(a) < key_i64(z) end); return t -- int64 order (mixed number/string keys)
  end
  if b and (b.s ~= nil or b.n ~= nil) then return { 0 } end
  return {}
end
function Shell:array_values(name)
  if VIRT_ARR[name] then return self[VIRT_ARR[name]](self) end
  local idx = self:array_indices(name); local t = {}
  for i = 1, #idx do t[i] = self:array_get(name, idx[i]) end
  return t
end
function Shell:array_count(name) return #self:array_indices(name) end

-- ---- parameter expansion ${var OP arg} ----
-- Whole-string glob match via the POSIX regex engine (real char classes/extglob).
-- Deferred to call time through M so it can be defined textually after this.
local function full_match(s, glob)
  if glob:find("!(", 1, true) then return M.ext_match(s, glob) end -- !() needs the split matcher
  return M.regex_match(s, M.glob_to_ere(glob))
end
local function strip_prefix(val, glob, longest)
  if longest then
    for k = #val, 0, -1 do if full_match(val:sub(1, k), glob) then return val:sub(k + 1) end end
  else
    for k = 0, #val do if full_match(val:sub(1, k), glob) then return val:sub(k + 1) end end
  end
  return val
end
local function strip_suffix(val, glob, longest)
  if longest then
    for k = 1, #val + 1 do if full_match(val:sub(k), glob) then return val:sub(1, k - 1) end end
  else
    for k = #val + 1, 1, -1 do if full_match(val:sub(k), glob) then return val:sub(1, k - 1) end end
  end
  return val
end
local function substr(val, off, len)
  -- ${v:off:len} slices by CHARACTER (codepoint) in the locale, like bash — offset
  -- and length count codepoints, not bytes (byte-equivalent under LC_ALL=C).
  local chars = M.mb_chars(val)
  local n = #chars
  local o = tonumber(off) or 0
  if o < 0 then o = n + o end
  if o < 0 then o = 0 end
  local last = n
  if len and len ~= "" then
    local l = tonumber(len) or 0
    last = (l < 0) and (n + l) or (o + l)
  end
  if last > n then last = n end
  local out = {}
  for k = o + 1, last do out[#out + 1] = chars[k].s end
  return table.concat(out)
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
local REG_EXTENDED, REG_NOSUB, REG_ICASE = 1, 8, 2
local regbuf = ffi.new("char[512]") -- opaque regex_t (glibc ~64B; over-allocate)

-- Convert a shell glob to a POSIX ERE, anchored. Char classes carry over (with
-- [!..] -> [^..]); regex-special chars elsewhere are escaped.
-- Split `body` on top-level `|` (respecting nested parens) — extglob arms.
local function split_arms(body)
  local arms, depth, start, k, n = {}, 0, 1, 1, #body
  while k <= n do
    local ch = body:sub(k, k)
    if ch == "\\" then k = k + 2 -- a `\|` (quoted/escaped bar) is literal, not a separator
    elseif ch == "(" then depth = depth + 1; k = k + 1
    elseif ch == ")" then depth = depth - 1; k = k + 1
    elseif ch == "|" and depth == 0 then arms[#arms + 1] = body:sub(start, k - 1); start = k + 1; k = k + 1
    else k = k + 1 end
  end
  arms[#arms + 1] = body:sub(start)
  return arms
end
-- Convert a glob (incl. extglob ?(..) *(..) +(..) @(..) !(..)) to an ERE body.
local EXTOP = { ["?"] = true, ["*"] = true, ["+"] = true, ["@"] = true, ["!"] = true }
-- `pn` (pathname mode): `*`/`?` do NOT cross `/` (for GLOBIGNORE matching against
-- a whole path). Default (case globs, per-segment expansion) lets them match `/`.
local function glob_conv(glob, pn)
  local star = pn and "[^/]*" or ".*"
  local qmark = pn and "[^/]" or "."
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
      for _, a in ipairs(arms) do conv[#conv + 1] = glob_conv(a, pn) end
      local group = "(" .. table.concat(conv, "|") .. ")"
      -- @ = exactly one; ? = 0/1; * = 0+; + = 1+; ! ≈ group (POSIX ERE can't negate)
      out[#out + 1] = (c == "?" and group .. "?") or (c == "*" and group .. "*")
        or (c == "+" and group .. "+") or group
      i = j + 1
    elseif c == "\\" then -- backslash escapes the next char -> match it literally
      local nc = glob:sub(i + 1, i + 1)
      if nc == "" then out[#out + 1] = "\\\\"; i = i + 1
      else out[#out + 1] = (nc:match("[%w]") and nc or ("\\" .. nc)); i = i + 2 end
    elseif c == "*" then out[#out + 1] = star; i = i + 1
    elseif c == "?" then out[#out + 1] = qmark; i = i + 1
    elseif c == "[" then
      local j, neg, has_rb, members = i + 1, false, false, {}
      if glob:sub(j, j) == "!" or glob:sub(j, j) == "^" then neg = true; j = j + 1 end
      if glob:sub(j, j) == "]" then has_rb = true; j = j + 1 end -- leading ] is a literal member
      while j <= n and glob:sub(j, j) ~= "]" do
        local cj, nx = glob:sub(j, j), glob:sub(j + 1, j + 1)
        if cj == "\\" then -- inside [...], `\` escapes the next char (bash); `\]` is a literal ]
          if nx == "]" then has_rb = true; j = j + 2
          elseif nx == "" then members[#members + 1] = "\\"; j = j + 1
          else members[#members + 1] = nx; j = j + 2 end -- ERE: backslash isn't special in a class
        elseif cj == "[" and (nx == ":" or nx == "." or nx == "=") then
          -- POSIX [:class:] / [.coll.] / [=equiv=]: copy through its own close
          local e = glob:find(nx .. "]", j + 2, true)
          if e then members[#members + 1] = glob:sub(j, e + 1); j = e + 2
          else members[#members + 1] = cj; j = j + 1 end
        else members[#members + 1] = cj; j = j + 1 end
      end
      if glob:sub(j, j) ~= "]" then
        -- no closing ] : bash treats the `[` as a literal character (not a class)
        out[#out + 1] = "\\["; i = i + 1
      else
        -- ERE class: a literal ] must come FIRST (right after [ or [^).
        out[#out + 1] = "[" .. (neg and "^" or "") .. (has_rb and "]" or "") .. table.concat(members) .. "]"
        i = j + 1
      end
    elseif c:match("[%.%+%(%)%{%}%|%^%$\\]") then out[#out + 1] = "\\" .. c; i = i + 1
    else out[#out + 1] = c; i = i + 1 end
  end
  return table.concat(out)
end
local function glob_to_ere(glob, pn)
  return "^" .. glob_conv(glob, pn) .. "$"
end
M.glob_to_ere = glob_to_ere -- exposed for strip_prefix/suffix (defined earlier)
-- GLOBIGNORE match: `glob` matched against a whole path with `/`-aware wildcards.
function M.glob_ignore_match(path, glob)
  return M.regex_match(path, glob_to_ere(glob, true))
end

-- Match `s` against a POSIX ERE. `anchored_glob` false = raw ERE (=~), true = a
-- glob already converted to an anchored ERE. Returns boolean.
function M.regex_match(s, ere, icase)
  if ffi.C.regcomp(regbuf, ere, REG_EXTENDED + REG_NOSUB + (icase and REG_ICASE or 0)) ~= 0 then return false end
  local rc = ffi.C.regexec(regbuf, s, 0, nil, 0)
  ffi.C.regfree(regbuf)
  return rc == 0
end
local function split_alts(s) -- top-level `|` split (paren/bracket-aware)
  local alts, depth, cur, i, n = {}, 0, {}, 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == "\\" then cur[#cur + 1] = s:sub(i, i + 1); i = i + 2
    elseif c == "(" or c == "[" then depth = depth + 1; cur[#cur + 1] = c; i = i + 1
    elseif c == ")" or c == "]" then depth = depth - 1; cur[#cur + 1] = c; i = i + 1
    elseif c == "|" and depth == 0 then alts[#alts + 1] = table.concat(cur); cur = {}; i = i + 1
    else cur[#cur + 1] = c; i = i + 1 end
  end
  alts[#alts + 1] = table.concat(cur)
  return alts
end
-- Whole-string extglob match with backtracking. Handles the extended operators
-- `@()/?()/*()/+()/!()` at ANY nesting depth (POSIX ERE can't express `!()`
-- negation, and a `!()` nested inside another group needs a real matcher, not the
-- ERE conversion) — literals / `*` / `?` / `[…]` are matched positionally too so
-- it composes with the operators. Used only for patterns containing `!(`; plain
-- extglob still goes through the faster glob_to_ere path.
function M.ext_match(str, pat, icase)
  local plen, slen = #pat, #str
  local ceq = icase and function(a, b) return a:lower() == b:lower() end or function(a, b) return a == b end
  -- index of the `)` closing an extglob group whose op is at `gi` (`(` at gi+1)
  local function group_end(gi)
    local d, j = 1, gi + 2
    while j <= plen do
      local cc = pat:sub(j, j)
      if cc == "\\" then j = j + 2
      elseif cc == "(" then d = d + 1; j = j + 1
      elseif cc == ")" then d = d - 1; if d == 0 then return j end; j = j + 1
      else j = j + 1 end
    end
    return j
  end
  local m -- does pat[pi..] match str[si..slen] EXACTLY?
  m = function(si, pi)
    if pi > plen then return si > slen end
    local c, nc = pat:sub(pi, pi), pat:sub(pi + 1, pi + 1)
    if EXTOP[c] and nc == "(" then
      local ge = group_end(pi)
      local alts = split_alts(pat:sub(pi + 2, ge - 1))
      local rest = ge + 1
      local function altfull(seg) for _, a in ipairs(alts) do if M.ext_match(seg, a, icase) then return true end end return false end
      if c == "@" then
        for j = si - 1, slen do if altfull(str:sub(si, j)) and m(j + 1, rest) then return true end end
      elseif c == "?" then
        if m(si, rest) then return true end
        for j = si, slen do if altfull(str:sub(si, j)) and m(j + 1, rest) then return true end end
      elseif c == "!" then
        for j = si - 1, slen do if not altfull(str:sub(si, j)) and m(j + 1, rest) then return true end end
      else -- `*` (zero or more) or `+` (one or more)
        local function rep(pos, count)
          if (c == "*" or count >= 1) and m(pos, rest) then return true end
          for j = pos, slen do if altfull(str:sub(pos, j)) and rep(j + 1, count + 1) then return true end end
          return false
        end
        return rep(si, 0)
      end
      return false
    elseif c == "\\" then
      return si <= slen and ceq(str:sub(si, si), nc) and m(si + 1, pi + 2)
    elseif c == "*" then
      for j = si - 1, slen do if m(j + 1, pi + 1) then return true end end
      return false
    elseif c == "?" then
      return si <= slen and m(si + 1, pi + 1)
    elseif c == "[" then
      local j = pi + 1
      if pat:sub(j, j) == "!" or pat:sub(j, j) == "^" then j = j + 1 end
      if pat:sub(j, j) == "]" then j = j + 1 end
      while j <= plen and pat:sub(j, j) ~= "]" do j = j + 1 end
      if pat:sub(j, j) ~= "]" then -- unclosed `[` is a literal `[`
        return si <= slen and str:sub(si, si) == "[" and m(si + 1, pi + 1)
      end
      if si <= slen and M.regex_match(str:sub(si, si), "^" .. glob_conv(pat:sub(pi, j)) .. "$", icase) then
        return m(si + 1, j + 1)
      end
      return false
    else
      return si <= slen and ceq(str:sub(si, si), c) and m(si + 1, pi + 1)
    end
  end
  return m(1, 1)
end
-- Count capturing groups `(…)` in a POSIX ERE (= regex_t.re_nsub) so BASH_REMATCH
-- reports one slot per group even when the matched alternative skipped some. A `(`
-- doesn't count when backslash-escaped or inside a `[…]` bracket expression.
local function count_groups(ere)
  local n, i, len = 0, 1, #ere
  while i <= len do
    local c = ere:sub(i, i)
    if c == "\\" then i = i + 2
    elseif c == "[" then -- skip a bracket expression: ] is literal right after [ or [^
      i = i + 1
      if ere:sub(i, i) == "^" then i = i + 1 end
      if ere:sub(i, i) == "]" then i = i + 1 end
      while i <= len and ere:sub(i, i) ~= "]" do i = i + 1 end
      i = i + 1
    elseif c == "(" then n = n + 1; i = i + 1
    else i = i + 1 end
  end
  return n
end

-- Match with capture groups: returns {whole, grp1, grp2, …} for BASH_REMATCH, or
-- nil on no match / bad regex. (glibc regoff_t is int; regmatch_t is 8 bytes.)
local NMATCH = 100
local pmatch = ffi.new("struct { int rm_so; int rm_eo; }[?]", NMATCH)
function M.regex_captures(s, ere, icase)
  -- second return = "invalid regex" (regcomp failed): [[ =~ ]] must report status
  -- 2 for that, distinct from a valid regex that simply does not match (nil, nil).
  if ffi.C.regcomp(regbuf, ere, REG_EXTENDED + (icase and REG_ICASE or 0)) ~= 0 then return nil, true end
  local rc = ffi.C.regexec(regbuf, s, NMATCH, pmatch, 0)
  ffi.C.regfree(regbuf)
  if rc ~= 0 then return nil end
  -- bash's BASH_REMATCH holds group 0 (whole) plus every capturing group, with
  -- non-participating groups as "" — so report up to re_nsub, not just the last
  -- group that happened to match.
  local hi = count_groups(ere)
  if hi > NMATCH - 1 then hi = NMATCH - 1 end
  local caps = {}
  for i = 0, hi do
    local so = pmatch[i].rm_so
    caps[#caps + 1] = (so >= 0) and s:sub(so + 1, pmatch[i].rm_eo) or ""
  end
  return caps
end

-- Full (anchored) shell-glob match, for `case` patterns.
function M.glob_match(s, glob, icase)
  if glob:find("!(", 1, true) then return M.ext_match(s, glob, icase) end -- !() needs the split matcher
  return M.regex_match(s, glob_to_ere(glob), icase)
end

local REG_NOTBOL = 1
-- ${v/pat/repl} and ${v//pat/repl}: substitute glob matches using the POSIX
-- regex engine (real char classes, extglob, leftmost-longest), not weak Lua
-- patterns. `all` replaces every match; a leading # / % on `glob` anchors the
-- match at the start / end. An empty pattern is a no-op (matches bash).
function M.subst_glob(val, glob, repl, all)
  local anchor
  if glob:sub(1, 1) == "#" then glob = glob:sub(2); anchor = "^"
  elseif glob:sub(1, 1) == "%" then glob = glob:sub(2); anchor = "$" end
  if glob == "" then -- empty pattern: no-op, except an anchored one inserts repl
    if anchor == "^" then return repl .. val elseif anchor == "$" then return val .. repl end
    return val
  end
  local ere = glob_conv(glob)
  if anchor == "^" then ere = "^(" .. ere .. ")"
  elseif anchor == "$" then ere = "(" .. ere .. ")$"
  else ere = "(" .. ere .. ")" end
  if ffi.C.regcomp(regbuf, ere, REG_EXTENDED) ~= 0 then return val end
  local out, pos, n, prev_end = {}, 0, #val, -1
  while pos <= n do
    local sub = val:sub(pos + 1)
    if ffi.C.regexec(regbuf, sub, 1, pmatch, pos > 0 and REG_NOTBOL or 0) ~= 0 then break end
    local so, eo = pmatch[0].rm_so, pmatch[0].rm_eo
    if eo == so and pos + so == prev_end then
      -- an EMPTY match right where the previous match ended (e.g. `.*` matched to
      -- the end, then matches empty again): don't replace, just carry one char.
      out[#out + 1] = sub:sub(1, so + 1); pos = pos + so + 1
    else
      out[#out + 1] = sub:sub(1, so) -- text before the match
      out[#out + 1] = repl
      prev_end = pos + eo
      if eo > so then pos = pos + eo
      else out[#out + 1] = sub:sub(eo + 1, eo + 1); pos = pos + eo + 1 end -- empty match: keep one char
      if not all or anchor then out[#out + 1] = val:sub(pos + 1); ffi.C.regfree(regbuf); return table.concat(out) end
    end
  end
  ffi.C.regfree(regbuf)
  out[#out + 1] = val:sub(pos + 1)
  return table.concat(out)
end

-- Scan one directory for entries matching a single glob segment. `dir` is the
-- directory to open ("" == cwd). Returns a list of matching base names (unsorted).
-- `dotglob` controls whether names beginning with `.` match a non-`.`-initial glob.
local function scan_seg(dir, seg, dotglob, skipdots)
  local scan = (dir == "" and ".") or dir
  local d = ffi.C.opendir(scan); if d == nil then return {} end
  -- a `!()` segment needs the split matcher (per entry); everything else uses one
  -- precompiled ERE.
  local neg = seg:find("!(", 1, true) ~= nil
  if not neg then
    if ffi.C.regcomp(regbuf, glob_to_ere(seg), REG_EXTENDED + REG_NOSUB) ~= 0 then ffi.C.closedir(d); return {} end
  end
  local hidden = seg:sub(1, 1) == "."
  skipdots = skipdots ~= false -- default: skip . and .. (globskipdots on)
  local out = {}
  while true do
    local e = ffi.C.readdir(d); if e == nil then break end
    local name = ffi.string(ffi.cast("const char *", e) + 19) -- d_name @ 19 (glibc x86-64)
    -- . and .. are matched only by an explicit leading-dot pattern with
    -- globskipdots off; a leading-dot name otherwise needs `.`-pattern or dotglob.
    local dotdot = name == "." or name == ".."
    if (not dotdot or (not skipdots and hidden)) and (name:sub(1, 1) ~= "." or hidden or dotglob) then
      local m
      if neg then m = M.ext_match(name, seg) -- (explicit if: a false ext_match must NOT fall to regexec on an uncompiled regbuf)
      else m = ffi.C.regexec(regbuf, name, 0, nil, 0) == 0 end
      if m then out[#out + 1] = name end
    end
  end
  if not neg then ffi.C.regfree(regbuf) end
  ffi.C.closedir(d)
  return out
end

local stbuf_g = ffi.new("uint8_t[144]")
local function is_dir(path)
  if ffi.C.curse_rt_stat(path == "" and "." or path, stbuf_g) ~= 0 then return false end
  return bit.band(ffi.cast("uint32_t *", stbuf_g + 24)[0], 0xF000) == 0x4000
end
-- globstar `**`: every directory at or under `base` (recursively), including base
-- itself (the zero-level case) — the prefixes an intermediate `**/` descends into.
local function rec_dirs(base, dotglob)
  local out = { base }
  local d = ffi.C.opendir(base == "" and "." or base); if d == nil then return out end
  while true do
    local e = ffi.C.readdir(d); if e == nil then break end
    local name = ffi.string(ffi.cast("const char *", e) + 19)
    if name ~= "." and name ~= ".." and (name:sub(1, 1) ~= "." or dotglob) then
      local path = base == "" and name or (base == "/" and "/" .. name or base .. "/" .. name)
      if is_dir(path) then for _, sd in ipairs(rec_dirs(path, dotglob)) do out[#out + 1] = sd end end
    end
  end
  ffi.C.closedir(d)
  return out
end
-- Pathname (glob) expansion: return the sorted matching paths for `pattern`, or
-- nil if none (bash default: the word stays literal). Multi-level patterns
-- (`*/*.c`, `dir/*/x`) are expanded segment by segment; a glob segment that
-- isn't the last must resolve to a directory to descend. `opts.dotglob` makes
-- `*`/`?` also match leading-dot names (set by dotglob / a non-null GLOBIGNORE).
function M.glob_expand(pattern, opts)
  opts = opts or {}
  if not (pattern:find("[*?%[]") or pattern:find("[?*+@!]%(")) then return nil end
  local abs = pattern:sub(1, 1) == "/"
  local segs = {}
  for s in pattern:gmatch("[^/]+") do segs[#segs + 1] = s end
  if #segs == 0 then return nil end
  local cur = { abs and "/" or "" } -- accumulated path prefixes (dir, "" == cwd)
  for si, seg in ipairs(segs) do
    local isglob = seg:find("[*?%[]") or seg:find("[?*+@!]%(")
    local islast = si == #segs
    local nxt = {}
    local function joined(base, name)
      if base == "" then return name elseif base == "/" then return "/" .. name
      else return base .. "/" .. name end
    end
    if seg == "**" and opts.globstar and not islast then
      -- an intermediate `**/` matches zero or more directory levels
      for _, base in ipairs(cur) do
        for _, dir in ipairs(rec_dirs(base, opts.dotglob)) do nxt[#nxt + 1] = dir end
      end
    elseif not isglob then
      -- literal segment: append; a nonexistent intermediate dir yields nothing
      -- next round (opendir fails), so no explicit stat needed.
      for _, base in ipairs(cur) do nxt[#nxt + 1] = joined(base, seg) end
    else
      for _, base in ipairs(cur) do
        local hits = scan_seg(base, seg, opts.dotglob, opts.skipdots)
        table.sort(hits, M.coll_lt) -- glob results sort by LC_COLLATE (bash)
        for _, name in ipairs(hits) do nxt[#nxt + 1] = joined(base, name) end
      end
    end
    cur = nxt
    if #cur == 0 then return nil end
  end
  if #cur == 0 then return nil end
  table.sort(cur, M.coll_lt)
  -- dedup: multiple `**` segments can reach the same path more than once
  local seen, dedup = {}, {}
  for _, p in ipairs(cur) do if not seen[p] then seen[p] = true; dedup[#dedup + 1] = p end end
  return dedup
end

-- Field engine, SPLIT path. The compiled tiers call this on the already-computed
-- VALUE of a SINGLE unquoted expansion (`$list`, `$(cmd)`, `$((expr))`, `${a[@]}`),
-- or on an unquoted glob LITERAL (`*.txt`). It is the genuine-compilation twin of
-- interp's expand_to_fields: emitted native code computes the operand string, then
-- this primitive performs the two runtime-dependent steps that CANNOT be decided at
-- compile time — IFS word-splitting and pathname (glob) expansion. `split=true` for
-- an unquoted expansion (split on $IFS, then glob each field); `split=false` for a
-- literal glob (no splitting — a literal is never word-split — just glob). Because
-- the whole value came from ONE unquoted source, every char is split- and
-- glob-active (no per-char quote mask needed). Kept byte-for-byte in lockstep with
-- expand_to_fields' feed_split + glob tail (interp.lua).
function M.field_split(sh, value, split)
  local fields
  if split then
    -- word-split on $IFS. IFS is a SET of chars; a delimiter may be multibyte
    -- (`IFS=ç`), so index by whole codepoint. Whitespace runs collapse, and a single
    -- non-whitespace delimiter (optionally surrounded by whitespace) ends a field.
    fields = {}
    local ifs = sh.vars["IFS"] and sh:get("IFS") or " \t\n"
    local ifsset = {}; for _, ch in ipairs(M.mb_chars(ifs)) do ifsset[ch.s] = true end
    local mbifs = M.lc_mb_cur_max() > 1 and ifs:find("[\128-\255]") ~= nil
    local function isws(c) return c == " " or c == "\t" or c == "\n" end
    local function inifs(c) return c ~= "" and ifsset[c] end
    local function clen(v, i)
      if not mbifs or v:byte(i) < 0x80 then return 1 end
      return M.mb_charlen(v, i)
    end
    local cur = nil
    local function brk() if cur ~= nil then fields[#fields + 1] = cur; cur = nil end end
    local v = value
    local i, n = 1, #v
    while i <= n do
      local cl = clen(v, i)
      local c = cl == 1 and v:sub(i, i) or v:sub(i, i + cl - 1)
      if inifs(c) then
        if isws(c) then
          if cur ~= nil then brk() end
          i = i + 1
          while i <= n and isws(v:sub(i, i)) do i = i + 1 end
          if i <= n then
            local nl = clen(v, i); local nc = nl == 1 and v:sub(i, i) or v:sub(i, i + nl - 1)
            if inifs(nc) and not isws(nc) then
              i = i + nl; while i <= n and isws(v:sub(i, i)) do i = i + 1 end
            end
          end
        else
          if cur == nil then cur = "" end
          brk()
          i = i + cl
          while i <= n and isws(v:sub(i, i)) do i = i + 1 end
        end
      else
        cur = (cur or "") .. c; i = i + cl
      end
    end
    brk()
  else
    fields = { value }
  end
  -- pathname expansion on each field (all glob-active; nothing quoted).
  local out = {}
  local gi = sh:get("GLOBIGNORE")
  local gi_exists = sh.vars[sh:deref("GLOBIGNORE")] ~= nil
  local giset = gi_exists and gi ~= ""
  local dotglob = gi_exists or (sh.shopt.dotglob and true)
  local nullglob = sh.shopt.nullglob and true
  local gipats
  if giset then -- split on ':' but NOT inside [...]
    gipats = {}
    local depth, curp = 0, {}
    for k = 1, #gi do
      local c = gi:sub(k, k)
      if c == "[" then depth = depth + 1; curp[#curp + 1] = c
      elseif c == "]" then if depth > 0 then depth = depth - 1 end; curp[#curp + 1] = c
      elseif c == ":" and depth == 0 then if #curp > 0 then gipats[#gipats + 1] = table.concat(curp); curp = {} end
      else curp[#curp + 1] = c end
    end
    if #curp > 0 then gipats[#gipats + 1] = table.concat(curp) end
  end
  local noglob = sh.opt_f -- set -f: pathname expansion disabled
  -- globskipdots defaults ON, globstar defaults OFF (SHOPT_DEFAULT, interp.lua).
  local skipdots = giset or (sh.shopt.globskipdots ~= false)
  local globstar = sh.shopt.globstar and true
  local function glob_active(s)
    for i = 1, #s do
      local c = s:sub(i, i)
      if c == "*" or c == "?" or c == "[" then return true end
      if (c == "?" or c == "*" or c == "+" or c == "@" or c == "!") and s:sub(i + 1, i + 1) == "(" then return true end
    end
    return false
  end
  for _, s in ipairs(fields) do
    if not noglob and glob_active(s) then
      local m = M.glob_expand(s, { dotglob = dotglob, skipdots = skipdots, globstar = globstar })
      if m and gipats then
        local filt = {}
        for _, x in ipairs(m) do
          local ig = false
          for _, gp in ipairs(gipats) do if M.glob_ignore_match(x, gp) then ig = true; break end end
          if not ig then filt[#filt + 1] = x end
        end
        m = (#filt > 0) and filt or nil
      end
      if m then for _, x in ipairs(m) do out[#out + 1] = x end
      elseif sh.shopt.failglob then
        io.stderr:write("curse: no match: " .. s .. "\n")
        error({ __curse_exit = 1, __curse_lineabort = true })
      elseif nullglob then -- drop
      else out[#out + 1] = s end
    else
      out[#out + 1] = s
    end
  end
  return out
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
    -- set-ness (for the no-colon - / + ops) is PRESENCE, not non-emptiness: an
    -- element holding "" is set, so ${a[0]-def} with a=("") yields "" not def.
    val = self:array_get(name, idxnum or 0); isset = self:is_elem_set(name, idxnum or 0)
  elseif name:match("^%d+$") then
    local nn = tonumber(name); val = self:param(nn); isset = (nn <= self.nparams)
  elseif name == "@" or name == "*" then
    val = self:paramsJoin(" "); isset = self.nparams > 0
  else
    -- "set" means it actually holds a value: a declared-but-valueless var (declare x)
    -- and an EMPTY array (whose [0] is unset) are NOT set, so ${x-default} yields the
    -- default (bash), even though declare -p lists them.
    local b = self.vars[self:deref(name)]
    if b and b.arr then isset = b.arr[0] ~= nil or b.arr["0"] ~= nil
    else isset = b ~= nil and (b.s ~= nil or b.n ~= nil) end
    isset = isset or self:special_get(name) ~= ""
    val = self:get(name)
  end
  -- The default/alternate word for the test ops arrives as a thunk (lazy: only
  -- expanded when its branch is taken, so a side-effecting default runs at most once).
  local function A() if type(arg) == "function" then return arg() end return arg or "" end
  -- set -u (nounset): a bare reference to an unset variable errors and exits. The
  -- unset-handling ops (:- - :+ + := = :? ?) and $@/$* are exempt.
  if self.opt_u and not isset and not (name == "@" or name == "*")
    and index ~= "@" and index ~= "*"
    and op ~= ":-" and op ~= "-" and op ~= ":+" and op ~= "+"
    and op ~= ":=" and op ~= "=" and op ~= ":?" and op ~= "?"
    and self:special_get(name) == "" then
    io.stderr:write("curse: " .. name .. ": unbound variable\n"); error({ __curse_exit = self.opt_c and 127 or 1, __curse_lineabort = self.opt_i or nil })
  end
  -- := / = write back to the SAME target that was read: an array element when
  -- subscripted (${a[0]=x} must populate a[0]), else the scalar variable.
  local function assign_default(v)
    if index and index ~= "@" and index ~= "*" then self:array_set(name, idxnum or 0, v)
    else
      -- a bare name that IS an array writes element 0 (bash), not a scalar shadow
      local b = self.vars[self:deref(name)]
      if b and b.arr then self:array_set(name, 0, v) else self:set_str(name, v) end
    end
  end
  if op == "len" then return tostring(M.mb_strlen(val)) end -- ${#v}: codepoints in the locale
  if op == ":-" then return val ~= "" and val or A() end
  if op == "-" then return isset and val or A() end
  if op == ":+" then return val ~= "" and A() or "" end
  if op == "+" then return isset and A() or "" end
  if op == ":=" then if val == "" then local v = A(); assign_default(v); return v end return val end
  if op == "=" then if not isset then local v = A(); assign_default(v); return v end return val end
  if op == ":?" then if val == "" then io.stderr:write("curse: " .. name .. ": " .. A() .. "\n"); error({ __curse_exit = self.opt_c and 127 or 1, __curse_lineabort = self.opt_i or nil }) end return val end
  if op == "?" then if not isset then io.stderr:write("curse: " .. name .. ": " .. A() .. "\n"); error({ __curse_exit = self.opt_c and 127 or 1, __curse_lineabort = self.opt_i or nil }) end return val end
  arg = arg or ""
  if op == "@" then -- ${x@OP} transforms
    -- @a reports the VARIABLE's attributes (e.g. `A` for a declared assoc array),
    -- so it's non-empty even when the scalar view (a[0]) is unset; the other
    -- transforms yield empty on an unset var.
    if arg == "a" then return self:attr_string(name) end
    if not isset then return "" end
    if arg == "A" then return name .. "=" .. M.shell_quote(val) end -- declare-able form
  end
  return self:apply_str_op(op, val, arg, arg2)
end

-- Shell-quote a string so it round-trips through eval (single-quote form).
local shell_quote = M.shell_quote

-- Decode PS1 prompt backslash-escapes (for ${x@P}). Parameter/command expansion
-- of the result is done by the caller (interp) afterward.
-- $- : the current option flags. h/B are always on (like bash); set flags and the
-- -i/-c invocation modes are appended in bash-ish order.
function Shell:dash_flags()
  -- $- in bash's canonical flag order: a b e f h k m n u v x B C i c (h and B are
  -- on by default here). Only flags actually set appear.
  local s = ""
  if self.opt_a then s = s .. "a" end
  if self.opt_b then s = s .. "b" end
  if self.opt_e then s = s .. "e" end
  if self.opt_f then s = s .. "f" end
  s = s .. "h"
  if self.opt_k then s = s .. "k" end
  if self.opt_m then s = s .. "m" end
  if self.opt_n then s = s .. "n" end
  if self.opt_u then s = s .. "u" end
  if self.opt_v then s = s .. "v" end
  if self.opt_x then s = s .. "x" end
  s = s .. "B"
  if self.opt_C then s = s .. "C" end
  if self.opt_i then s = s .. "i" end
  if self.opt_c then s = s .. "c" end
  return s
end

-- System hostname (for \h/\H): $HOSTNAME if set, else /proc/sys/kernel/hostname.
local _hostname
function M.hostname()
  if _hostname then return _hostname end
  _hostname = os.getenv("HOSTNAME")
  if not _hostname or _hostname == "" then
    local f = io.open("/proc/sys/kernel/hostname", "r")
    if f then _hostname = (f:read("*l") or ""):gsub("%s+$", ""); f:close() end
  end
  if not _hostname or _hostname == "" then _hostname = "localhost" end
  return _hostname
end
function Shell:prompt_escapes(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == "\\" then
      local d = s:sub(i + 1, i + 1)
      local simple = ({ a = "\7", e = "\27", n = "\n", r = "\r", ["\\"] = "\\",
        ["$"] = (self:special_get("EUID") == "0" and "#" or "$"), t = os.date("%H:%M:%S"),
        T = os.date("%I:%M:%S"), ["@"] = os.date("%I:%M %p"), A = os.date("%H:%M"),
        d = os.date("%a %b %d"), s = self.shellname or "bash", v = "5.2", V = "5.2.0", ["!"] = "1", ["#"] = "1", j = "0" })[d]
      if d == "[" or d == "]" then i = i + 2 -- non-printing markers: drop
      elseif d == "l" then -- basename of the controlling tty, or "tty" when none (bash)
        local tn = C.isatty(0) == 1 and C.ttyname(0) or nil
        out[#out + 1] = tn ~= nil and (ffi.string(tn):gsub(".*/", "")) or "tty"; i = i + 2
      elseif d == "w" then out[#out + 1] = self:pwd(); i = i + 2
      elseif d == "W" then out[#out + 1] = (self:pwd():gsub(".*/", "")); i = i + 2
      elseif d == "u" then out[#out + 1] = os.getenv("USER") or "user"; i = i + 2
      elseif d == "h" then out[#out + 1] = M.hostname():gsub("%..*$", ""); i = i + 2
      elseif d == "H" then out[#out + 1] = M.hostname(); i = i + 2
      elseif d == "D" and s:sub(i + 2, i + 2) == "{" then -- \D{strftime}
        local close = s:find("}", i + 3, true)
        local fmt = s:sub(i + 3, (close or i + 2) - 1)
        out[#out + 1] = os.date(fmt ~= "" and fmt or "%X"); i = (close or i + 2) + 1
      elseif simple then out[#out + 1] = simple; i = i + 2
      elseif d:match("[0-7]") then
        local oct = s:match("^[0-7][0-7]?[0-7]?", i + 1)
        out[#out + 1] = string.char(tonumber(oct, 8) % 256); i = i + 1 + #oct
      else out[#out + 1] = "\\" .. d; i = i + 2 end -- unknown escape kept literal
    else out[#out + 1] = c; i = i + 1 end
  end
  return table.concat(out)
end

-- The per-value string-transform operators (pattern strip, substitute, substring,
-- case, and the ${x@OP} transforms). Factored out so ${a[@]OP} can apply per element.
-- Case-fold `val` per the ${x^PAT}/${x,,PAT} rules: `upper` picks the direction,
-- `all` folds every matching char (else only the first). An empty PAT means "any".
local function fold_case(val, pat, upper, all)
  if pat == nil or pat == "" then pat = "?" end
  -- Fold per CHARACTER (codepoint) using the locale's towupper/towlower, exactly
  -- as bash does — so `${x^^}` upcases μ→Μ under a UTF-8 locale, Turkish i→İ under
  -- tr_TR, etc. A bad byte (wc == nil) is left as-is.
  local chars = M.mb_chars(val)
  local out, limit = {}, all and #chars or math.min(1, #chars)
  for k = 1, #chars do
    local ch = chars[k]; local s = ch.s
    if k <= limit and ch.wc and M.glob_match(s, pat) then
      local w2 = upper and M.towupper(ch.wc) or M.towlower(ch.wc)
      if w2 ~= ch.wc then s = M.wc_to_bytes(w2, ch.s) end
    end
    out[k] = s
  end
  return table.concat(out)
end
function Shell:apply_str_op(op, val, arg, arg2)
  arg = arg or ""
  if op == "@" then -- ${x@Q}/@U/@u/@L/@E/@K/@k (bash 5.x transforms)
    if arg == "Q" or arg == "K" or arg == "k" then return shell_quote(val) end
    if arg == "U" then return fold_case(val, "?", true, true) end   -- upcase all (locale)
    if arg == "u" then return fold_case(val, "?", true, false) end  -- upcase first char
    if arg == "L" then return fold_case(val, "?", false, true) end  -- downcase all
    if arg == "E" then return M.ansi_unescape(val) end
    return val
  end
  if op == "#" then return strip_prefix(val, arg, false) end
  if op == "##" then return strip_prefix(val, arg, true) end
  if op == "%" then return strip_suffix(val, arg, false) end
  if op == "%%" then return strip_suffix(val, arg, true) end
  if op == "/" then return M.subst_glob(val, arg, arg2 or "", false) end
  if op == "//" then return M.subst_glob(val, arg, arg2 or "", true) end
  if op == "sub" then return substr(val, arg, arg2) end
  -- ${x^^PAT}/${x,,PAT}: fold every char matching glob PAT (default ? = any);
  -- ${x^PAT}/${x,PAT}: fold only the first char, and only if it matches PAT.
  if op == "^^" or op == ",," then return fold_case(val, arg, op == "^^", true) end
  if op == "^" or op == "," then return fold_case(val, arg, op == "^", false) end
  return val
end

-- Interpret backslash escapes for `echo -e` and ANSI-C `$'…'` quoting.
-- Encode a Unicode code point as UTF-8 bytes (for \u/\U in $'…', echo -e, printf).
function M.utf8_char(cp)
  if cp < 0x80 then return string.char(cp)
  elseif cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
  elseif cp < 0x10000 then return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
  else return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64, 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64) end
end

-- `ansi_c` (true for $'…') enables \cX control chars and \u/\U code points; the
-- default (echo -e) treats \c as "stop output".
-- mode: true = $'…' (\cX ctrl, \NNN octal); "b" = printf %b (\NNN and \0NNN octal,
-- \c stops); nil/false = echo -e (\0NNN octal only — bare \NNN stays literal, \c stops).
function M.ansi_unescape(s, mode)
  local ansi_c = (mode == true)
  local out, i, n = {}, 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == "\\" and i < n then
      local d = s:sub(i + 1, i + 1)
      if ansi_c and d == "c" then -- \cX -> Ctrl-X (code point & 0x1f)
        local x = s:sub(i + 2, i + 2)
        if x == "" then out[#out + 1] = "\\c"; i = i + 2
        else out[#out + 1] = string.char(x:byte() % 32); i = i + 3 end
      elseif d == "u" or d == "U" then -- \uXXXX / \UXXXXXXXX code point (echo -e and $'…')
        local hex = s:match(d == "u" and "^%x%x?%x?%x?" or "^%x%x?%x?%x?%x?%x?%x?%x?", i + 2)
        if hex then
          local cp = tonumber(hex, 16); local u = {}
          if cp < 0x80 then u = { cp }
          elseif cp < 0x800 then u = { 0xC0 + math.floor(cp / 64), 0x80 + cp % 64 }
          elseif cp < 0x10000 then u = { 0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64 }
          else u = { 0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64, 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64 } end
          for _, b in ipairs(u) do out[#out + 1] = string.char(b) end
          i = i + 2 + #hex
        else out[#out + 1] = "\\" .. d; i = i + 2 end
      elseif d == "n" then out[#out + 1] = "\n"; i = i + 2
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
      elseif not ansi_c and d == "0" then -- echo -e / printf %b: \0NNN (0 prefix + up to 3 octal)
        local oct = s:match("^[0-7]?[0-7]?[0-7]?", i + 2) or ""
        out[#out + 1] = string.char(tonumber("0" .. oct, 8) % 256); i = i + 2 + #oct
      elseif d:match("[0-7]") and (ansi_c or mode == "b") then -- \NNN octal ($'…' and %b, NOT echo -e)
        local oct = s:match("^[0-7][0-7]?[0-7]?", i + 1)
        out[#out + 1] = string.char(tonumber(oct, 8) % 256); i = i + 1 + #oct
      elseif d == "c" then return table.concat(out), true -- \c: stop all further output
      else out[#out + 1] = "\\" .. d; i = i + 2 end
    else out[#out + 1] = c; i = i + 1 end
  end
  return table.concat(out)
end

function Shell:echo(...)
  -- echo [-neE] ARGS: -n suppresses the trailing newline, -e interprets backslash
  -- escapes, -E disables them (bash). Same flag handling as the interp echo builtin,
  -- so compiled and interpreted echo agree.
  local n = select("#", ...)
  local args = { ... }
  local j, nonl, esc = 1, false, false
  while j <= n and type(args[j]) == "string" and args[j]:match("^%-[neE]+$") do
    for ch in args[j]:sub(2):gmatch(".") do
      if ch == "n" then nonl = true elseif ch == "e" then esc = true elseif ch == "E" then esc = false end
    end
    j = j + 1
  end
  local buf = {}
  for k = j, n do buf[#buf + 1] = tostring(args[k]) end
  local s = table.concat(buf, " ")
  local stopped
  if esc then s, stopped = M.ansi_unescape(s) end -- \c stops all output (incl. the newline)
  self.out(s); if not nonl and not stopped then self.out("\n") end
  -- bash's echo/printf flush stdout immediately (sh_chkwrite). This makes output
  -- ordering deterministic across a fork — e.g. `echo a & echo b` prints b then a,
  -- because the parent flushes b before the just-forked child is scheduled. Only
  -- when writing to the real fd (not into a $()/pipe capture buffer). A flush
  -- error (e.g. a full disk) is a write error -> status 1, like bash's sh_chkwrite.
  local werr = (self.out == io.write) and not io.flush() -- flush error (e.g. full disk) here
  if werr then self.write_err = true end
  self.status = werr and 1 or 0 -- a write error is status 1, like bash's sh_chkwrite
end

return M
