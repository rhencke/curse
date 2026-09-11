-- Tree-walking interpreter over the AST, mutating the shared `sh`. It starts
-- instantly (no compile) and runs statement-by-statement like bash. At each
-- safepoint — a top-level statement boundary and every loop back-edge — it
-- calls `hook(kind, id)`; the tier driver's hook throws {switch=true, resume=…}
-- when the compiled Lua is ready, unwinding here so execution can jump into the
-- compiled code from exactly this point (state is already in `sh`).
local rt = require("runtime")
local P = require("parser") -- parser has no load-time dep on interp, so this is cycle-safe
local i64 = rt.i64
local ffi = require("ffi")
local u64 = ffi.typeof("uint64_t") -- string.format formats int64_t/uint64_t cdata directly
local bit = require("bit")

local M = {}

-- `set -o NAME` / short-flag maps for the `set` builtin (and shopt -o).
-- Ordered list mirrors bash's `set -o` output order.
local SETOPTS = {
  { "allexport", "opt_a" }, { "braceexpand", "opt_B" }, { "emacs", "opt_emacs" },
  { "errexit", "opt_e" }, { "errtrace", "opt_errtrace" }, { "functrace", "opt_functrace" },
  { "hashall", "opt_h" }, { "histexpand", "opt_H" }, { "history", "opt_history" },
  { "ignoreeof", "opt_ignoreeof" }, { "interactive-comments", "opt_icomments" },
  { "keyword", "opt_k" }, { "monitor", "opt_m" }, { "noclobber", "opt_C" },
  { "noexec", "opt_n" }, { "noglob", "opt_f" }, { "nolog", "opt_nolog" },
  { "notify", "opt_b" }, { "nounset", "opt_u" }, { "onecmd", "opt_t" },
  { "physical", "opt_P" }, { "pipefail", "opt_pipefail" }, { "posix", "opt_posix" },
  { "privileged", "opt_p" }, { "verbose", "opt_v" }, { "vi", "opt_vi" },
  { "xtrace", "opt_x" },
}
local SETOPT = {} -- name -> field
for _, o in ipairs(SETOPTS) do SETOPT[o[1]] = o[2] end
local SETFLAG = { a = "opt_a", B = "opt_B", e = "opt_e", h = "opt_h", H = "opt_H",
  k = "opt_k", m = "opt_m", C = "opt_C", n = "opt_n", f = "opt_f", b = "opt_b",
  u = "opt_u", t = "opt_t", P = "opt_P", v = "opt_v", x = "opt_x", p = "opt_p" }
-- options that default ON (interactive-comments and braceexpand/hashall/histexpand/
-- history are on; emacs is on for the display default). nil field state == off.
local SETDEFAULT = { opt_B = true, opt_h = true, opt_H = true, opt_history = true,
  opt_icomments = true }
local function opt_on(sh, field)
  local v = sh[field]
  if v ~= nil then return v end
  -- emacs line-editing defaults on only for interactive shells.
  if field == "opt_emacs" then return sh.opt_i and true or false end
  return SETDEFAULT[field] or false
end
local function set_opt(sh, field, on)
  sh[field] = on
  -- emacs and vi line-editing modes are mutually exclusive.
  if on and field == "opt_emacs" then sh.opt_vi = false
  elseif on and field == "opt_vi" then sh.opt_emacs = false end
end

-- bash `shopt` options in bash's own listing order, with their default state.
-- Curse doesn't implement most behaviors, but validity + default + on/off display
-- must match bash. sh.shopt[name] overrides the default once set/unset.
local SHOPT_ORDER = {
  "autocd", "assoc_expand_once", "cdable_vars", "cdspell", "checkhash", "checkjobs",
  "checkwinsize", "cmdhist", "compat31", "compat32", "compat40", "compat41",
  "compat42", "compat43", "compat44", "complete_fullquote", "direxpand", "dirspell",
  "dotglob", "execfail", "expand_aliases", "extdebug", "extglob", "extquote",
  "failglob", "force_fignore", "globasciiranges", "globskipdots", "globstar",
  "gnu_errfmt", "histappend", "histreedit", "histverify", "hostcomplete", "huponexit",
  "inherit_errexit", "interactive_comments", "lastpipe", "lithist", "localvar_inherit",
  "localvar_unset", "login_shell", "mailwarn", "no_empty_cmd_completion", "nocaseglob",
  "nocasematch", "noexpand_translation", "nullglob", "patsub_replacement", "progcomp",
  "progcomp_alias", "promptvars", "restricted_shell", "shift_verbose", "sourcepath",
  "varredir_close", "xpg_echo",
}
local SHOPT_DEFAULT = {} -- name -> true (valid); default-on ones map to "on"
for _, n in ipairs(SHOPT_ORDER) do SHOPT_DEFAULT[n] = false end
for _, n in ipairs({ "checkwinsize", "cmdhist", "complete_fullquote", "extquote",
  "force_fignore", "globasciiranges", "globskipdots", "hostcomplete",
  "interactive_comments", "patsub_replacement", "progcomp", "promptvars",
  "sourcepath" }) do SHOPT_DEFAULT[n] = true end
local function shopt_on(sh, name)
  local v = sh.shopt[name]
  if v == nil then return SHOPT_DEFAULT[name] end
  return v
end

-- $SHELLOPTS: sorted colon-list of enabled `set -o` options; $BASHOPTS: same for
-- shopt. bash keeps both live (read-only). Defined here so they share the single
-- SETOPTS/SHOPT tables and opt_on/shopt_on rules. history/histexpand appear only
-- interactively.
function rt.Shell:shellopts()
  local names = {}
  for _, o in ipairs(SETOPTS) do
    local field, on = o[2], nil
    if field == "opt_H" or field == "opt_history" then
      on = (self[field] ~= nil) and self[field] or (self.opt_i and true or false)
    else on = opt_on(self, field) end
    if on then names[#names + 1] = o[1] end
  end
  table.sort(names)
  return table.concat(names, ":")
end
function rt.Shell:bashopts()
  local names = {}
  for _, n in ipairs(SHOPT_ORDER) do if shopt_on(self, n) then names[#names + 1] = n end end
  table.sort(names)
  return table.concat(names, ":")
end

-- Quote a value the way `set`/`declare -p` do: bare if it's all "safe" chars,
-- else single-quoted with embedded quotes escaped as '\''.
local function sq(s)
  if s == "" then return "''" end
  if s:match("^[%w_,.:/@%%+=%-]+$") then return s end
  return rt.shell_quote(s)
end
-- Field-split a line for `read` into exactly `nvars` values. Skips leading IFS
-- whitespace; each field but the last stops at an IFS char (a run of IFS
-- whitespace + at most one IFS non-whitespace is one delimiter); the LAST var
-- gets the verbatim remainder (keeping its interior separators — unlike a
-- re-join) with trailing IFS whitespace stripped.
-- `read` field-splitting. The line may carry CTLESC markers (\1) before each
-- backslash-escaped character (see the read builtin): a marked char is LITERAL —
-- it is part of a field and never a delimiter — and the marker is dropped from
-- the value. Split into an array of {ch, esc} cells, then apply IFS to those.
local function read_split(ifs, line, nvars)
  local wsset, ifsset = {}, {}
  for c in ifs:gmatch(".") do ifsset[c] = true; if c == " " or c == "\t" or c == "\n" then wsset[c] = true end end
  local cells, p, m = {}, 1, #line
  while p <= m do
    local c = line:sub(p, p)
    if c == "\1" and p < m then cells[#cells + 1] = { ch = line:sub(p + 1, p + 1), esc = true }; p = p + 2
    else cells[#cells + 1] = { ch = c, esc = false }; p = p + 1 end
  end
  local n = #cells
  local function isws(k) local c = cells[k]; return c and not c.esc and wsset[c.ch] end
  local function isifs(k) local c = cells[k]; return c and not c.esc and ifsset[c.ch] end
  local function slice(a, b) local t = {}; for k = a, b do t[#t + 1] = cells[k].ch end; return table.concat(t) end
  local i = 1
  while i <= n and isws(i) do i = i + 1 end -- leading IFS whitespace
  local out = {}
  for v = 1, nvars do
    if v == nvars then
      local last = n
      while last >= i and isws(last) do last = last - 1 end -- trailing IFS ws
      out[v] = slice(i, last)
    else
      local s = i
      while i <= n and not isifs(i) do i = i + 1 end
      out[v] = slice(s, i - 1)
      while i <= n and isws(i) do i = i + 1 end -- delimiter: IFS whitespace
      if i <= n and isifs(i) then i = i + 1; while i <= n and isws(i) do i = i + 1 end end -- + one non-ws
    end
  end
  return out
end
-- `set` (no args) one-line rendering of a variable box.
local function fmt_set_var(name, b)
  if b.assoc and b.arr then
    local keys = {}
    for k in pairs(b.arr) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
      local kq = tostring(k):match("^[%w_]+$") and tostring(k) or ('"' .. tostring(k):gsub('"', '\\"') .. '"')
      parts[#parts + 1] = ("[%s]=\"%s\""):format(kq, tostring(b.arr[k]):gsub('"', '\\"'))
    end
    return ("%s=(%s )"):format(name, table.concat(parts, " ")) -- trailing space, like bash
  elseif b.arr then
    local idx = {}
    for k in pairs(b.arr) do idx[#idx + 1] = k end
    table.sort(idx, function(x, y) return tonumber(x) < tonumber(y) end)
    local parts = {}
    for _, i in ipairs(idx) do parts[#parts + 1] = ('[%d]="%s"'):format(tonumber(i), tostring(b.arr[i]):gsub('"', '\\"')) end
    return ("%s=(%s)"):format(name, table.concat(parts, " "))
  else
    return name .. "=" .. sq(b.s ~= nil and b.s or (b.n ~= nil and rt.i64_to_str(b.n) or ""))
  end
end

local function truth(n) return n ~= i64(0) end
local function b2i(b) return b and 1LL or 0LL end
-- ${…} operators whose default/alternate word is expanded lazily (only when used).
local TESTOP = { ["-"] = 1, [":-"] = 1, ["+"] = 1, [":+"] = 1, ["="] = 1, [":="] = 1, ["?"] = 1, [":?"] = 1 }

-- ---- `test` / `[` builtin ----
ffi.cdef [[
  int access(const char *path, int mode);
  int chdir(const char *path);
  int curse_stat(const char *path, void *buf) asm("stat");
  int curse_lstat(const char *path, void *buf) asm("lstat");
  int isatty(int fd);
  int fork(void);
  int dup2(int oldfd, int newfd);
  int dup(int oldfd);
  int open(const char *path, int flags, unsigned int mode);
  int setenv(const char *name, const char *value, int overwrite);
  int unsetenv(const char *name);
  void _exit(int status);
  unsigned int umask(unsigned int mask);
  long read(int fd, void *buf, unsigned long count);
  unsigned long confstr(int name, char *buf, unsigned long len);
  long long strtoll(const char *nptr, char **endptr, int base);
  unsigned long long strtoull(const char *nptr, char **endptr, int base);
  struct curse_passwd { char *pw_name; char *pw_passwd; unsigned int pw_uid; unsigned int pw_gid; char *pw_gecos; char *pw_dir; char *pw_shell; };
  struct curse_passwd *getpwnam(const char *name);
  int sigemptyset(void *set);
  int sigaddset(void *set, int signum);
  int sigprocmask(int how, const void *set, void *oldset);
  int sigtimedwait(const void *set, void *info, const void *timeout);
  struct curse_passwd *getpwent(void);
  void setpwent(void);
  void endpwent(void);
  int kill(int pid, int sig);
  unsigned int geteuid(void);
  unsigned int getegid(void);
  int fcntl(int fd, int cmd, ...);
  struct curse_rlimit { uint64_t rlim_cur; uint64_t rlim_max; };
  int getrlimit(int resource, struct curse_rlimit *rlim);
  int setrlimit(int resource, const struct curse_rlimit *rlim);
  struct curse_timeval { long tv_sec; long tv_usec; };
  int gettimeofday(struct curse_timeval *tv, void *tz);
  struct curse_pollfd { int fd; short events; short revents; };
  int poll(struct curse_pollfd *fds, unsigned long nfds, int timeout);
]]
local C = ffi.C
-- The standard utility PATH (`command -p`), from confstr(_CS_PATH) like bash —
-- typically "/bin:/usr/bin". Cached; falls back if confstr is unavailable.
local _std_path
local function std_path()
  if not _std_path then
    local buf = ffi.new("char[1024]")
    local n = tonumber(C.confstr(0, buf, 1024)) -- _CS_PATH == 0
    _std_path = (n > 1 and n <= 1024) and ffi.string(buf) or "/bin:/usr/bin"
  end
  return _std_path
end
-- Unbuffered one-byte read from a raw fd (for `read`, which must NOT over-read
-- past its delimiter/char count — buffered io.read would swallow the rest of the
-- stream, breaking a subsequent read from the same underlying fd).
local rd1 = ffi.new("char[1]")
local function fd_getc(fd)
  local n = C.read(fd, rd1, 1)
  if n == 1 then return string.char(rd1[0] % 256) end
  return nil -- EOF or error
end
-- `read -t 0`: is a read on `fd` ready (data available OR EOF), so it wouldn't
-- block? poll with a 0 timeout (POLLIN=1); >0 means ready (POLLIN or POLLHUP).
local pollfd1 = ffi.new("struct curse_pollfd[1]")
local function fd_ready(fd)
  pollfd1[0].fd = fd; pollfd1[0].events = 1; pollfd1[0].revents = 0
  return C.poll(pollfd1, 1, 0) > 0
end
local statbuf = ffi.new("uint8_t[144]") -- glibc x86-64 struct stat is 144 bytes
-- Signal name/number normalization for `trap`.
local SIGNUM = { HUP = 1, INT = 2, QUIT = 3, ILL = 4, TRAP = 5, ABRT = 6, BUS = 7,
  FPE = 8, KILL = 9, USR1 = 10, SEGV = 11, USR2 = 12, PIPE = 13, ALRM = 14, TERM = 15,
  CHLD = 17, CONT = 18, STOP = 19, TSTP = 20, TTIN = 21, TTOU = 22, SYS = 31 }
local NUMSIG = {}; for k, v in pairs(SIGNUM) do NUMSIG[v] = k end
-- Real-signal traps: LuaJIT forbids calling Lua from an async C signal handler,
-- so instead of installing one we BLOCK the trapped signal (sigprocmask) and POLL
-- for it synchronously at safepoints with sigtimedwait — running the handler
-- between commands, like bash delivers a trap.
local sigset_poll = ffi.new("uint8_t[128]")  -- glibc sigset_t is 128 bytes
local sigset_one = ffi.new("uint8_t[128]")
local zero_ts = ffi.new("long[2]", 0, 0)     -- struct timespec {0,0} = poll, don't block
local function block_sig(signum, block) -- SIG_BLOCK=0, SIG_UNBLOCK=1
  C.sigemptyset(sigset_one); C.sigaddset(sigset_one, signum)
  C.sigprocmask(block and 0 or 1, sigset_one, nil)
end
-- Human-readable signal descriptions bash prints when a job is killed (`wait`).
local SIGDESC = { [1] = "Hangup", [2] = "Interrupt", [3] = "Quit", [4] = "Illegal instruction",
  [5] = "Trace/breakpoint trap", [6] = "Aborted", [7] = "Bus error", [8] = "Floating point exception",
  [9] = "Killed", [11] = "Segmentation fault", [13] = "Broken pipe", [14] = "Alarm clock", [15] = "Terminated" }
local function canon_sig(s)
  s = s:upper()
  if s == "0" or s == "EXIT" then return "EXIT" end
  if s == "ERR" or s == "DEBUG" or s == "RETURN" then return s end
  s = s:gsub("^SIG", "")
  if s:match("^%d+$") then local nm = NUMSIG[tonumber(s)]; return nm and ("SIG" .. nm) or nil end
  return SIGNUM[s] and ("SIG" .. s) or nil
end
local function sig_order(canon) -- for printing: EXIT=0, then by signal number
  if canon == "EXIT" then return 0 end
  local nm = canon:gsub("^SIG", ""); return SIGNUM[nm] or 99
end

local function file_test(op, path)
  if op == "-e" or op == "-a" then return C.access(path, 0) == 0 end
  if op == "-r" then return C.access(path, 4) == 0 end
  if op == "-w" then return C.access(path, 2) == 0 end
  if op == "-x" then return C.access(path, 1) == 0 end
  if op == "-t" then return C.isatty(tonumber(path) or -1) == 1 end -- fd is a terminal
  -- -h/-L test the link itself (lstat); everything else follows symlinks (stat)
  local statfn = (op == "-h" or op == "-L") and C.curse_lstat or C.curse_stat
  local ok, rc = pcall(statfn, path, statbuf)
  if not ok or rc ~= 0 then return false end
  local mode = ffi.cast("uint32_t *", statbuf + 24)[0] -- st_mode @ offset 24
  local fmt = bit.band(mode, 0xF000)
  if op == "-f" then return fmt == 0x8000 end -- S_IFREG
  if op == "-d" then return fmt == 0x4000 end -- S_IFDIR
  if op == "-b" then return fmt == 0x6000 end
  if op == "-c" then return fmt == 0x2000 end
  if op == "-p" then return fmt == 0x1000 end
  if op == "-S" then return fmt == 0xC000 end
  if op == "-h" or op == "-L" then return fmt == 0xA000 end -- S_IFLNK
  if op == "-k" then return bit.band(mode, 0x200) ~= 0 end -- sticky
  if op == "-g" then return bit.band(mode, 0x400) ~= 0 end -- setgid
  if op == "-u" then return bit.band(mode, 0x800) ~= 0 end -- setuid
  if op == "-s" then return tonumber(ffi.cast("int64_t *", statbuf + 48)[0]) > 0 end -- st_size @ 48
  if op == "-O" then return ffi.cast("uint32_t *", statbuf + 28)[0] == C.geteuid() end -- st_uid @ 28
  if op == "-G" then return ffi.cast("uint32_t *", statbuf + 32)[0] == C.getegid() end -- st_gid @ 32
  return false
end
-- file1 -ot/-nt/-ef file2: compare modification time / same inode (dev+ino).
local statbuf2 = ffi.new("uint8_t[144]")
local function file_bincmp(op, x, y)
  local function st(path, buf) local ok, rc = pcall(C.curse_stat, path, buf); return ok and rc == 0 end
  local ax, ay = st(x, statbuf), st(y, statbuf2)
  if op == "-ef" then
    if not (ax and ay) then return false end
    return ffi.cast("uint64_t *", statbuf)[0] == ffi.cast("uint64_t *", statbuf2)[0]       -- st_dev @ 0
       and ffi.cast("uint64_t *", statbuf + 8)[0] == ffi.cast("uint64_t *", statbuf2 + 8)[0] -- st_ino @ 8
  end
  -- compare (tv_sec @88, tv_nsec @96) lexicographically to avoid double overflow
  local function older(ba, bb) -- ba's mtime < bb's mtime
    local s1, s2 = tonumber(ffi.cast("int64_t *", ba + 88)[0]), tonumber(ffi.cast("int64_t *", bb + 88)[0])
    if s1 ~= s2 then return s1 < s2 end
    return tonumber(ffi.cast("int64_t *", ba + 96)[0]) < tonumber(ffi.cast("int64_t *", bb + 96)[0])
  end
  if op == "-nt" then return ax and (not ay or older(statbuf2, statbuf)) end -- x newer (or y missing)
  return ay and (not ax or older(statbuf, statbuf2))                          -- -ot: x older (or x missing)
end
local UNARY_STR = { ["-z"] = true, ["-n"] = true }
-- `test -v NAME` / `[[ -v NAME ]]`: is the variable (or array element) set?
local array_key -- forward (defined below)
local function var_is_set(sh, nm)
  local base, sub = nm:match("^([%a_][%w_]*)%[(.+)%]$")
  if base then return sh:is_elem_set(base, array_key(sh, base, sub)) end
  if nm:match("^%d+$") then return tonumber(nm) <= sh.nparams end -- positional param
  local dn = sh:deref(nm)
  local b = sh.vars[dn]
  -- a bare array name tests element 0 (`test -v a` == `test -v a[0]`), so an
  -- empty (declared-but-elementless) array reads as unset, like bash.
  if b and b.arr then return sh:is_elem_set(dn, array_key(sh, dn, "0")) end
  return b ~= nil or sh:special_get(nm) ~= ""
end
local function unary(sh, op, x)
  if op == "-z" then return x == "" end
  if op == "-n" then return x ~= "" end
  if op == "-o" then return sh and SETOPT[x] and opt_on(sh, SETOPT[x]) or false end -- shell option on
  if op == "-v" then return sh and var_is_set(sh, x) or false end -- variable/element is set
  return file_test(op, x) -- -e/-f/-d/-r/-w/-x/-s…
end
-- `test` numeric operands are plain DECIMAL integers (a leading 0 is NOT octal,
-- 0x.. / N#.. / arithmetic are all rejected) — an invalid one is a syntax error.
local function test_int(s)
  local d = s:match("^%s*([+-]?%d+)%s*$")
  if not d then error({ __test_syntax = ("%s: integer expression expected"):format(s) }) end
  return tonumber(d, 10)
end
local TEST_BINOPS = { ["="] = 1, ["=="] = 1, ["!="] = 1, ["<"] = 1, [">"] = 1,
  ["-eq"] = 1, ["-ne"] = 1, ["-lt"] = 1, ["-le"] = 1, ["-gt"] = 1, ["-ge"] = 1,
  ["-ot"] = 1, ["-nt"] = 1, ["-ef"] = 1 }
-- Unary primaries bash recognizes in `test`/`[`. Used to reject a 2-arg test
-- whose first token is not an operator (`[ = '' ]`, `[ '(' foo ]`, `[ a b ]`):
-- bash calls that "unary operator expected" (status 2), not a false result.
local TEST_UNOPS = {}
for w in ("-a -b -c -d -e -f -g -h -k -p -r -s -t -u -w -x -G -L -N -O -R -S -o -v -z -n"):gmatch("%S+") do TEST_UNOPS[w] = 1 end
local function binary(x, op, y)
  if op == "=" or op == "==" then return x == y end
  if op == "!=" then return x ~= y end
  if op == "<" then return x < y end -- string compare (C locale, like bash)
  if op == ">" then return x > y end
  if op == "-ot" or op == "-nt" or op == "-ef" then return file_bincmp(op, x, y) end
  if not TEST_BINOPS[op] then error({ __test_syntax = ("%s: binary operator expected"):format(op) }) end
  local nx, ny = test_int(x), test_int(y)
  if op == "-eq" then return nx == ny end
  if op == "-ne" then return nx ~= ny end
  if op == "-lt" then return nx < ny end
  if op == "-le" then return nx <= ny end
  if op == "-gt" then return nx > ny end
  if op == "-ge" then return nx >= ny end
  return false
end
-- Evaluate a `test`/`[` argument list (already expanded). Returns a boolean.
-- Recursive descent with `( )` grouping and `-o` (lowest) / `-a` / `!` precedence.
local function eval_test(sh, a, lo, hi)
  local n = hi - lo + 1
  if n <= 0 then return false end
  -- ( expr ): strip only when lo's `(` matches hi's `)`
  if a[lo] == "(" then
    local depth = 0
    for j = lo, hi do
      if a[j] == "(" then depth = depth + 1
      elseif a[j] == ")" then depth = depth - 1; if depth == 0 then
        if j == hi then return eval_test(sh, a, lo + 1, hi - 1) end; break
      end end
    end
  end
  -- -o then -a, paren-aware, only when flanked by operands
  for _, opw in ipairs({ "-o", "-a" }) do
    local depth = 0
    for j = lo, hi do
      if a[j] == "(" then depth = depth + 1
      elseif a[j] == ")" then depth = depth - 1
      elseif a[j] == opw and depth == 0 and j > lo and j < hi then
        local l, r = eval_test(sh, a, lo, j - 1), eval_test(sh, a, j + 1, hi)
        if opw == "-o" then return l or r else return l and r end
      end
    end
  end
  if a[lo] == "!" and n > 1 then return not eval_test(sh, a, lo + 1, hi) end
  if n == 1 then return a[lo] ~= "" end
  if n == 2 then
    -- bash: a 2-arg test needs a unary operator first (`=`, `(`, or a plain word
    -- is "unary operator expected", status 2 — not a string test).
    if not TEST_UNOPS[a[lo]] then error({ __test_syntax = a[lo] .. ": unary operator expected" }) end
    return unary(sh, a[lo], a[lo + 1])
  end
  if n == 3 then return binary(a[lo], a[lo + 1], a[lo + 2]) end
  error({ __test_syntax = "too many arguments" }) -- n>3 with no -a/-o/paren: bash syntax error
end
local function do_test(sh, args)
  local lo, hi = 2, #args
  if args[1] == "[" then
    if args[hi] ~= "]" then sh.status = 2; return end
    hi = hi - 1
  end
  -- POSIX 3-argument rule (top level only): a binary operator in the MIDDLE binds
  -- first, so `[ ( = ) ]` is the string compare "(" = ")", not `( )` grouping of
  -- a lone `=`. Grouping only applies to `( )` in longer (recursively-parsed)
  -- expressions.
  local ok, res
  if hi - lo + 1 == 3 and TEST_BINOPS[args[lo + 1]] then
    ok, res = pcall(binary, args[lo], args[lo + 1], args[lo + 2])
  else
    ok, res = pcall(eval_test, sh, args, lo, hi)
  end
  -- a malformed expression (bad operator, non-integer for -eq, too many args) is a
  -- SYNTAX error (status 2); a well-formed expression that's false is status 1.
  if not ok then sh.status = 2; return end
  sh.status = res and 0 or 1
end

local tilde_prefix -- forward (word-initial ~ expansion; defined below, used in paramexp)
local expand_word -- forward (used by eval's $-deferred arith and expand_part_str)
local expand_assign_word -- forward (assignment-RHS expander; ${-default} tilde ctx)
local expand_pattern -- forward (quote-aware glob-pattern expansion for ${v/…} etc.)
local indirect_part -- forward (${!ref} target resolution, re-parsed to a part)
local eval  -- arithmetic evaluator (forward decl)
local arith_resolve -- var-value-as-arith-expression resolver (forward decl)
local arith_key -- array subscript in arith: string key for assoc, number for indexed
local arith_int -- forward: arith-eval a slice offset/length string
local run_trap -- trap-handler runner (forward decl; defined near the bottom)
local fire_err -- ERR-trap + errexit enforcement (forward decl; defined near exec_list)
local sherr -- error-message writer, capture-aware for `2>&1` in $() (defined w/ redirs)
-- Resolve a variable's string value in arithmetic. bash treats it as an arith
-- EXPRESSION: a bare number is its value, but a name (or `3+4`, `bar`) is
-- recursively parsed and evaluated (so bar=foo; foo=5; $((bar)) == 5). A pure
-- integer literal short-circuits (the hot path); a recursion guard bounds cycles.
local function looks_numeric(s)
  return s:match("^%s*[+-]?%d+%s*$") or s:match("^%s*[+-]?0[xX]%x+%s*$")
    or s:match("^%s*[+-]?0[0-7]+%s*$") or s:match("^%s*%d+#[%w@_]+%s*$")
end
arith_resolve = function(sh, s)
  if s == nil or s:match("^%s*$") then return i64(0) end -- unset/blank value -> 0 (bash)
  if looks_numeric(s) then return rt.arith_num(s) end
  sh.arith_depth = (sh.arith_depth or 0) + 1
  if sh.arith_depth > 40 then sh.arith_depth = sh.arith_depth - 1; return i64(0) end -- cycle guard
  local ok, ast = pcall(P.arith, s)
  sh.arith_depth = sh.arith_depth - 1 -- balanced BEFORE any error unwinds past here
  if not ok then -- the value is not a valid arith expression (e.g. "12 34", "1+"): a
    -- non-fatal syntax error — fails the containing command, script continues.
    io.stderr:write("curse: " .. s .. ": syntax error in expression\n")
    error({ __curse_exit = 1, __curse_matherr = true, __curse_experr = true })
  end
  -- A nested bad value (rare: `s=t; t='1 2'`) stays swallowed as 0, matching the
  -- previous behavior; but a genuine arith error during eval (syntax/math, e.g. a
  -- bad subscript) propagates so the command fails like bash instead of yielding 0.
  local ok2, v = pcall(eval, sh, ast)
  if not ok2 then
    if type(v) == "table" and (v.__curse_experr or v.__curse_matherr) then error(v) end
    return i64(0)
  end
  return v ~= nil and v or i64(0)
end

-- Division/modulo by zero is a fatal arithmetic error (bash aborts the current
-- command with status 1 and a diagnostic). Tagged __curse_matherr so a caller
-- that runs code in a protected context (compgen -F) can recover from it.
local function arith_div0()
  io.stderr:write("curse: division by 0\n")
  error({ __curse_exit = 1, __curse_matherr = true })
end

-- Reading an unset variable in arithmetic under `set -u` is a fatal unbound-
-- variable error (bash), just like `$var`. Applies to plain reads and to the
-- read side of `+=`/`++`/`--`, but NOT to a pure `=` assignment (which defines).
local function arith_nounset(sh, name)
  if sh.opt_u and sh.vars[sh:deref(name)] == nil and sh:special_get(name) == "" then
    io.stderr:write("curse: " .. name .. ": unbound variable\n"); error({ __curse_exit = sh.opt_c and 127 or 1 })
  end
end

eval = function(sh, e)
  local k = e.k
  if k == "matherr" then -- a deferred arith parse error (bad lvalue): non-fatal in (( ))
    io.stderr:write("curse: arithmetic syntax error\n")
    error({ __curse_exit = 1, __curse_matherr = true })
  end
  if k == "num" then return rt.arith_num(e.v) end
  if k == "var" then
    if e.idxraw then arith_nounset(sh, e.name); return arith_resolve(sh, sh:array_get(e.name, arith_key(sh, e.name, e.idx, e.idxraw))) end
    arith_nounset(sh, e.name)
    return arith_resolve(sh, sh:get(e.name))
  end
  if k == "param" then return rt.str_to_i64(sh:param(e.n)) end
  if k == "xpand" then -- deferred: expansions inside $(( )) resolved at runtime
    return eval(sh, P.arith(expand_word(sh, P.parse_word(e.raw)), true))
  end
  if k == "comma" then eval(sh, e.l); return eval(sh, e.r) end
  if k == "un" then
    local v = eval(sh, e.e)
    if e.op == "-" then return -v end
    if e.op == "!" then return b2i(not truth(v)) end
    if e.op == "~" then return bit.bnot(v) end
  end
  if k == "tern" then
    if truth(eval(sh, e.c)) then return eval(sh, e.a) else return eval(sh, e.b) end
  end
  if k == "bin" then
    local op = e.op
    if op == "&&" then return b2i(truth(eval(sh, e.l)) and truth(eval(sh, e.r))) end
    if op == "||" then return b2i(truth(eval(sh, e.l)) or truth(eval(sh, e.r))) end
    local l, r = eval(sh, e.l), eval(sh, e.r)
    if op == "+" then return l + r end
    if op == "-" then return l - r end
    if op == "*" then return l * r end
    if op == "/" then if r == i64(0) then arith_div0() end; return l / r end
    if op == "%" then if r == i64(0) then arith_div0() end; return l % r end
    if op == "==" then return b2i(l == r) end
    if op == "!=" then return b2i(l ~= r) end
    if op == "<" then return b2i(l < r) end
    if op == "<=" then return b2i(l <= r) end
    if op == ">" then return b2i(l > r) end
    if op == ">=" then return b2i(l >= r) end
    if op == "&" then return bit.band(l, r) end
    if op == "|" then return bit.bor(l, r) end
    if op == "^" then return bit.bxor(l, r) end
    if op == "<<" then return bit.lshift(l, tonumber(r) % 64) end
    if op == ">>" then return bit.arshift(l, tonumber(r) % 64) end
    if op == "**" then
      local base, n, res = l, tonumber(r), i64(1)
      if n < 0 then -- bash disallows a negative exponent (fatal arith error)
        io.stderr:write("curse: exponent less than 0\n"); error({ __curse_exit = 1, __curse_matherr = true })
      end
      for _ = 1, n do res = res * base end
      return res
    end
  end
  if k == "asgn" then
    local iv = e.idxraw and arith_key(sh, e.name, e.idx, e.idxraw) or nil
    local v = eval(sh, e.e)
    if e.op ~= "=" then
      arith_nounset(sh, e.name) -- `x += …` reads x first
      local cur = iv and rt.arith_num(sh:array_get(e.name, iv)) or sh:aget(e.name)
      local o = e.op:sub(1, #e.op - 1) -- strip the trailing '=' (`<<=` -> `<<`)
      if o == "+" then v = cur + v elseif o == "-" then v = cur - v
      elseif o == "*" then v = cur * v
      elseif o == "/" then if v == i64(0) then arith_div0() end; v = cur / v
      elseif o == "%" then if v == i64(0) then arith_div0() end; v = cur % v
      elseif o == "&" then v = bit.band(cur, v)
      elseif o == "|" then v = bit.bor(cur, v)
      elseif o == "^" then v = bit.bxor(cur, v)
      elseif o == "<<" then v = bit.lshift(cur, tonumber(v) % 64)
      elseif o == ">>" then v = bit.arshift(cur, tonumber(v) % 64) end
    end
    if iv then sh:array_set(e.name, iv, rt.i64_to_str(v)); return v end
    return sh:aset(e.name, v)
  end
  if k == "post" then
    arith_nounset(sh, e.name) -- x++ / x-- read x first
    if e.idxraw then
      local iv = arith_key(sh, e.name, e.idx, e.idxraw)
      local cur = rt.arith_num(sh:array_get(e.name, iv))
      sh:array_set(e.name, iv, rt.i64_to_str(cur + i64(e.d))); return cur
    end
    local cur = sh:aget(e.name); sh:aset(e.name, cur + i64(e.d)); return cur
  end
  if k == "pre" then
    arith_nounset(sh, e.name) -- ++x / --x read x first
    if e.idxraw then
      local iv = arith_key(sh, e.name, e.idx, e.idxraw)
      local v = rt.arith_num(sh:array_get(e.name, iv)) + i64(e.d)
      sh:array_set(e.name, iv, rt.i64_to_str(v)); return v
    end
    local v = sh:aget(e.name) + i64(e.d); return sh:aset(e.name, v)
  end
  error("interp: bad arith node " .. tostring(k))
end
M.eval = eval

-- An array subscript used in arithmetic: an associative array takes the
-- evaluated-then-stringified value as its key ("5"), an indexed array a number.
arith_key = function(sh, name, idxexpr, idxraw)
  -- An associative-array subscript in (( )) is a LITERAL string key (parameter-
  -- expanded and quote-removed), NOT an arith expression: `A[K]` -> key "K",
  -- `A[$k]` -> the value of k, `A['x']` -> "x". Reuse the normal key resolver.
  if sh:is_assoc(name) then return array_key(sh, name, idxraw or "") end
  if idxexpr == nil then -- a non-arith subscript (e.g. quoted) on a NON-assoc array
    io.stderr:write("curse: " .. (idxraw or "") .. ": syntax error in expression\n")
    error({ __curse_exit = 1, __curse_matherr = true, __curse_experr = true })
  end
  return tonumber(rt.i64_to_str(eval(sh, idxexpr)))
end


-- Resolve an array subscript to a key: a string (word-expanded) for an
-- associative array, else an integer (arith-evaluated) for an indexed one.
array_key = function(sh, name, index_raw)
  if sh:is_assoc(name) then return expand_word(sh, P.parse_word(index_raw)) end
  -- indexed: expand $()/$vars in the subscript, then evaluate it as arithmetic
  local ex = expand_word(sh, P.parse_word(index_raw))
  if ex == "" then return 0 end
  local ok, v = pcall(function() return tonumber(rt.i64_to_str(eval(sh, P.arith(ex)))) end)
  return (ok and v) or 0
end

-- Expand ONE part to its string value (a multi-element @/* part is joined here;
-- expand_to_fields treats those specially for word-splitting).
local function expand_part_str(sh, p, assign)
  if p.lit ~= nil then return p.lit
  elseif p.var then
    -- a nameref whose target has a subscript (`typeset -n ref='a[2]'`) reads as
    -- ${a[2]} — deref only yields the base name, so expand the target here.
    local rb = sh.vars[p.var]
    if rb and rb.ref and rb.s and rb.s:find("[", 1, true) then
      return expand_word(sh, P.parse_word("${" .. rb.s .. "}"))
    end
    local b = sh.vars[sh:deref(p.var)]
    local unset = b == nil or (b.s == nil and b.n == nil and b.arr == nil)
    if sh.opt_u and unset and sh:special_get(p.var) == "" then
      io.stderr:write("curse: " .. p.var .. ": unbound variable\n"); error({ __curse_exit = sh.opt_c and 127 or 1 })
    end
    return sh:get(p.var)
  elseif p.param then
    if sh.opt_u and p.param > sh.nparams then
      io.stderr:write("curse: " .. p.param .. ": unbound variable\n"); error({ __curse_exit = sh.opt_c and 127 or 1 })
    end
    return sh:param(p.param)
  elseif p.special then
    local v
    if p.special == "#" then v = tostring(sh.nparams)
    elseif p.special == "*" then -- $* joins on the first IFS char; $@ always on a space
      v = sh:paramsJoin(sh.vars["IFS"] and sh:get("IFS"):sub(1, 1) or " ")
    elseif p.special == "@" then v = sh:paramsJoin(" ")
    elseif p.special == "?" then v = tostring(sh.status)
    elseif p.special == "$" then v = tostring(sh:pid())
    elseif p.special == "!" then v = sh.last_bg_pid or ""
    elseif p.special == "-" then v = sh:dash_flags()
    else v = "" end
    if p.lenof then return tostring(#v) end -- ${##} ${#?} ${#-} ${#$} ${#!}: length
    return v
  elseif p.arith then -- cache the parsed AST on the part (a loop re-expanding the
    if not p.arith_ast then -- same $((…)) shouldn't re-parse it)
      local ok, ast = pcall(P.arith, p.arith)
      if not ok then -- a syntax error in $(( )) fails the command, non-fatally (bash)
        io.stderr:write("curse: " .. p.arith .. ": syntax error in expression\n")
        error({ __curse_exit = 1, __curse_matherr = true, __curse_experr = true })
      end
      p.arith_ast = ast
    end
    return rt.i64_to_str(eval(sh, p.arith_ast))
  elseif p.procsub then
    -- <(cmd)/>(cmd): substitute a filename. <( ) runs the command and captures its
    -- output to a temp file whose path is the word; >( ) makes a temp file the word
    -- and feeds it to the command AFTER the outer command runs (sh.procsub_pending).
    local tmp = os.tmpname()
    if p.dir == "<" then
      local out = sh:capture_src(p.procsub)
      local f = io.open(tmp, "w"); if f then f:write(out); if out ~= "" then f:write("\n") end; f:close() end
    else
      sh.procsub_pending = sh.procsub_pending or {}
      sh.procsub_pending[#sh.procsub_pending + 1] = { file = tmp, cmd = p.procsub }
      local f = io.open(tmp, "w"); if f then f:close() end
    end
    sh.procsub_files = sh.procsub_files or {}; sh.procsub_files[#sh.procsub_files + 1] = tmp
    return tmp
  elseif p.cmdsub then return sh:capture_src(p.cmdsub)
  elseif p.pexp then
    local pe = p.pexp
    if pe.op == "badsubst" then -- ${x|html} and other unrecognized ${…} forms
      sherr(sh, "curse: ${" .. (pe.raw or pe.name or "") .. "}: bad substitution\n")
      error({ __curse_exit = 1, __curse_experr = true }) -- fails the command, non-fatal
    end
    if pe.op == "@" and pe.arg == "P" then -- ${x@P}: decode prompt escapes, then expand
      local decoded = sh:prompt_escapes(sh:get_u(pe.name)) -- get_u: honor set -u
      -- The decode output is already final; only re-expand it for $var/$(…)/`…`
      -- (promptvars). Re-parsing as a word otherwise eats decoded backslashes
      -- (e.g. `\x55` -> `\x55`, a lone `\` stays `\`), which bash keeps.
      if not decoded:find("[$`]") then return decoded end
      return expand_word(sh, P.parse_word(decoded))
    end
    if pe.op == "indirect" then -- ${!ref} / ${!ref OP}: resolve the name, then expand it
      local ip = indirect_part(sh, pe)
      if not ip then return "" end
      ip.q = p.q
      return expand_part_str(sh, ip)
    end
    local subkey
    if pe.index and pe.index ~= "@" and pe.index ~= "*" then
      subkey = array_key(sh, pe.name, pe.index)
    end
    -- pattern-context ops (strip #/##/%/%%, subst /,//) treat quoted metachars
    -- literally; everything else (defaults :-/-, etc.) is an ordinary value.
    local patmode = pe.op == "/" or pe.op == "//" or pe.op == "#" or pe.op == "##"
      or pe.op == "%" or pe.op == "%%"
      or pe.op == "^" or pe.op == "^^" or pe.op == "," or pe.op == ",," -- case-fold pattern
    -- The word for -/:-/+/:+/=/:=/?/:? is only expanded WHEN USED (bash: a default
    -- with side effects like $((i++)) runs only if the branch is taken). Pass a thunk.
    -- (TESTOP is a module-level constant.)
    -- When the ${…} is inside double quotes, its default/alternate word follows
    -- double-quoted rules: single quotes are literal and a backslash is kept
    -- except before $ ` " \ (parse_heredoc has exactly these semantics). An inner
    -- double quote is syntactic (part of the outer quote), so `"${x:-"a b"}"`
    -- yields `a b` — strip the unescaped `"` before the heredoc-style parse.
    local function pw(txt)
      if not p.q then return P.parse_word(txt) end
      local out, k, m = {}, 1, #txt
      while k <= m do
        local ch = txt:sub(k, k)
        if ch == "\\" then
          local nx2 = txt:sub(k + 1, k + 1)
          if nx2 == "\n" then k = k + 2 -- backslash-newline: line continuation (removed)
          elseif nx2 == "}" then out[#out + 1] = "}"; k = k + 2 -- \} in a ${…} word is a literal }
          else out[#out + 1] = txt:sub(k, k + 1); k = k + 2 end
        elseif ch == '"' then k = k + 1 -- drop the syntactic inner quote
        else out[#out + 1] = ch; k = k + 1 end
      end
      return P.parse_heredoc(table.concat(out))
    end
    local arg
    if TESTOP[pe.op] then
      -- In an assignment RHS the default word gets the after-`:` tilde rule too
      -- (`x=${undef-~:~}` -> HOME:HOME), so use the assignment-aware expander.
      local wexp = assign and expand_assign_word or expand_word
      arg = pe.arg and function() return wexp(sh, pw(pe.arg)) end or nil
    else
      arg = pe.arg and (patmode and expand_pattern or expand_word)(sh, P.parse_word(pe.arg)) or nil
    end
    local arg2 = pe.arg2 and expand_word(sh, P.parse_word(pe.arg2)) or nil
    if pe.op == "sub" then -- ${v:off:len}: offset/length are arithmetic expressions
      arg = arg and tostring(arith_int(sh, arg) or 0) or nil
      arg2 = arg2 and tostring(arith_int(sh, arg2) or 0) or nil
    elseif not TESTOP[pe.op] then
      -- a word-initial ~ in a pattern / replacement expands (${p//~/z}, ${p#~/x})
      if type(arg) == "string" then arg = tilde_prefix(sh, arg) end
      if arg2 then arg2 = tilde_prefix(sh, arg2) end
    end
    return sh:expand_param(pe, arg, arg2, subkey)
  end
  return ""
end

-- Expand a word to a single string (assignment RHS, case subject, arith index —
-- contexts that do NOT word-split).
-- Tilde expansion on a word-initial unquoted literal: ~ / ~/… -> $HOME, ~+ -> PWD,
-- ~- -> OLDPWD, ~user/… -> that user's home (getpwnam), else the text is literal.
tilde_prefix = function(sh, s)
  if s:sub(1, 1) ~= "~" then return s end
  local r = s:sub(2)
  -- The tilde-prefix login name ends at the first `/` OR `:` (bash: `~:~` -> the
  -- bare `~` expands, `:~` stays; `~root:x` -> /root:x). So `:` terminates the ~/
  -- ~+/~-/~user forms just like `/` does.
  local c1 = r:sub(1, 1)
  if r == "" or c1 == "/" or c1 == ":" then -- ~ / ~/… / ~:… : HOME's value if SET (even ""); else literal
    if sh.vars[sh:deref("HOME")] ~= nil then return sh:get("HOME") .. r end
    return s
  end
  if r == "+" or r:sub(1, 2) == "+/" or r:sub(1, 2) == "+:" then return sh:pwd() .. r:sub(2) end
  if r == "-" or r:sub(1, 2) == "-/" or r:sub(1, 2) == "-:" then local o = sh:get("OLDPWD"); return o ~= "" and (o .. r:sub(2)) or s end
  -- ~user / ~user/… : the named user's home directory (unknown user stays literal)
  local user, tail = r:match("^([^/:]+)(.*)$")
  if user then
    local pw = C.getpwnam(user)
    if pw ~= nil then return ffi.string(pw.pw_dir) .. tail end
  end
  return s
end
M.tilde_prefix = tilde_prefix

-- Canonicalize an absolute path string LOGICALLY: resolve `.`/`..` textually,
-- without following symlinks (bash's default -L `cd` semantics — `..` pops the
-- previous name even when it is a symlink).
local function logical_canon(path)
  local parts = {}
  for seg in path:gmatch("[^/]+") do
    if seg == "." then -- drop
    elseif seg == ".." then if #parts > 0 then parts[#parts] = nil end
    else parts[#parts + 1] = seg end
  end
  return "/" .. table.concat(parts, "/")
end

-- In an assignment RHS (x=…, x+=…, [k]=…) bash tilde-expands not just the word
-- start but every segment following an unquoted ':' (the PATH=~/a:~/b idiom).
local function tilde_assign(sh, s)
  if not s:find("~", 1, true) then return s end -- fast path: nothing to expand
  local segs = {}
  for seg in (s .. ":"):gmatch("([^:]*):") do segs[#segs + 1] = tilde_prefix(sh, seg) end
  return table.concat(segs, ":")
end

-- Word-initial unquoted-literal tilde. bash also tilde-expands a word shaped like
-- `NAME=value` (a valid identifier before `=`) as if it were an assignment RHS —
-- at the value start and after each `:` — even for a plain command argument
-- (`echo x=~`). Otherwise only a leading `~` expands.
local function tilde_word_initial(sh, s)
  local pre, rest = s:match("^([%a_][%w_]*%+?=)(.*)$")
  if pre then return pre .. tilde_assign(sh, rest) end
  return tilde_prefix(sh, s)
end

expand_word = function(sh, w)
  local buf = {}
  for k, p in ipairs(w.parts) do
    local s = expand_part_str(sh, p)
    if k == 1 and p.lit ~= nil and not p.q then s = tilde_word_initial(sh, s) end
    buf[#buf + 1] = s
  end
  return table.concat(buf)
end

-- expand_word for an assignment RHS: unquoted literal parts get the after-':'
-- tilde rule; expanded ($var/$()) and quoted text is never (re-)tilde-expanded.
-- peel_name: the word is a full `name=value` (declaration-builtin arg), so the
-- leading `name=` / `name+=` stays literal and the value after it is the first
-- tilde segment (`readonly x=~/y`). Only the FIRST `=` is a boundary — bash
-- leaves `x=foo=~` as foo=~, which falls out of expanding the value as one word.
expand_assign_word = function(sh, w, peel_name)
  local buf = {}
  for i, p in ipairs(w.parts) do
    local s = expand_part_str(sh, p, true) -- assignment context: ${-default} tilde after ':'
    if p.lit ~= nil and not p.q then
      if peel_name and i == 1 then
        local pre, rest = s:match("^([%a_][%w_]*%+?=)(.*)$")
        s = pre and (pre .. tilde_assign(sh, rest)) or tilde_assign(sh, s)
      else
        s = tilde_assign(sh, s)
      end
    end
    buf[#buf + 1] = s
  end
  return table.concat(buf)
end
M.expand_assign_word = expand_assign_word

-- Expand a word, backslash-escaping the metacharacters in `charclass` for any
-- QUOTED part (so they match literally) while leaving unquoted parts — including
-- unquoted $var expansions — active. Matches bash's rule that quoting, not the
-- value, decides literalness. Shared by glob-pattern and =~-regex expansion.
local function expand_escaped(sh, w, charclass)
  local buf = {}
  for _, p in ipairs(w.parts) do
    local s = expand_part_str(sh, p)
    if p.q then s = s:gsub(charclass, "\\%0") end
    buf[#buf + 1] = s
  end
  return table.concat(buf)
end
-- glob PATTERN context (${v/pat/repl}, case, [[ == ]]): glob metacharacters.
expand_pattern = function(sh, w) return expand_escaped(sh, w, "[%*%?%[%]\\%(%)%|%+%@%!]") end
-- `=~` regex context: ERE metacharacters.
local function expand_regex(sh, w) return expand_escaped(sh, w, "[%.%^%$%*%+%?%(%)%[%]%{%}%|\\]") end

-- A part that expands to multiple elements: $@ / $* / ${a[@]} / ${a[*]} /
-- ${!a[@]} (keys). ${#a[@]} (op="len") is a single count, NOT multi.
-- ${!ref}: the name/expression `ref` indirects to (its value, or a nameref's
-- target), with any trailing operator (iop) appended. Re-parsed into a part so
-- the target can itself be an array (arr[@]), $@, a subscript, etc.
indirect_part = function(sh, pe)
  local tname
  if pe.index == "@" or pe.index == "*" then
    -- ${!name[@]OP}: the reference name is ${name[@]} space-joined (a single
    -- element derefs cleanly; several join to a name with spaces = invalid).
    tname = table.concat(sh:array_values(pe.name), " ")
  elseif pe.index then
    tname = sh:array_get(pe.name, array_key(sh, pe.name, pe.index))
  else
    local b = sh.vars[pe.name]
    -- ${!ref} on a NAMEREF is inverted: it yields the target NAME, not its value.
    if b and b.ref and b.s and not pe.iop then return { lit = b.s } end
    if pe.name:match("^%d+$") then tname = sh:param(tonumber(pe.name)) -- ${!1}: positional
    else tname = (b and b.ref and b.s) or sh:get(pe.name) end
  end
  if tname == nil or tname == "" then return nil end
  -- ${!ref} to a special parameter: $?, $$, $!, $#, $-, $N, $@, $*
  if not pe.iop then
    if tname:match("^%d+$") then return { param = tonumber(tname) } end
    if #tname == 1 and tname:match("[%?%$!#%-@%*]") then return { special = tname } end
  end
  -- The resolved target must be a valid variable reference: an identifier,
  -- optionally with a [subscript]. Anything else (spaces, `/`, …) is invalid.
  local base = tname:match("^[%a_][%w_]*")
  if not base or (#tname > #base and tname:sub(#base + 1, #base + 1) ~= "[") then
    io.stderr:write("curse: " .. tname .. ": invalid variable name\n")
    error({ __curse_exit = 1, __curse_experr = true })
  end
  local ok, part = pcall(P.parse_paramexp, tname .. (pe.iop or ""))
  return ok and part or nil
end
local is_multi
is_multi = function(sh, p)
  if not p.pexp then return p.special == "@" or p.special == "*" end
  if p.pexp.op == "len" then return false end
  if p.pexp.op == "prefix" then return true end -- ${!pfx@} / ${!pfx*}
  if p.pexp.op == "indirect" then local ip = indirect_part(sh, p.pexp); return ip ~= nil and is_multi(sh, ip) end
  -- $@/$* live in pexp.name (e.g. ${@:1}); array [@]/[*] live in pexp.index
  return p.pexp.index == "@" or p.pexp.index == "*" or p.pexp.name == "@" or p.pexp.name == "*"
end
-- arith-evaluate a slice offset/length expression (e.g. "i-4", "(-4)", "2").
arith_int = function(sh, s)
  if s == nil or s == "" then return nil end
  local ok, v = pcall(function() return tonumber(rt.i64_to_str(eval(sh, P.arith(s)))) end)
  return (ok and v) or tonumber(s) or 0
end
-- ${a[@]:off:len}: select elements by (0-based, negatives-from-end) offset/length.
local function array_slice(els, off, len)
  local n = #els
  off = off or 0
  -- a negative offset counts from the end; if it reaches past the start, bash
  -- yields an EMPTY slice (not the whole array — don't clamp to 0).
  if off < 0 then off = n + off; if off < 0 then return {} end end
  local last = n
  if len ~= nil then last = (len < 0) and (n + len) or (off + len) end
  local out = {}
  for i = off, last - 1 do if els[i + 1] ~= nil then out[#out + 1] = els[i + 1] end end
  return out
end
local function multi_elems(sh, p) -- returns element list, star?
  if p.pexp then
    local pe = p.pexp
    local star = (pe.index == "*" or pe.name == "*") -- $* / ${*:…} join when quoted
    -- Expand a default/alternate word (`:-`/`-`/`:+`/`+` arg). If it is itself a
    -- single array/$@ expansion (${d[@]}), preserve its elements as separate
    -- fields instead of flattening to one joined string.
    local function defval(arg)
      if arg == nil then return { "" } end
      local w = P.parse_word(arg)
      if #w.parts == 1 then
        local part = w.parts[1]; part.q = p.q
        if is_multi(sh, part) then return (multi_elems(sh, part)) end
      end
      return { expand_word(sh, w) }
    end
    if pe.op == "badsubst" then -- e.g. ${a[@]:} (empty offset): fails the command, non-fatal
      sherr(sh, "curse: ${" .. (pe.raw or pe.name or "") .. "}: bad substitution\n")
      error({ __curse_exit = 1, __curse_experr = true })
    end
    if pe.op == "indirect" then -- ${!ref} where ref names an array / $@ / subscript
      local ip = indirect_part(sh, pe)
      if ip then ip.q = p.q; return multi_elems(sh, ip) end
      return {}, false
    end
    if pe.op == "indices" then -- ${!a[@]} -> the keys/indices
      if pe.drop then return {}, star end -- ${!a[@]@X}: a transform on the keys -> empty (bash)
      local ix = sh:array_indices(pe.name); local t = {}
      for i = 1, #ix do t[i] = tostring(ix[i]) end
      return t, star
    end
    if pe.op == "prefix" then return sh:var_prefix_names(pe.name), pe.star end
    local els
    if pe.name == "@" or pe.name == "*" then
      -- $@ / $* operators (slice, @P/@Q transforms, …) run over the positional
      -- params; a slice is indexed over [$0, $1, …] so ${@:0} includes $0.
      els = {}
      if pe.op == "sub" then els[1] = sh.argv0 or "" end
      for i = 1, sh.nparams do els[#els + 1] = sh.params[i] end
    else
      els = sh:array_values(pe.name)
    end
    if pe.op == "sub" then -- array slice
      local off = arith_int(sh, pe.arg and expand_word(sh, P.parse_word(pe.arg)) or nil) or 0
      -- a PRESENT length (even empty, `${a[@]:0:}`) is a count; empty means 0.
      local len = pe.arg2 and (arith_int(sh, expand_word(sh, P.parse_word(pe.arg2))) or 0) or nil
      -- Unlike a scalar substring, a NEGATIVE length over @/*/array/assoc is a
      -- fatal expansion error in bash (aborts the script with status 1).
      if len and len < 0 then
        io.stderr:write("curse: " .. len .. ": substring expression < 0\n")
        error({ __curse_exit = 1 })
      end
      if pe.name ~= "@" and pe.name ~= "*" and not sh:is_assoc(pe.name) then
        -- indexed (possibly sparse) array: select by INDEX VALUE (elements whose
        -- index >= off), length is a COUNT. A negative offset counts from the
        -- highest index + 1 (bash), not from the element count.
        local idx = sh:array_indices(pe.name)
        if off < 0 then off = (idx[#idx] or -1) + 1 + off end
        local out = {}
        if off >= 0 then -- an out-of-bounds negative offset (off < 0 here) is empty
          for i = 1, #idx do if idx[i] >= off then out[#out + 1] = els[i] end end
          if len ~= nil then local t = {}; for i = 1, math.min(len, #out) do t[i] = out[i] end; out = t end
        end
        els = out
      else -- $@/$* and assoc: position-based
        els = array_slice(els, off, len)
      end
    elseif pe.op == "-" and #els == 0 then -- unset/empty array: the default
      return defval(pe.arg), star
    -- `:` null-test for @/* differs by form: a QUOTED `*` tests the IFS[0]-joined
    -- string (empty IFS -> concatenation), so `"${a[*]:-w}"` with ("" "") joins to
    -- "" and IS null; `@` (any quoting) and an UNQUOTED `*` test the element list
    -- instead — null iff there are no elements, or exactly one empty element.
    elseif pe.op == ":-" or pe.op == ":+" then
      local ne
      if star and p.q then
        ne = table.concat(els, sh.vars["IFS"] and sh:get("IFS"):sub(1, 1) or " ") ~= ""
      else
        ne = #els > 1 or (els[1] ~= nil and els[1] ~= "")
      end
      if pe.op == ":-" then if not ne then return defval(pe.arg), star end
      else return ne and defval(pe.arg) or {}, star end
    elseif pe.op == "+" then -- alternate iff the array has any element (is set)
      return (#els > 0) and defval(pe.arg) or {}, star
    elseif pe.op == "@" and pe.arg == "a" then -- ${a[@]@a}: the variable's attribute string, per element
      local attr = sh:attr_string(pe.name); local out = {}
      for i = 1, #els do out[i] = attr end
      els = out
    elseif pe.op and pe.op ~= ":-" and pe.op ~= "-" and pe.op ~= ":+" and pe.op ~= "+" then
      local arg = pe.arg and expand_word(sh, P.parse_word(pe.arg)) or ""
      local arg2 = pe.arg2 and expand_word(sh, P.parse_word(pe.arg2)) or nil
      local out = {}
      for i, v in ipairs(els) do out[i] = sh:apply_str_op(pe.op, v, arg, arg2) end
      els = out
    end
    return els, star
  end
  local els = {}; for i = 1, sh.nparams do els[i] = sh.params[i] end
  return els, (p.special == "*")
end

-- Expand a word to a LIST of fields (command args, for-in lists): unquoted
-- expansions split on default-IFS whitespace; quoted text never splits; "$@" /
-- "${a[@]}" yield one field per element.
local function expand_to_fields(sh, w)
  -- Concatenate-then-split model: build the word left to right, splitting the
  -- chars that came from UNQUOTED expansions on $IFS (default: space/tab/newline),
  -- while literal/quoted chars are never delimiters. This is what bash does, and
  -- it handles concatenation ($x-, pre$x) and custom IFS correctly. Fields also
  -- track `unq` for glob eligibility (quoted glob chars stay literal).
  local ifs = sh.vars["IFS"] and sh:get("IFS") or " \t\n"
  local function isws(c) return c == " " or c == "\t" or c == "\n" end
  local function inifs(c) return c ~= "" and ifs:find(c, 1, true) ~= nil end
  -- `q` is a per-character literal-mask parallel to the field's string ("1" = the
  -- char came from QUOTED/escaped text so it's literal in pathname expansion, "0" =
  -- glob-active). Kept OUT OF BAND (not an escape byte) so it can't collide with a
  -- real byte in the data — curse is byte-transparent, so `'[bc]'*.mm` matches the
  -- file [bc]ar.mm while a $'\x01' byte passes through untouched.
  local fields, cur, cur_unq, cur_q = {}, nil, false, nil
  local function brk()
    if cur ~= nil then fields[#fields + 1] = { s = cur, unq = cur_unq, q = cur_q }; cur, cur_unq, cur_q = nil, false, nil end
  end
  local function add(s, unq)
    cur = (cur or "") .. s
    cur_q = (cur_q or "") .. (unq and "0" or "1"):rep(#s)
    if unq then cur_unq = true end
  end
  local function feed_split(v) -- unquoted expansion text: split on $IFS
    local i, n = 1, #v
    while i <= n do
      local c = v:sub(i, i)
      if inifs(c) then
        if isws(c) then
          if cur ~= nil then brk() end
          i = i + 1
          while i <= n and isws(v:sub(i, i)) do i = i + 1 end
          if i <= n and inifs(v:sub(i, i)) and not isws(v:sub(i, i)) then
            i = i + 1; while i <= n and isws(v:sub(i, i)) do i = i + 1 end
          end
        else                       -- non-whitespace IFS delimiter
          if cur == nil then cur = "" end -- a delimiter always ends a field (empty ok)
          cur_unq = true; brk()
          i = i + 1
          while i <= n and isws(v:sub(i, i)) do i = i + 1 end
        end
      else
        add(c, true); i = i + 1
      end
    end
  end
  for pi, p in ipairs(w.parts) do
    if is_multi(sh, p) then
      local els, star = multi_elems(sh, p)
      if p.q then
        if star then -- "$*" / "${a[*]}" join with the first char of IFS
          local sep = sh.vars["IFS"] and sh:get("IFS"):sub(1, 1) or " "
          add(table.concat(els, sep), false)
        else for k = 1, #els do if k > 1 then brk() end; add(els[k], false) end end -- one field per element
      else
        for k = 1, #els do if k > 1 then brk() end; feed_split(els[k]) end
      end
    elseif p.pexp and not p.q and (p.pexp.op == ":-" or p.pexp.op == "-") and not p.pexp.index
        and p.pexp.name ~= "@" and p.pexp.name ~= "*" then
      -- unquoted ${x:-word}/-: when the WORD branch is taken, the word's OWN quoting
      -- governs splitting (bash), so expand it field-wise rather than as a flat string.
      local pe = p.pexp
      local b = sh.vars[sh:deref(pe.name)]
      local hasval = b ~= nil and (b.s ~= nil or b.n ~= nil or b.arr ~= nil) or sh:special_get(pe.name) ~= ""
      local useword = (pe.op == ":-" and sh:get(pe.name) == "") or (pe.op == "-" and not hasval)
      if useword and pe.arg then
        -- expand the default's parts: a QUOTED part is one atomic (sub)field, an
        -- unquoted part word-splits — so 'a b' stays one field but a b splits.
        for k, sp in ipairs(P.parse_word(pe.arg).parts) do
          local s = expand_part_str(sh, sp)
          if k == 1 and sp.lit ~= nil and not sp.q then s = tilde_prefix(sh, s) end -- word-initial ~
          if sp.q then add(s, false) else feed_split(s) end
        end
      else
        feed_split(sh:get(pe.name))
      end
    else
      local s = expand_part_str(sh, p)
      if pi == 1 and p.lit ~= nil and not p.q then s = tilde_word_initial(sh, s) end -- word-initial / NAME= ~
      if p.q or p.lit ~= nil then add(s, not p.q) else feed_split(s) end
    end
  end
  brk()
  -- pathname expansion on fields with unquoted glob metacharacters
  local out = {}
  -- GLOBIGNORE (set & non-null): filter matches by its `:`-separated patterns and
  -- enable dotglob (leading-dot names then match); `.`/`..` are always excluded.
  local gi = sh:get("GLOBIGNORE")
  local giset = sh.vars[sh:deref("GLOBIGNORE")] ~= nil and gi ~= ""
  local dotglob = giset or (sh.shopt.dotglob and true)
  local nullglob = sh.shopt.nullglob and true
  local gipats
  if giset then -- split on ':' but NOT inside [...] (a `[[:alnum:]]` class holds colons)
    gipats = {}
    local depth, cur = 0, {}
    for k = 1, #gi do
      local c = gi:sub(k, k)
      if c == "[" then depth = depth + 1; cur[#cur + 1] = c
      elseif c == "]" then if depth > 0 then depth = depth - 1 end; cur[#cur + 1] = c
      elseif c == ":" and depth == 0 then if #cur > 0 then gipats[#gipats + 1] = table.concat(cur); cur = {} end
      else cur[#cur + 1] = c end
    end
    if #cur > 0 then gipats[#gipats + 1] = table.concat(cur) end
  end
  local noglob = sh.opt_f -- set -f: pathname expansion disabled; globs stay literal
  local GLOBSPECIAL = { ["*"] = 1, ["?"] = 1, ["["] = 1, ["]"] = 1, ["\\"] = 1,
    ["+"] = 1, ["@"] = 1, ["!"] = 1, ["("] = 1, [")"] = 1 }
  -- is there a glob metacharacter at a NON-masked (glob-active) position?
  local function glob_active(f)
    local s, q = f.s, f.q
    for i = 1, #s do
      if not q or q:sub(i, i) == "0" then
        local c = s:sub(i, i)
        if c == "*" or c == "?" or c == "[" then return true end
        if (c == "?" or c == "*" or c == "+" or c == "@" or c == "!")
          and s:sub(i + 1, i + 1) == "(" and (not q or q:sub(i + 1, i + 1) == "0") then return true end
      end
    end
    return false
  end
  -- build the glob pattern: a masked (quoted) glob-special char is backslash-escaped
  -- so glob_conv treats it literally; the stored value f.s is left byte-for-byte intact.
  local function glob_pat(f)
    if not f.q or not f.q:find("1") then return f.s end
    local o = {}
    for i = 1, #f.s do
      local c = f.s:sub(i, i)
      o[#o + 1] = (f.q:sub(i, i) == "1" and GLOBSPECIAL[c]) and ("\\" .. c) or c
    end
    return table.concat(o)
  end
  for _, f in ipairs(fields) do
    if not noglob and f.unq and glob_active(f) then
      -- a set GLOBIGNORE always filters `.`/`..` (overriding globskipdots)
      local m = rt.glob_expand(glob_pat(f), { dotglob = dotglob, skipdots = giset or shopt_on(sh, "globskipdots"),
        globstar = shopt_on(sh, "globstar") })
      if m and gipats then
        local filt = {}
        for _, x in ipairs(m) do
          local ig = false
          for _, p in ipairs(gipats) do if rt.glob_ignore_match(x, p) then ig = true; break end end
          if not ig then filt[#filt + 1] = x end
        end
        m = (#filt > 0) and filt or nil
      end
      if m then for _, x in ipairs(m) do out[#out + 1] = x end
      elseif sh.shopt.failglob then -- shopt -s failglob: no match is an error (non-fatal)
        io.stderr:write("curse: no match: " .. f.s .. "\n")
        error({ __curse_exit = 1, __curse_experr = true })
      elseif nullglob then -- no matches: nullglob drops the field entirely
      else out[#out + 1] = f.s end
    else
      out[#out + 1] = f.s
    end
  end
  return out
end

local exec_list  -- forward

-- ---- redirections ----
-- Apply a command's redirs, saving fds 0/1/2 for restore. open flags: 577 =
-- O_WRONLY|O_CREAT|O_TRUNC, 1089 = |O_APPEND, 0 = O_RDONLY; mode 0644.
-- Feed a string as a command's stdin (heredoc/herestring): write to a temp file,
-- open it, dup2 onto fd 0, unlink (the open fd keeps the inode alive).
-- Move an opened fd `f` onto target `fd`. If open() already handed us the target
-- (it returns the lowest free fd, e.g. 3 for `3<file`), dup2/close would close the
-- very fd we just set up — so only dup2+close when they differ.
local function place_fd(f, fd) if f ~= fd then C.dup2(f, fd); C.close(f) end end
local function feed_stdin(fd, body)
  local tmp = os.tmpname()
  local w = io.open(tmp, "w"); if w then w:write(body); w:close() end
  local f = C.open(tmp, 0, 0)
  if f >= 0 then place_fd(f, fd) end
  os.remove(tmp)
end
-- Apply redirections, backing up each touched fd (any fd, not just 0/1/2) so it
-- can be restored. Returns (save, ok); ok is false when an open() failed (bash
-- then skips the command and reports failure).
-- Lowest free fd >= 10 (bash allocates named-fd redirs here); F_GETFD=1 on a
-- closed fd returns -1 (EBADF).
local function alloc_fd()
  for fd = 10, 250 do if C.fcntl(fd, 1) == -1 then return fd end end
  return -1
end
-- Open a `>`/`&>` target honoring noclobber (set -C): with noclobber, `>` must
-- not overwrite an existing REGULAR file, but may still write non-regular files
-- (/dev/null, fifos, devices). Returns the fd, or -1 on a noclobber clobber error.
local function open_out(sh, path, mode)
  if not sh.opt_C then return C.open(path, 577, mode) end -- O_WRONLY|O_CREAT|O_TRUNC
  local f = C.open(path, 705, mode)                       -- + O_EXCL
  if f >= 0 then return f end
  local ok, rc = pcall(C.curse_stat, path, statbuf)       -- O_EXCL failed: allow non-regular
  if ok and rc == 0 and bit.band(ffi.cast("uint32_t *", statbuf + 24)[0], 0xF000) ~= 0x8000 then
    return C.open(path, 1, mode) -- not S_IFREG -> plain O_WRONLY (no truncate)
  end
  return -1
end
local function apply_redirs(sh, redirs)
  io.flush() -- flush pending stdout BEFORE moving fds, else buffered output from a
             -- prior command would be redirected into (and lost to) the new target
  local save, ok = {}, true
  local fd1file = false -- has fd 1 gone to a real file? (then `2>&1` isn't captured)
  local function backup(fd) save[#save + 1] = { fd = fd, saved = C.dup(fd) } end
  -- redirect targets are word-expanded at runtime (e.g. `> $TMP/f`, `>& $myfd`).
  local function tgt(r) return expand_word(sh, P.parse_word(r.target or "")) end
  -- A FILE redirect target is glob-expanded and word-split like any word; bash
  -- requires it to resolve to EXACTLY ONE word, else "ambiguous redirect".
  local function ftgt(r)
    local raw = r.target or ""
    -- bash brace-expands the target too; more than one word -> ambiguous redirect.
    if P.brace_count(raw) > 1 then
      io.stderr:write("curse: " .. raw .. ": ambiguous redirect\n"); return nil
    end
    -- expansion can also fail non-fatally (e.g. failglob no-match): the redirect
    -- then fails (status 1) rather than aborting the script.
    local eok, fs = pcall(expand_to_fields, sh, P.parse_word(raw))
    if not eok then return nil end
    if #fs ~= 1 then io.stderr:write("curse: " .. raw .. ": ambiguous redirect\n"); return nil end
    return fs[1]
  end
  for _, r in ipairs(redirs) do
    -- `{var}>…`: allocate a fresh fd (>=10), store it in `var`, and redirect there.
    -- `{var}>&-` instead closes the fd already stored in `var` (no allocation).
    if r.fdvar then
      if (r.op == "dup" or r.op == "dupin") and r.target == "-" then
        r = setmetatable({ fd = tonumber(sh:get(r.fdvar)) or -1 }, { __index = r })
      else
        local nf = alloc_fd(); sh:set_str(r.fdvar, tostring(nf))
        r = setmetatable({ fd = nf }, { __index = r }) -- shadow r.fd, inherit op/target
      end
    end
    if ((r.op == "out" or r.op == "clobber" or r.op == "app" or r.op == "rw") and r.fd == 1)
        or r.op == "outboth" or r.op == "appboth" then fd1file = true end
    if r.op == "out" then
      -- noclobber (set -C): `>` fails on an existing regular file (open_out)
      local t = ftgt(r); if not t then ok = false else
      backup(r.fd); local f = open_out(sh, t, 438)
      if f >= 0 then place_fd(f, r.fd) else ok = false end end
    elseif r.op == "clobber" then -- `>|` truncates regardless of noclobber
      local t = ftgt(r); if not t then ok = false else
      backup(r.fd); local f = C.open(t, 577, 438)
      if f >= 0 then place_fd(f, r.fd) else ok = false end end
    elseif r.op == "app" then
      local t = ftgt(r); if not t then ok = false else
      backup(r.fd); local f = C.open(t, 1089, 438)
      if f >= 0 then place_fd(f, r.fd) else ok = false end end
    elseif r.op == "in" then
      local t = ftgt(r); if not t then ok = false else
      backup(r.fd); local f = C.open(t, 0, 0)
      if f >= 0 then place_fd(f, r.fd) else ok = false end end
    elseif r.op == "rw" then -- `N<>file`: open read+write (O_RDWR|O_CREAT, no truncate)
      local t = ftgt(r); if not t then ok = false else
      backup(r.fd); local f = C.open(t, 66, 438)
      if f >= 0 then place_fd(f, r.fd) else ok = false end end
    elseif r.op == "outboth" then -- `&>` truncation honors noclobber too
      local t = ftgt(r); if not t then ok = false else
      backup(1); backup(2); local f = open_out(sh, t, 438)
      if f >= 0 then C.dup2(f, 1); C.dup2(f, 2); C.close(f) else ok = false end end
    elseif r.op == "appboth" then -- `&>>`: append stdout+stderr (append ignores noclobber)
      local t = ftgt(r); if not t then ok = false else
      backup(1); backup(2); local f = C.open(t, 1089, 438)
      if f >= 0 then C.dup2(f, 1); C.dup2(f, 2); C.close(f) else ok = false end end
    elseif r.op == "heredoc" then
      local body = r.expand and expand_word(sh, P.parse_heredoc(r.body or "", true)) or (r.body or "")
      backup(r.fd or 0); feed_stdin(r.fd or 0, body)
    elseif r.op == "herestring" then
      local body = expand_word(sh, P.parse_word(r.word or "")) .. "\n"
      backup(r.fd or 0); feed_stdin(r.fd or 0, body)
    elseif r.op == "dup" or r.op == "dupin" then
      local tv = tgt(r)
      if tv == "-" then backup(r.fd); C.close(r.fd) -- `N>&-` closes fd N
      else
        local movesrc = tv:match("^(%d+)%-$")       -- `N>&M-`: dup then close the source (move)
        local m = tonumber(movesrc or tv)
        if m then
          -- Validate the source fd is open BEFORE backing up the destination: a
          -- dup-based backup would otherwise reuse a just-closed source fd number,
          -- making a stale `>&N` spuriously succeed (fd N reopened as the backup).
          if C.fcntl(m, 1) == -1 then -- F_GETFD on a closed fd returns -1 (EBADF)
            io.stderr:write("curse: " .. tv .. ": Bad file descriptor\n"); ok = false
          else
            backup(r.fd); C.dup2(m, r.fd)
            if movesrc then C.close(m) end
            -- `2>&1` while capturing (fd 1 not a file): route curse's OWN error
            -- output into the capture buffer too (bash captures it; our in-process
            -- capture leaves fd 1 real, so the error would otherwise leak). See sherr.
            if r.fd == 2 and m == 1 and sh.capturing and not fd1file then
              save.e2o = (save.e2o or 0) + 1; save._sh = sh; sh.err2out = (sh.err2out or 0) + 1
            end
          end
        elseif r.op == "dup" and tv ~= "" then -- `>&word` (non-number): open the file for
          backup(r.fd); backup(2); local f = C.open(tv, sh.opt_C and 705 or 577, 438) -- both stdout AND stderr
          if f >= 0 then C.dup2(f, r.fd); C.dup2(f, 2); C.close(f) else ok = false end
        end
      end
    end
  end
  return save, ok
end
-- Does this redirection list target stdout (fd 1)? Used to decide whether to
-- route captured/builtin output to the real fd 1 vs a $(...) capture buffer.
local function redirs_touch_stdout(rd)
  for _, r in ipairs(rd) do
    if not r.fdvar and (r.op == "outboth" or r.op == "appboth"
        or (r.fd == 1 and (r.op == "out" or r.op == "app" or r.op == "clobber"
          or r.op == "dup" or r.op == "rw"))) then
      return true
    end
  end
  return false
end
local function restore_redirs(save)
  if save.e2o and save._sh then save._sh.err2out = (save._sh.err2out or 0) - save.e2o end -- undo 2>&1 capture routing
  for k = #save, 1, -1 do
    local s = save[k]
    if s.saved >= 0 then C.dup2(s.saved, s.fd); C.close(s.saved) else C.close(s.fd) end
  end
end
-- Write a curse error message. Inside a `$(...)` capture where `2>&1` is active,
-- route it into the capture buffer (sh.out) so it's captured like bash does;
-- otherwise to real stderr.
sherr = function(sh, msg)
  if sh.capturing and (sh.err2out or 0) > 0 then sh.out(msg) else io.stderr:write(msg) end
end

-- name classification for `type` / `command -v`
local BUILTINS = {
  echo = 1, [":"] = 1, ["true"] = 1, ["false"] = 1, ["["] = 1, test = 1, ["return"] = 1,
  exit = 1, cd = 1, unset = 1, export = 1, declare = 1, typeset = 1, set = 1, shift = 1,
  read = 1, getopts = 1, printf = 1, ["local"] = 1, command = 1, type = 1, pwd = 1,
  eval = 1, source = 1, ["."] = 1, ["break"] = 1, ["continue"] = 1, ["true"] = 1,
  exec = 1, readonly = 1, umask = 1, alias = 1, unalias = 1, shopt = 1, wait = 1, trap = 1,
  mapfile = 1, readarray = 1, compgen = 1, complete = 1, compopt = 1,
  pushd = 1, popd = 1, dirs = 1, builtin = 1, kill = 1, ulimit = 1, jobs = 1,
  history = 1, fc = 1, hash = 1, ["let"] = 1, times = 1,
}
M.BUILTINS = BUILTINS -- exposed so the compiled backend delegates the same set
local KEYWORDS = {
  ["if"] = 1, ["then"] = 1, ["else"] = 1, ["elif"] = 1, ["fi"] = 1, ["for"] = 1,
  ["while"] = 1, ["until"] = 1, ["do"] = 1, ["done"] = 1, ["case"] = 1, ["esac"] = 1,
  ["function"] = 1, ["in"] = 1, ["select"] = 1, ["{"] = 1, ["}"] = 1, ["!"] = 1,
  ["time"] = 1, ["[["] = 1, ["]]"] = 1, ["coproc"] = 1,
}
-- Find `name` in PATH (existence, F_OK — bash's type/command-v report a
-- non-executable file too; execution then fails 126 via posix_spawn).
-- Every PATH match for `name`, in search order, as `type`/`command -v` report
-- them. Executables are preferred: when any exist they ARE the result; only when
-- none is executable do we fall back to non-executable regular files (bash still
-- reports those — unlike actual command execution, which requires +x).
local function find_all_in_path(name)
  if name == "" then return {} end
  local function isfile(p) return C.access(p, 0) == 0 and not file_test("-d", p) end
  local function isexec(p) return C.access(p, 1) == 0 and not file_test("-d", p) end
  if name:find("/", 1, true) then return isexec(name) and { name } or {} end -- a path operand still needs +x
  local path = os.getenv("PATH") or "/usr/bin:/bin"
  local exe, nonexe = {}, {}
  for dir in path:gmatch("[^:]+") do
    local p = dir .. "/" .. name
    if isexec(p) then exe[#exe + 1] = p
    elseif isfile(p) then nonexe[#nonexe + 1] = p end
  end
  return #exe > 0 and exe or nonexe
end
local function find_in_path(name) return find_all_in_path(name)[1] end
local function name_type(sh, name, nofunc)
  if sh.aliases[name] then return "alias" end
  if KEYWORDS[name] then return "keyword" end
  if not nofunc and sh.functions[name] then return "function" end -- `type -f` skips functions
  if BUILTINS[name] then return "builtin" end
  local p = find_in_path(name)
  if p then return "file", p end
  return nil
end

-- Execute an array literal assignment `name=(...)` / `name+=(...)`. bash evaluates
-- in two phases: expand every RHS against the OLD array state first, then evaluate
-- indices left-to-right against the array as it is being built.
local function do_arrayassign(sh, st)
  local isassoc = sh:is_assoc(st.name)
  local anykeyed = false
  for _, e in ipairs(st.elems) do if e.key ~= nil then anykeyed = true; break end end
  local items = {}
  for _, e in ipairs(st.elems) do
    if e.key ~= nil then -- keyed RHS is a single value (no field splitting)
      items[#items + 1] = { key = e.key, op = e.op, val = expand_assign_word(sh, e.word) }
    else -- bare element: unquoted expansions split into multiple elements
      for _, f in ipairs(expand_to_fields(sh, e.word)) do
        items[#items + 1] = { key = nil, op = "=", val = f }
      end
    end
  end
  if not st.append then -- plain assignment resets the array (keep assoc-ness)
    local b = sh.vars[st.name]
    if not b then sh:array_assign(st.name, {}, false); b = sh.vars[st.name] end
    b.arr = {}; b.s = nil; b.n = nil
    if isassoc then b.order = {} end
  end
  if isassoc then
    if anykeyed then -- keyed elements assigned; bare ones are an error in bash (skip)
      for _, it in ipairs(items) do
        if it.key ~= nil then
          sh:array_set(st.name, array_key(sh, st.name, it.key), it.val, it.op == "+=")
        end
      end
    else -- all-bare assoc: alternating key value pairs
      for k = 1, #items, 2 do
        sh:array_set(st.name, items[k].val, items[k + 1] and items[k + 1].val or "", false)
      end
    end
  else
    local auto = 0
    if st.append then
      local mx, b = -1, sh.vars[st.name]
      if b and b.s ~= nil and not b.arr then b.arr = { [0] = b.s }; b.s = nil; b.n = nil end -- scalar -> [0]
      if b and b.arr then for kk in pairs(b.arr) do if kk > mx then mx = kk end end end
      auto = mx + 1
    end
    for _, it in ipairs(items) do
      if it.key ~= nil then
        local idx = array_key(sh, st.name, it.key)
        sh:array_set(st.name, idx, it.val, it.op == "+=")
        auto = idx + 1
      else
        sh:array_set(st.name, auto, it.val, false)
        auto = auto + 1
      end
    end
  end
  -- An array can't live in the process environment: converting a variable to an
  -- array drops it from the env (so a child sees nothing), though bash keeps the
  -- export ATTRIBUTE on the shell variable itself.
  local b = sh.vars[st.name]
  if b and b.exported then C.unsetenv(st.name) end
end
M.do_arrayassign = do_arrayassign

-- Quote a value the way `declare -p` does: double-quoted with \ " $ ` escaped.
local function decl_quote(s)
  -- a control char or high byte forces $'…' (bash: `declare -- x=$'a\nb'`);
  -- otherwise the usual double-quoted form.
  if s:find("[%z\1-\31\127-\255]") then return rt.shell_quote(s) end
  s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("%$", "\\$"):gsub("`", "\\`")
  return '"' .. s .. '"'
end
-- Format one variable as a `declare -p` line, or nil if it is unset.
local function fmt_decl(sh, name)
  -- SHELLOPTS/BASHOPTS are readonly, exported, derived specials with no var box.
  if (name == "SHELLOPTS" or name == "BASHOPTS") and (sh.shellopts) then
    return "declare -r " .. name .. "=" .. decl_quote(sh:special_get(name))
  end
  local b = sh.vars[name]
  if b == nil then return nil end
  if b.ref then return "declare -n " .. name .. "=" .. decl_quote(b.s or "") end
  if b.assoc then
    local parts = {}
    for _, k in ipairs(sh:array_indices(name)) do
      parts[#parts + 1] = "[" .. tostring(k) .. "]=" .. decl_quote(sh:array_get(name, k))
    end
    if #parts == 0 then return "declare -A " .. name .. "=()" end
    return "declare -A " .. name .. "=(" .. table.concat(parts, " ") .. " )"
  elseif b.arr then
    local parts = {}
    for _, k in ipairs(sh:array_indices(name)) do
      parts[#parts + 1] = "[" .. tostring(k) .. "]=" .. decl_quote(sh:array_get(name, k))
    end
    return "declare -a " .. name .. "=(" .. table.concat(parts, " ") .. ")"
  else
    -- attribute letters in bash's order: -rxilu (readonly/export/integer/lower/upper)
    local a = (b.ro and "r" or "") .. (os.getenv(name) ~= nil and "x" or "")
      .. (b.int and "i" or "") .. (b.lower and "l" or "") .. (b.upper and "u" or "")
    local pre = "declare " .. (a == "" and "--" or "-" .. a) .. " " .. name
    if b.s == nil and b.n == nil then return pre end -- declared but unset: no =value
    return pre .. "=" .. decl_quote(sh:get(name))
  end
end

-- ---- umask helpers ----
local function perms_str(bits)
  return (bit.band(bits, 4) ~= 0 and "r" or "") .. (bit.band(bits, 2) ~= 0 and "w" or "")
    .. (bit.band(bits, 1) ~= 0 and "x" or "")
end
local function umask_symbolic(cur)
  local allowed = bit.band(bit.bnot(cur), 511)
  return "u=" .. perms_str(bit.band(bit.rshift(allowed, 6), 7))
    .. ",g=" .. perms_str(bit.band(bit.rshift(allowed, 3), 7))
    .. ",o=" .. perms_str(bit.band(allowed, 7))
end
-- Parse a umask MODE (octal like 0022, or symbolic like u=rwx,go=rx) against the
-- current mask; returns the new mask, or nil on a syntax error.
local function parse_umask(s, cur)
  if s == "" then return nil end
  if s:match("^[0-7]+$") then
    local v = tonumber(s, 8)
    if v > 511 then return nil end -- > 0777: out of range (bash errors; it doesn't truncate)
    return v
  end
  local allowed = bit.band(bit.bnot(cur), 511) -- symbolic works on allowed perms
  -- iterate clauses INCLUDING empty ones (`u-r,,u-r`) so an empty clause is a
  -- syntax error, not silently skipped (gmatch "[^,]+" would drop it).
  for clause in (s .. ","):gmatch("([^,]*),") do
    local who, op, perms = clause:match("^([ugoa]*)([=+-])([rwx]*)$")
    if not who then return nil end
    local pv = 0
    for ch in perms:gmatch(".") do
      pv = bit.bor(pv, ch == "r" and 4 or ch == "w" and 2 or 1)
    end
    if who == "" then who = "a" end
    local whos = {}
    for c in who:gmatch(".") do
      if c == "a" then whos = { "u", "g", "o" }; break else whos[#whos + 1] = c end
    end
    for _, wc in ipairs(whos) do
      local sh4 = wc == "u" and 6 or wc == "g" and 3 or 0
      local cbits = bit.band(bit.rshift(allowed, sh4), 7)
      if op == "=" then cbits = pv
      elseif op == "+" then cbits = bit.bor(cbits, pv)
      else cbits = bit.band(cbits, bit.band(bit.bnot(pv), 7)) end
      allowed = bit.bor(bit.band(allowed, bit.band(bit.bnot(bit.lshift(7, sh4)), 511)), bit.lshift(cbits, sh4))
    end
  end
  return bit.band(bit.bnot(allowed), 511)
end

-- ---- printf (native, bash-compatible) ----
-- An integer printf argument: `'x`/`"x` is the code of the first byte; "" is 0;
-- otherwise arithmetic (bases honored). Returns (int64, ok) — ok=false marks an
-- invalid number (bash prints 0 and sets status 1). int64 keeps full 64-bit
-- precision for %d/%u/%o/%x (LuaJIT's string.format formats cdata directly).
local function printf_int(s, uns)
  if s == nil or s == "" then return 0, true end
  local c = s:sub(1, 1)
  if c == "'" or c == '"' then return (#s >= 2 and s:byte(2) or 0), true end
  -- strtoll semantics (NOT shell arithmetic): skip leading blanks, read a single
  -- [sign] hex/octal/decimal integer, and any leftover (trailing chars OR blanks,
  -- and no base#N) makes it invalid — bash still prints the parsed value, status 1.
  local rest = s:gsub("^[ \t\n]+", "")
  local tok = rest:match("^[%+%-]?0[xX]%x+")   -- 0x hex
    or rest:match("^[%+%-]?0[0-7]*")           -- 0 / 0NNN octal
    or rest:match("^[%+%-]?%d+")               -- decimal
  if not tok then return 0, false end          -- no digits at all ("xyz") -> 0, invalid
  -- libc strtoll/strtoull clamp out-of-range values to the type limits (and
  -- strtoull wraps a negative modulo 2^64), exactly matching bash's printf. Cast
  -- to the int64_t/uint64_t typedefs so string.format formats them directly.
  local v = uns and u64(C.strtoull(tok, nil, 0)) or i64(C.strtoll(tok, nil, 0))
  return v, (rest:sub(#tok + 1) == "")         -- fully consumed?
end
-- A floating printf argument (for %f/%e/%g): C strtod semantics via tonumber.
local function printf_float(s)
  if s == nil or s == "" then return 0, true end
  local c = s:sub(1, 1)
  if c == "'" or c == '"' then return (#s >= 2 and s:byte(2) or 0), true end
  local v = tonumber(s)
  if v then return v, true end
  return 0, false
end
-- width/precision for %s or a %(…)T result via string.format on a plain string.
-- printf %q: quote so the result re-reads as the same word (bash style: backslash-
-- escape metacharacters/whitespace; $'…' when control chars are present).
local function printf_q(s)
  if s == "" then return "''" end
  if s:match("^[%w_@%%%+%-%./,:=^]+$") then return s end
  if s:find("[%z\1-\31\127-\255]") then -- control OR high byte -> $'…' (octal for bytes)
    local out = { "$'" }
    for k = 1, #s do
      local ch, b = s:sub(k, k), s:byte(k)
      if ch == "\n" then out[#out + 1] = "\\n"
      elseif ch == "\t" then out[#out + 1] = "\\t"
      elseif ch == "\r" then out[#out + 1] = "\\r"
      elseif b < 32 or b >= 127 then out[#out + 1] = string.format("\\%03o", b)
      elseif ch == "'" then out[#out + 1] = "\\'"
      elseif ch == "\\" then out[#out + 1] = "\\\\"
      else out[#out + 1] = ch end
    end
    out[#out + 1] = "'"; return table.concat(out)
  end
  return (s:gsub("[%s\"'\\|&;<>()$`?*%[%]#~=!{}^]", "\\%0"))
end
-- Format one numeric %-conversion from a raw arg string. Returns (string, ok).
local function printf_conv(full, conv, arg)
  if conv == "d" or conv == "i" then
    local v, ok = printf_int(arg); return string.format(full .. "d", v), ok
  elseif conv == "u" then
    local v, ok = printf_int(arg, true); return string.format(full .. "u", v), ok
  elseif conv == "o" or conv == "x" or conv == "X" then
    local v, ok = printf_int(arg, true); return string.format(full .. conv, v), ok
  elseif conv == "f" or conv == "F" or conv == "e" or conv == "E" or conv == "g"
      or conv == "G" or conv == "a" or conv == "A" then
    local v, ok = printf_float(arg); return string.format(full .. (conv == "F" and "f" or conv), v), ok
  end
  return nil, true -- unknown conversion
end
-- The full printf engine. `argv[start..]` are the data args; the format is reused
-- until they're exhausted. Returns (output, status).
local function sh_printf(fmt, argv, start)
  local out, status, ai = {}, 0, start
  local nargs = #argv
  local function nextarg() local v = argv[ai]; if v ~= nil then ai = ai + 1 end; return v or "" end
  repeat
    local pass_start = ai
    local i, n = 1, #fmt
    while i <= n do
      local c = fmt:sub(i, i)
      if c == "\\" then -- format-level backslash escapes (\n \t \\ \ooo \xHH …)
        local d = fmt:sub(i + 1, i + 1)
        if d == "n" then out[#out + 1] = "\n"; i = i + 2
        elseif d == "t" then out[#out + 1] = "\t"; i = i + 2
        elseif d == "r" then out[#out + 1] = "\r"; i = i + 2
        elseif d == "\\" then out[#out + 1] = "\\"; i = i + 2
        elseif d == "a" then out[#out + 1] = "\7"; i = i + 2
        elseif d == "b" then out[#out + 1] = "\8"; i = i + 2
        elseif d == "f" then out[#out + 1] = "\12"; i = i + 2
        elseif d == "v" then out[#out + 1] = "\11"; i = i + 2
        elseif d == "x" then local h = fmt:match("^%x%x?", i + 2)
          if h then out[#out + 1] = string.char(tonumber(h, 16)); i = i + 2 + #h else out[#out + 1] = "\\"; i = i + 1 end
        elseif d == "u" or d == "U" then -- \uHHHH / \UHHHHHHHH code point -> UTF-8
          local h = fmt:match(d == "u" and "^%x%x?%x?%x?" or "^%x%x?%x?%x?%x?%x?%x?%x?", i + 2)
          if h then out[#out + 1] = rt.utf8_char(tonumber(h, 16)); i = i + 2 + #h else out[#out + 1] = "\\"; i = i + 1 end
        elseif d:match("[0-7]") then local o = fmt:match("^[0-7][0-7]?[0-7]?", i + 1)
          out[#out + 1] = string.char(tonumber(o, 8) % 256); i = i + 1 + #o
        else out[#out + 1] = "\\"; i = i + 1 end
      elseif c == "%" then
        local j = i + 1
        if fmt:sub(j, j) == "%" then out[#out + 1] = "%"; i = j + 1
        else
          local spec = "%"
          while fmt:sub(j, j):match("[-+ #0]") do spec = spec .. fmt:sub(j, j); j = j + 1 end
          local width = ""
          if fmt:sub(j, j) == "*" then local w = tonumber((printf_int(nextarg()))); width = tostring(math.floor(w)); j = j + 1
          else while fmt:sub(j, j):match("%d") do width = width .. fmt:sub(j, j); j = j + 1 end end
          local prec = nil
          if fmt:sub(j, j) == "." then
            j = j + 1; prec = ""
            if fmt:sub(j, j) == "*" then local p = tonumber((printf_int(nextarg()))); prec = tostring(math.floor(p)); j = j + 1
            else while fmt:sub(j, j):match("%d") do prec = prec .. fmt:sub(j, j); j = j + 1 end end
          end
          while fmt:sub(j, j):match("[lhLjzt]") do j = j + 1 end -- length mods (ignored)
          if fmt:sub(j, j) == "(" then -- %(FORMAT)T strftime
            local close = fmt:find(")", j + 1, true)
            local tfmt = fmt:sub(j + 1, (close or j + 1) - 1)
            j = (close or j) + 1 -- now at 'T'
            local arg = nextarg()
            local epoch = (arg == "" or arg == "-1") and os.time() or (tonumber(arg) or os.time())
            local sres = os.date(tfmt, epoch) or ""
            if prec then sres = sres:sub(1, tonumber(prec)) end
            out[#out + 1] = string.format("%" .. (spec:sub(2)) .. width .. "s", sres)
            i = j + 1
          else
            local conv = fmt:sub(j, j)
            local full = spec .. width .. (prec and ("." .. prec) or "")
            if conv == "s" then
              out[#out + 1] = string.format((spec:gsub("0", "", 1)) .. width .. (prec and ("." .. prec) or "") .. "s", nextarg())
            elseif conv == "c" then -- first char of the (string) argument
              out[#out + 1] = string.format("%" .. spec:sub(2) .. width .. "s", nextarg():sub(1, 1))
            elseif conv == "b" then
              local bs, bstop = rt.ansi_unescape(nextarg(), "b") -- %b: \NNN & \0NNN; \c stops ALL output
              out[#out + 1] = string.format("%" .. spec:sub(2) .. width .. "s", bs)
              if bstop then return table.concat(out), status end
            elseif conv == "q" then
              local s = printf_q(nextarg())
              out[#out + 1] = width ~= "" and string.format("%" .. spec:sub(2) .. width .. "s", s) or s
            else
              local r, ok = printf_conv(full, conv, nextarg())
              if not ok then status = 1 end
              if r == nil then io.stderr:write("curse: printf: `" .. conv .. "': invalid conversion specification\n"); status = 1 end
              out[#out + 1] = r or ""
            end
            i = j + 1
          end
        end
      else out[#out + 1] = c; i = i + 1 end
    end
  until ai > nargs or ai == pass_start
  return table.concat(out), status
end

-- Dispatch one already-expanded simple command (no redirs — the caller sets those
-- up). Builtins first, then user functions, then external.
-- Run a shell function `cmd` (its body `fn`) with args[2..] as positional params.
-- A function OVERRIDES a builtin of the same name in bash, so this is dispatched
-- before the builtin table (except via `command`, which passes no_func).
local function run_function(sh, cmd, fn, args, hook, tenv_base)
  sh.calldepth = sh.calldepth + 1 -- OSR gate: no handoff inside a call
  sh:pushCall(unpack(args, 2))
  -- Tempenv bindings applied as THIS call's prefix (`x=v func`) belong to this new
  -- frame — tag them so a `local x` in the body absorbs its own call's tempenv
  -- (but not an outer/eval tempenv). See Shell:localVar.
  if tenv_base then for k = tenv_base + 1, #sh.tenv do sh.tenv[k].frame = sh.pd end end
  sh.funcstack = sh.funcstack or {}
  table.insert(sh.funcstack, 1, cmd) -- $FUNCNAME[0] = the function now running
  -- Parallel call-stack for ${BASH_LINENO[@]}/${BASH_SOURCE[@]}: the call SITE's
  -- line, and the file it ran in (single-file scripts: the main script path).
  sh.linestack = sh.linestack or {}; table.insert(sh.linestack, 1, sh.cur_line or 0)
  sh.srcstack = sh.srcstack or {}; table.insert(sh.srcstack, 1, sh.cur_source or sh.argv0 or "")
  local saved_ld = sh.loopdepth; sh.loopdepth = 0 -- break/continue don't cross into a function
  -- Redirects on the definition (`f(){ … } >&2`) apply to the whole body per call.
  local fr = sh.func_redirs and sh.func_redirs[cmd]
  local rsave, rsavedout, rok
  if fr then
    rsave, rok = apply_redirs(sh, fr)
    rsavedout = sh.out; if redirs_touch_stdout(fr) then sh.out = io.write end
  end
  local ok, err = true, nil
  if fr and rok == false then sh.status = 1 -- a failed redirect skips the body (bash)
  elseif type(fn) == "function" then ok, err = pcall(fn, sh) -- a COMPILED function closure
  else ok, err = pcall(exec_list, sh, fn, hook, false) end -- an interp AST body
  if fr then io.flush(); sh.out = rsavedout; restore_redirs(rsave) end
  sh.loopdepth = saved_ld
  table.remove(sh.funcstack, 1)
  table.remove(sh.linestack, 1); table.remove(sh.srcstack, 1)
  sh:popCall()
  sh.calldepth = sh.calldepth - 1
  if not ok then
    if type(err) == "table" and err.__curse_return then sh.status = err.__curse_return
    else error(err) end
  end
  -- RETURN trap: fires after the function body returns (in the caller's scope),
  -- preserving the function's exit status.
  local rt_h = sh.traps and sh.traps.RETURN
  if rt_h and rt_h ~= "" and not sh.in_return_trap then
    sh.in_return_trap = true; local saved = sh.status
    run_trap(sh, rt_h); sh.status = saved; sh.in_return_trap = false
  end
end

-- ---- background job table (for `jobs`, `wait -n`, `wait %jobspec`) ----
local WNOHANG = 1
local function job_add(sh, pid, cmdstr)
  sh.jobs = sh.jobs or {}
  local maxid = 0
  for _, j in ipairs(sh.jobs) do if not j.done and j.id > maxid then maxid = j.id end end
  local job = { id = maxid + 1, pid = pid, cmd = cmdstr or "", done = false }
  sh.jobs[#sh.jobs + 1] = job
  sh.last_bg_pid = tostring(pid)
  return job
end
-- Reap a job (blocking unless nohang); caches its exit status. Returns the status,
-- or nil if it's still running (nohang) / already gone.
local function job_reap(sh, job, nohang)
  if job.done then return job.status end
  local sb = ffi.new("int[1]")
  local r = C.waitpid(job.pid, sb, nohang and WNOHANG or 0)
  if r > 0 then
    job.done = true; job.status = rt.wexit(sb[0])
    local s = bit.band(sb[0], 0x7f); if s ~= 0 and s ~= 0x7f then job.sig = s end -- killed by a signal
    return job.status
  end
  if r < 0 and not nohang then job.done = true; job.status = 127; return 127 end -- already gone
  return nil -- still running (or, in a subshell, not our child to reap — keep it listed)
end
-- Resolve a `%…` jobspec to a job: %N by id, %+/%% current, %- previous, %str prefix.
local function job_resolve(sh, spec)
  local active = {}
  for _, j in ipairs(sh.jobs or {}) do if not j.done then active[#active + 1] = j end end
  if spec == "%%" or spec == "%+" then return active[#active] end
  if spec == "%-" then return active[#active - 1] end
  local n = spec:match("^%%(%d+)$")
  if n then for _, j in ipairs(sh.jobs or {}) do if j.id == tonumber(n) and not j.done then return j end end return nil end
  local str = spec:match("^%%%%?(.+)$") -- %str / %%str: command-prefix match
  if str then for _, j in ipairs(active) do if j.cmd:sub(1, #str) == str then return j end end end
  return nil
end

local function exec_simple(sh, args, hook, no_func)
  local cmd = args[1]
  -- Consume any pending tempenv-call marker (set by exec_stmt for `x=v cmd`): only
  -- the FIRST command dispatched under it may claim those bindings. A direct
  -- function call tags them with its frame; anything else (a builtin like `eval`,
  -- an external) just drops the marker so a function it later invokes can't absorb.
  local tcb = sh.tenv_call_base; sh.tenv_call_base = nil
  -- A user function overrides a builtin of the same name (bash), so it wins here
  -- — unless invoked via `command` (no_func) or the word is a keyword/assignment
  -- builtin whose parse shape a function can't stand in for.
  if cmd ~= nil and not no_func and sh.functions[cmd] then
    return run_function(sh, cmd, sh.functions[cmd], args, hook, tcb)
  end
  if cmd == nil then sh.status = 0
  elseif cmd == "echo" then
    -- echo [-neE] ARGS: -n suppresses the newline, -e interprets backslash escapes.
    local j, nonl, esc = 2, false, false
    while args[j] and args[j]:match("^%-[neE]+$") do
      for ch in args[j]:sub(2):gmatch(".") do
        if ch == "n" then nonl = true elseif ch == "e" then esc = true elseif ch == "E" then esc = false end
      end
      j = j + 1
    end
    local buf = {}
    for k = j, #args do buf[#buf + 1] = args[k] end
    local s = table.concat(buf, " ")
    local stopped
    if esc then s, stopped = rt.ansi_unescape(s) end -- \c stops all output (incl. the newline)
    sh.out(s); if not nonl and not stopped then sh.out("\n") end
    if sh.out == io.write and not io.flush() then sh.write_err = true end -- full disk etc.
    sh.status = 0
  elseif cmd == ":" or cmd == "true" then sh.status = 0
  elseif cmd == "false" then sh.status = 1
  elseif cmd == "break" then -- outside a loop: a no-op (bash), not a fatal unwind
    if args[3] ~= nil then -- too many arguments: a usage error (fatal under -c, else status 1)
      io.stderr:write("curse: break: too many arguments\n"); sh.status = 1
      if sh.opt_c then error({ __curse_exit = 1 }) end
    elseif args[2] and not tonumber(args[2]) then -- non-numeric arg: error 128, still breaks one level
      io.stderr:write("curse: break: " .. args[2] .. ": numeric argument required\n")
      sh.status = 128; if (sh.loopdepth or 0) > 0 then error({ __curse_break = 1 }) end
    else
      sh.status = 0; if (sh.loopdepth or 0) > 0 then error({ __curse_break = tonumber(args[2]) or 1 }) end
    end
  elseif cmd == "continue" then
    if args[3] ~= nil then
      io.stderr:write("curse: continue: too many arguments\n"); sh.status = 1
      if sh.opt_c then error({ __curse_exit = 1 }) end
    elseif args[2] and not tonumber(args[2]) then
      io.stderr:write("curse: continue: " .. args[2] .. ": numeric argument required\n")
      sh.status = 128; if (sh.loopdepth or 0) > 0 then error({ __curse_continue = 1 }) end
    else
      sh.status = 0; if (sh.loopdepth or 0) > 0 then error({ __curse_continue = tonumber(args[2]) or 1 }) end
    end
  elseif cmd == "eval" then
    -- eval [--]: join args, parse, run in the CURRENT shell (return/exit propagate).
    if args[2] and args[2] ~= "-" and args[2] ~= "--" and args[2]:sub(1, 1) == "-" then
      io.stderr:write("curse: eval: " .. args[2] .. ": invalid option\n"); sh.status = 2
    else
      local start = (args[2] == "--") and 3 or 2
      local code = table.concat({ unpack(args, start) }, " ")
      if code:match("%S") then
        local ok, parsed = pcall(P.parse, code)
        -- a syntax error in the eval'd code makes eval RETURN 2 (bash), running
        -- nothing — it must NOT abort the shell (the lazy parser reports it as a
        -- parse_error node, which would otherwise throw when executed).
        local perr = ok and parsed.stmts[1]
        for _, s in ipairs(ok and parsed.stmts or {}) do if s.t == "parse_error" then perr = s; break end end
        if not ok then io.stderr:write("curse: eval: " .. tostring(parsed) .. "\n"); sh.status = 2
        elseif perr and perr.t == "parse_error" then io.stderr:write("curse: eval: syntax error\n"); sh.status = 2
        else exec_list(sh, parsed.stmts, hook, false) end
      else sh.status = 0 end
    end
  elseif cmd == "source" or cmd == "." then
    -- source FILE [args]: run FILE in the current shell; a `return` ends the file.
    -- A name with no slash is looked up in $PATH (files only, dirs skipped), then
    -- falls back to the bare name; `--` ends options.
    local j = 2
    if args[j] == "--" then j = j + 1 end
    local name = args[j]
    local file = name
    if name and not name:find("/", 1, true) then
      for dir in (sh:get("PATH") .. ":"):gmatch("([^:]*):") do
        local cand = (dir == "" and "." or dir) .. "/" .. name
        if file_test("-f", cand) then file = cand; break end
      end
    end
    if not name then io.stderr:write("curse: " .. cmd .. ": filename argument required\n"); sh.status = 2
    elseif file_test("-d", file) then
      io.stderr:write("curse: " .. cmd .. ": " .. name .. ": is a directory\n"); sh.status = 1
    else
      local f = io.open(file, "r")
      if not f then io.stderr:write("curse: " .. cmd .. ": " .. name .. ": No such file or directory\n"); sh.status = 1
      else
        local src = f:read("*a"); f:close()
        local ok, parsed = pcall(P.parse, src)
        if not ok then sh.status = 2
        else
          local savep, savenp = sh.params, sh.nparams
          if #args > j then
            sh.params, sh.nparams = {}, 0
            for k = j + 1, #args do sh.nparams = sh.nparams + 1; sh.params[sh.nparams] = args[k] end
          end
          sh.sourcedepth = (sh.sourcedepth or 0) + 1 -- a `return` is valid while sourcing
          local rok, err = pcall(exec_list, sh, parsed.stmts, hook, false)
          sh.sourcedepth = sh.sourcedepth - 1
          if #args > j then sh.params, sh.nparams = savep, savenp end
          if not rok then
            if type(err) == "table" and err.__curse_return then sh.status = err.__curse_return
            elseif type(err) == "table" and err.__curse_parseerr then sh.status = 2 -- a syntax error in the file: source returns 2, doesn't halt the shell (bash)
            else error(err) end -- a real `exit` propagates
          end
        end
      end
    end
  elseif cmd == "wait" then
    -- wait [-n] [pid…]: reap background jobs. With pids, return the last one's
    -- status; with none, wait for all (status 0); an invalid arg is status 1.
    local stbuf = ffi.new("int[1]")
    local function reap(pid)
      if C.waitpid(pid, stbuf, 0) < 0 then return 127 end
      return rt.wexit(stbuf[0])
    end
    local nflag, specs, bad = false, {}, false
    for k = 2, #args do
      local a = args[k]
      if a == "-n" then nflag = true
      elseif a == "-f" then -- accept (we always block until done anyway)
      elseif a:sub(1, 1) == "-" and #a > 1 then bad = true
      else specs[#specs + 1] = a end
    end
    sh.jobs = sh.jobs or {}
    if bad then sh.status = 2
    elseif nflag and #specs == 0 then
      -- wait for the NEXT job to finish (127 if there are none to wait for)
      local active = false
      for _, j in ipairs(sh.jobs) do if not j.done then active = true; break end end
      if not active then sh.status = 127
      else
        local r = C.waitpid(-1, stbuf, 0); local est = rt.wexit(stbuf[0])
        for _, j in ipairs(sh.jobs) do if j.pid == r then j.done = true; j.status = est end end
        sh.status = est
      end
    elseif #specs > 0 then
      local last = 0
      for _, s in ipairs(specs) do
        if s:sub(1, 1) == "%" then
          local j = job_resolve(sh, s)
          if not j then io.stderr:write("curse: wait: " .. s .. ": no such job\n"); last = 127
          else last = job_reap(sh, j) or 127
            if j.sig and SIGDESC[j.sig] then io.stderr:write(SIGDESC[j.sig] .. "\n") end end
        elseif s:match("^%d+$") then
          local pid, found = tonumber(s), nil
          for _, j in ipairs(sh.jobs) do if j.pid == pid then found = j end end
          if found then last = job_reap(sh, found) or 127
            if found.sig and SIGDESC[found.sig] then io.stderr:write(SIGDESC[found.sig] .. "\n") end
          else last = reap(pid) end
        else -- a bare non-pid/non-jobspec word: status 1 alone, 127 under -n
          io.stderr:write("curse: wait: `" .. s .. "': not a pid or valid job spec\n")
          last = nflag and 127 or 1
        end
      end
      sh.status = last
    else -- wait for all jobs
      for _, j in ipairs(sh.jobs) do job_reap(sh, j) end
      if sh.bg_pids then for _, p in ipairs(sh.bg_pids) do pcall(reap, p) end; sh.bg_pids = {} end
      sh.status = 0
    end
  elseif cmd == "hash" then
    -- hash [-r] [NAME…] : the command-location cache. bare = list; NAME = look up
    -- and cache; -r = forget all. (bash keeps a cached path until -r, ignoring a
    -- later PATH change — see Shell:resolve_cmd.)
    sh.hashcache = sh.hashcache or {}
    local rflag, names, j = false, {}, 2
    while args[j] and args[j]:sub(1, 1) == "-" and #args[j] > 1 do
      if args[j]:find("r") then rflag = true end
      j = j + 1
    end
    for k = j, #args do names[#names + 1] = args[k] end
    if rflag then for k in pairs(sh.hashcache) do sh.hashcache[k] = nil end end
    if #names > 0 then
      sh.status = 0
      for _, nm in ipairs(names) do
        if not nm:find("/", 1, true) and not sh:resolve_cmd(nm) then
          io.stderr:write("curse: hash: " .. nm .. ": not found\n"); sh.status = 1
        end
      end
    elseif not rflag then -- bare `hash`: print the cache (bash format)
      local ks = {}; for k in pairs(sh.hashcache) do ks[#ks + 1] = k end; table.sort(ks)
      if #ks > 0 then
        sh:echo("hits\tcommand")
        for _, k in ipairs(ks) do sh:echo(("%4d\t%s"):format(sh.hashcache[k].hits, sh.hashcache[k].path)) end
      end
      sh.status = 0
    else sh.status = 0 end
  elseif cmd == "history" then
    -- history [-c] [-r [file]] [-w [file]] | history : the shell command history.
    sh.history = sh.history or {}
    local a = args[2]
    if a == "-c" then for i = #sh.history, 1, -1 do sh.history[i] = nil end; sh.status = 0
    elseif a == "-r" or a == "-n" then -- read history from FILE (default $HISTFILE)
      local file = args[3] or sh:get("HISTFILE")
      local f = file ~= "" and file and io.open(file, "r")
      if f then for line in f:lines() do sh.history[#sh.history + 1] = line end; f:close() end
      sh.status = 0
    elseif a == "-w" or a == "-a" then -- write history to FILE
      local file = args[3] or sh:get("HISTFILE")
      local f = file ~= "" and file and io.open(file, "w")
      if f then for _, h in ipairs(sh.history) do f:write(h, "\n") end; f:close() end
      sh.status = 0
    elseif a == nil then -- list the whole history
      for i = 1, #sh.history do sh:echo(("%5d  %s"):format(i, sh.history[i])) end
      sh.status = 0
    elseif a:sub(1, 1) == "-" then -- an unrecognized `-X` flag (e.g. `history -5`)
      io.stderr:write("curse: history: " .. a .. ": invalid option\n"); sh.status = 2
    elseif args[3] ~= nil then -- too many arguments
      io.stderr:write("curse: history: too many arguments\n"); sh.status = 1
    elseif not tonumber((a:gsub("^%+", ""))) then -- a non-numeric count (`history f`)
      io.stderr:write("curse: history: " .. a .. ": numeric argument required\n"); sh.status = 1
    else -- `history N` / `history +N`: list the last N entries
      local nn = math.abs(tonumber((a:gsub("^%+", ""))))
      for i = math.max(1, #sh.history - nn + 1), #sh.history do sh:echo(("%5d  %s"):format(i, sh.history[i])) end
      sh.status = 0
    end
  elseif cmd == "fc" then
    -- fc -l [-n] [-r] [first] [last]: LIST history (edit/re-exec modes not supported).
    -- The `fc` command is itself the last history entry, so it's excluded from ranges.
    sh.history = sh.history or {}
    local lflag, nflag, rflag, nums = false, false, false, {}
    for j = 2, #args do
      local x = args[j]
      if x:sub(1, 1) == "-" and #x > 1 and x:match("^%-[lnr]+$") then
        if x:find("l") then lflag = true end
        if x:find("n") then nflag = true end
        if x:find("r") then rflag = true end
      else nums[#nums + 1] = x end
    end
    local cur = #sh.history -- index of this `fc` command; ranges cover 1..cur-1
    local function resolve(s, dflt)
      if s == nil then return dflt end
      local v = tonumber(s); if not v then return dflt end
      if v < 0 then v = cur + v end -- negative: offset back from the current command
      return v
    end
    local last_default = cur - 1
    local first = resolve(nums[1], math.max(1, last_default - 15))
    local last = resolve(nums[2], last_default)
    if lflag or true then -- only -l (list) is implemented; treat any fc as a listing
      local step = (first <= last) and 1 or -1
      if rflag then first, last, step = last, first, -step end -- -r reverses
      for i = first, last, step do
        if i >= 1 and i <= cur - 1 and sh.history[i] then
          sh:echo((nflag and "" or tostring(i)) .. "\t " .. sh.history[i])
        end
      end
    end
    sh.status = 0
  elseif cmd == "jobs" then
    -- jobs [-p|-l|-r]: list active background jobs (one line each). Refresh done
    -- state non-blockingly first so finished jobs drop off (bash removes them).
    local pflag, lflag = false, false
    for k = 2, #args do local a = args[k]
      if a == "-p" then pflag = true elseif a == "-l" then lflag = true
      elseif a == "-r" or a == "-s" or a == "-n" then -- filters: accept
      elseif a:sub(1, 1) == "-" and #a > 1 then io.stderr:write("curse: jobs: " .. a .. ": invalid option\n"); sh.status = 2; return end
    end
    local sb = ffi.new("int[1]")
    for _, j in ipairs(sh.jobs or {}) do job_reap(sh, j, true) end -- WNOHANG refresh
    local active = {}
    for _, j in ipairs(sh.jobs or {}) do if not j.done then active[#active + 1] = j end end
    for i, j in ipairs(active) do
      local mark = (i == #active) and "+" or (i == #active - 1 and "-" or " ")
      if pflag then sh:echo(tostring(j.pid))
      elseif lflag then sh:echo(("[%d]%s %d Running                 %s &"):format(j.id, mark, j.pid, j.cmd))
      else sh:echo(("[%d]%s  Running                 %s &"):format(j.id, mark, j.cmd)) end
    end
    sh.status = 0
  elseif cmd == "trap" then
    -- trap [-p] [ACTION] SIG…  (subset: registers/prints; only EXIT actually fires)
    local j, pflag = 2, false
    if args[j] == "-l" then -- list signal names (NN) SIGNAME)
      local nums = {}; for n in pairs(NUMSIG) do nums[#nums + 1] = n end; table.sort(nums)
      for _, n in ipairs(nums) do sh:echo(("%2d) SIG%s"):format(n, NUMSIG[n])) end
      sh.status = 0; return
    end
    if args[j] == "-p" then pflag = true; j = j + 1 end
    if args[j] == "--" then j = j + 1 end
    if pflag or j > #args then -- print traps (all, or the named signals) in signal order
      local list = {}
      if j <= #args then -- print only the named signals
        for k = j, #args do local c = canon_sig(args[k]); if c and sh.traps[c] then list[#list + 1] = c end end
      else for canon in pairs(sh.traps) do list[#list + 1] = canon end end
      table.sort(list, function(a, b) return sig_order(a) < sig_order(b) end)
      for _, canon in ipairs(list) do
        sh:echo("trap -- '" .. sh.traps[canon] .. "' " .. canon)
      end
      sh.status = 0
    elseif args[j]:sub(1, 1) == "-" and args[j] ~= "-" then -- a stray -flag (e.g. `trap -1`)
      io.stderr:write("curse: trap: " .. args[j] .. ": invalid option\n"); sh.status = 2
    else
      -- bash: reset-mode (all tokens are signals to reset) only when the first
      -- token is a NUMERIC signal (`trap 0 2`) or the sole arg and a valid signal
      -- (`trap TERM`); a NAME first token is the action, even a name that happens
      -- to be a signal (`trap INT EXIT` runs `INT` at EXIT; `trap err ERR`).
      local action, sigstart
      if canon_sig(args[j]) and (#args == j or args[j]:match("^%d+$")) then
        action, sigstart = "-", j
      else action, sigstart = args[j], j + 1 end
      if sigstart > #args then -- an action with no signal spec is a usage error
        io.stderr:write("curse: trap: usage: trap [-lp] [[arg] signal_spec ...]\n"); sh.status = 1; return
      end
      local ok = true
      for k = sigstart, #args do
        local canon = canon_sig(args[k])
        if not canon then io.stderr:write("curse: trap: " .. args[k] .. ": invalid signal specification\n"); ok = false
        elseif action == "-" then sh.traps[canon] = nil
        else sh.traps[canon] = action end
        -- a REAL signal (not EXIT/DEBUG/RETURN/ERR): block it so we can poll it at
        -- safepoints; resetting unblocks it. sh.sigtraps counts active signal traps.
        local num = canon and SIGNUM[canon:match("^SIG(.+)$") or ""]
        if num and num ~= 9 and num ~= 19 then -- KILL/STOP can't be trapped
          local had = sh.sigtraps and sh.sigtraps[canon]
          if action == "-" and had then block_sig(num, false); sh.sigtraps[canon] = nil
          elseif action ~= "-" and not had then
            sh.sigtraps = sh.sigtraps or {}; sh.sigtraps[canon] = true; block_sig(num, true)
          end
        end
      end
      sh.status = ok and 0 or 1
    end
  elseif cmd == "alias" then
    -- alias [name[=value] …]: define or print aliases.
    local j, ok, printed = 2, true, false
    if args[j] == "--" then j = j + 1 end
    if j > #args then -- print all, sorted
      local ns = {}; for k in pairs(sh.aliases) do ns[#ns + 1] = k end; table.sort(ns)
      for _, k in ipairs(ns) do sh:echo("alias " .. k .. "='" .. sh.aliases[k] .. "'") end
      sh.status = 0
    else
      for k = j, #args do
        local nm, val = args[k]:match("^([^=]+)=(.*)$")
        if nm then sh.aliases[nm] = val
        elseif sh.aliases[args[k]] then sh:echo("alias " .. args[k] .. "='" .. sh.aliases[args[k]] .. "'")
        else io.stderr:write("curse: alias: " .. args[k] .. ": not found\n"); ok = false end
      end
      sh.status = ok and 0 or 1
    end
  elseif cmd == "unalias" then
    local ok = true
    if #args < 2 then io.stderr:write("curse: unalias: usage: unalias [-a] name [name ...]\n"); ok = false
    elseif args[2] == "-a" then sh.aliases = {}
    else
      for k = 2, #args do
        if args[k] ~= "--" then
          if sh.aliases[args[k]] then sh.aliases[args[k]] = nil
          else io.stderr:write("curse: unalias: " .. args[k] .. ": not found\n"); ok = false end
        end
      end
    end
    sh.status = ok and 0 or 1
  elseif cmd == "shopt" then
    -- shopt [-s|-u|-q|-p|-o] [names]: set/unset/query shell options (subset).
    local set_, unset_, quiet, oflag, pflag, badopt = false, false, false, false, false, false
    local names = {}
    for k = 2, #args do
      local a = args[k]
      if a == "-s" then set_ = true elseif a == "-u" then unset_ = true
      elseif a == "-q" then quiet = true elseif a == "-p" then pflag = true
      elseif a == "-o" then oflag = true
      elseif a:match("^-[suqpo]+$") then
        if a:find("s") then set_ = true end; if a:find("u") then unset_ = true end
        if a:find("q") then quiet = true end; if a:find("o") then oflag = true end
        if a:find("p") then pflag = true end
      elseif a:sub(1, 2) == "--" then badopt = true -- long opts are Oil syntax; bash errors
      else names[#names + 1] = a end
    end
    if badopt then
      io.stderr:write("curse: shopt: invalid option\n"); sh.status = 1
    elseif oflag then -- shopt -o: the `set -o` options
      if set_ or unset_ then
        local allok = true
        for _, nm in ipairs(names) do
          if SETOPT[nm] then set_opt(sh, SETOPT[nm], set_)
          else io.stderr:write("curse: shopt: " .. nm .. ": invalid option name\n"); allok = false end
        end
        sh.status = allok and 0 or 1
      elseif #names == 0 then -- list all set-o options
        for _, ent in ipairs(SETOPTS) do
          if pflag then sh.out(("set %so %s\n"):format(opt_on(sh, ent[2]) and "-" or "+", ent[1]))
          else sh.out(("%-15s\t%s\n"):format(ent[1], opt_on(sh, ent[2]) and "on" or "off")) end
        end
        sh.status = 0
      else
        local allok = true
        for _, nm in ipairs(names) do
          if not SETOPT[nm] then allok = false -- unknown: skipped, drops status
          else
          local on = opt_on(sh, SETOPT[nm])
          if not on then allok = false end
          if not quiet then
            if pflag then sh.out(("set %so %s\n"):format(on and "-" or "+", nm))
            else sh.out(("%-15s\t%s\n"):format(nm, on and "on" or "off")) end
          end
          end
        end
        sh.status = allok and 0 or 1
      end
    elseif set_ or unset_ then
      -- -s/-u NAMES: unknown names error (status 1) but valid ones still apply.
      local allok = true
      for _, nm in ipairs(names) do
        if SHOPT_DEFAULT[nm] == nil then
          io.stderr:write("curse: shopt: " .. nm .. ": invalid shell option name\n"); allok = false
        else sh.shopt[nm] = set_ end
      end
      sh.status = allok and 0 or 1
    elseif #names == 0 then -- print all options (query/-p; same 2-col/`shopt -s` form)
      for _, nm in ipairs(SHOPT_ORDER) do
        sh.out(("shopt %s%s\n"):format(shopt_on(sh, nm) and "-s " or "-u ", nm))
      end
      sh.status = 0
    else -- query / print named: invalid names skipped, drop status to 1
      local allok = true
      for _, nm in ipairs(names) do
        if SHOPT_DEFAULT[nm] == nil then allok = false -- unknown: not printed
        else
          local on = shopt_on(sh, nm)
          if not on then allok = false end
          if not quiet then
            if pflag then sh.out(("shopt %s%s\n"):format(on and "-s " or "-u ", nm))
            else sh.out(("%-15s\t%s\n"):format(nm, on and "on" or "off")) end
          end
        end
      end
      sh.status = allok and 0 or 1
    end
  elseif cmd == "let" then
    -- let EXPR…: evaluate each as arithmetic (assignments take effect). Status is
    -- 0 if the LAST expression is non-zero, else 1; a bad/empty expression or no
    -- args is also status 1 (an arith error is non-fatal, like `(( ))`).
    if #args < 2 then io.stderr:write("curse: let: expression expected\n"); sh.status = 1
    else
      local last = 0
      for k = 2, #args do
        local ok, v = pcall(function() return eval(sh, P.arith(args[k])) end)
        last = ok and tonumber(rt.i64_to_str(v)) or 0
      end
      sh.status = (last ~= 0) and 0 or 1
    end
  elseif cmd == "[" or cmd == "test" then do_test(sh, args)
  elseif cmd == "return" then
    -- `return` is only valid inside a function, a sourced script, or a trap;
    -- elsewhere bash reports an error (status 2) but keeps running (no unwind).
    if (sh.calldepth or 0) == 0 and (sh.sourcedepth or 0) == 0 and (sh.in_trap or 0) == 0 then
      io.stderr:write("curse: return: can only `return' from a function or sourced script\n")
      sh.status = 2; return
    end
    if args[2] and not tonumber(args[2]) then io.stderr:write("curse: return: " .. args[2] .. ": numeric argument required\n"); error({ __curse_return = 2 }) end
    error({ __curse_return = args[2] and (tonumber(args[2]) % 256) or sh.status })
  elseif cmd == "exit" then
    if #args > 2 then io.stderr:write("curse: exit: too many arguments\n"); sh.status = 1; return end -- bash: non-fatal
    if args[2] and not tonumber(args[2]) then io.stderr:write("curse: exit: " .. args[2] .. ": numeric argument required\n"); error({ __curse_exit = 2 }) end
    error({ __curse_exit = args[2] and (tonumber(args[2]) % 256) or sh.status })
  elseif cmd == "cd" then
    local prev = sh:pwd()
    -- parse leading -L/-P/-e/-@ flags and a `--`, then the directory operand.
    local operands, j, physical = {}, 2, false
    while args[j] do
      local a = args[j]
      if a == "--" then j = j + 1; break
      elseif a == "-" then operands[#operands + 1] = a; j = j + 1
      elseif a:match("^%-[LPe@]+$") then
        if a:find("P") then physical = true elseif a:find("L") then physical = false end
        j = j + 1
      else break end
    end
    for k = j, #args do operands[#operands + 1] = args[k] end
    if #operands > 1 then io.stderr:write("curse: cd: too many arguments\n"); sh.status = 1; return end
    local dir, print_dir = operands[1], false
    if dir == "-" then
      dir = sh:get("OLDPWD")
      if dir == "" then io.stderr:write("curse: cd: OLDPWD not set\n"); sh.status = 1; return end
      print_dir = true
    elseif dir == nil or dir == "" then
      dir = sh:get("HOME")
      if dir == "" then io.stderr:write("curse: cd: HOME not set\n"); sh.status = 1; return end
    elseif dir:sub(1, 1) ~= "/" and dir ~= "." and dir:sub(1, 2) ~= "./"
        and dir ~= ".." and dir:sub(1, 3) ~= "../" then
      -- CDPATH: a relative operand (not . / ..) is looked up under each entry.
      local cdpath = sh:get("CDPATH")
      if cdpath ~= "" then
        for entry in (cdpath .. ":"):gmatch("([^:]*):") do
          local cand = (entry == "" and "." or entry) .. "/" .. dir
          if C.chdir(cand) == 0 then dir = cand; print_dir = true; break end
        end
      end
    end
    -- logical target: resolve . and .. against $PWD textually (unless -P)
    local logical = logical_canon(dir:sub(1, 1) == "/" and dir or (prev .. "/" .. dir))
    local target = physical and dir or logical
    if C.chdir(target) ~= 0 and not (not physical and C.chdir(dir) == 0) then
      io.stderr:write("curse: cd: " .. dir .. ": No such file or directory\n"); sh.status = 1; return
    end
    sh.status = 0
    local newpwd = physical and sh:phys_cwd() or logical
    sh:export_str("OLDPWD", prev)
    sh:export_str("PWD", newpwd)
    if print_dir then sh:echo(newpwd) end
    if sh.dirstack then sh.dirstack[1] = newpwd end
  elseif cmd == "kill" then
    if args[2] == "-l" or args[2] == "-L" then -- list / translate signal names<->numbers
      if #args == 2 then
        local nums = {}; for n in pairs(NUMSIG) do nums[#nums + 1] = n end; table.sort(nums)
        local line = {}
        for _, n in ipairs(nums) do
          line[#line + 1] = ("%2d) SIG%-8s"):format(n, NUMSIG[n])
          if #line == 5 then sh:echo((table.concat(line):gsub("%s+$", ""))); line = {} end
        end
        if #line > 0 then sh:echo((table.concat(line):gsub("%s+$", ""))) end
        sh.status = 0
      else
        local allok = true
        for k = 3, #args do
          local a = args[k]; local n = tonumber(a)
          if n then
            if n > 128 then n = n - 128 end
            local nm = n == 0 and "EXIT" or NUMSIG[n] -- signal 0 is the pseudo-signal EXIT
            if nm then sh:echo(nm) else allok = false; io.stderr:write("curse: kill: " .. a .. ": invalid signal specification\n") end
          elseif a:upper():gsub("^SIG", "") == "EXIT" then sh:echo("0") -- name EXIT maps back to 0
          else
            local num = SIGNUM[a:gsub("^SIG", "")]
            if num then sh:echo(tostring(num)) else allok = false; io.stderr:write("curse: kill: " .. a .. ": invalid signal specification\n") end
          end
        end
        sh.status = allok and 0 or 1
      end
    else
      local j, sig, bad = 2, 15, nil -- default SIGTERM
      -- Resolve a signal spec to its number: a name (TERM/SIGTERM) via SIGNUM, or a
      -- number that names a real signal (or 0 = the null check). An unknown name or
      -- an out-of-range number (`kill -s 9999`) is invalid → status 1, not silently 15.
      local function resolve_sig(spec)
        local n = tonumber(spec)
        if n then return (n == 0 or NUMSIG[n]) and n or nil end
        return SIGNUM[(spec or ""):upper():gsub("^SIG", "")] -- names are case-insensitive
      end
      if args[j] == "-n" then sig = resolve_sig(args[j + 1]); bad = sig == nil and (args[j + 1] or "") or nil; j = j + 2
      elseif args[j] == "-s" then sig = resolve_sig(args[j + 1]); bad = sig == nil and (args[j + 1] or "") or nil; j = j + 2
      elseif args[j] == "--" then j = j + 1
      elseif args[j] and args[j]:match("^%-.") then
        local s = args[j]:sub(2); sig = resolve_sig(s); bad = sig == nil and s or nil; j = j + 1
      end
      if bad then io.stderr:write("curse: kill: " .. bad .. ": invalid signal specification\n"); sh.status = 1; return end
      local allok = true
      for k = j, #args do
        local target = args[k]
        local pid = tonumber(target)
        if not pid and target:sub(1, 1) == "%" then -- %-jobspec: resolve to its pid
          local jb = job_resolve(sh, target)
          if jb then pid = jb.pid else io.stderr:write("curse: kill: " .. target .. ": no such job\n") end
        end
        if not (pid and C.kill(pid, sig) == 0) then allok = false end
      end
      sh.status = allok and 0 or 1
    end
  elseif cmd == "pushd" or cmd == "popd" or cmd == "dirs" then
    sh.dirstack = sh.dirstack or { sh:pwd() }
    local function cd_to(p) C.chdir(p); sh:export_str("PWD", p) end
    local ds = sh.dirstack
    -- collapse a leading $HOME to ~ only at a path boundary (not a mere prefix:
    -- HOME=/a/b must NOT turn /a/bc into ~c).
    local function tilde(p)
      local h = sh:get("HOME")
      if h ~= "" and p:sub(1, #h) == h and (#p == #h or p:sub(#h + 1, #h + 1) == "/") then
        return "~" .. p:sub(#h + 1)
      end
      return p
    end
    if cmd == "dirs" then
      local vflag, pflag, lflag = false, false, false
      for j = 2, #args do
        local a = args[j]
        if a == "-c" then sh.dirstack = { sh:pwd() }; ds = sh.dirstack
        elseif a == "-v" then vflag = true elseif a == "-p" then pflag = true
        elseif a == "-l" then lflag = true
        elseif a:match("^[+-]%d+$") then -- +N / -N select one entry (accepted)
        else io.stderr:write("curse: dirs: " .. a .. ": invalid option\n"); sh.status = 2; return end
      end
      if not args[2] or not args[2]:find("c") or vflag or pflag or lflag then
        local parts = {}
        for k = 1, #ds do parts[k] = lflag and ds[k] or tilde(ds[k]) end
        if vflag then for k = 1, #parts do sh:echo(("%2d  %s"):format(k - 1, parts[k])) end
        elseif pflag then for k = 1, #parts do sh:echo(parts[k]) end
        else sh:echo(table.concat(parts, " ")) end
      end
      sh.status = 0
    elseif cmd == "pushd" then
      local target, nops = nil, 0
      for j = 2, #args do local a = args[j]
        if a == "--" then target = args[j + 1]; nops = nops + (args[j + 1] and 1 or 0); break
        elseif a:sub(1, 1) == "-" and a ~= "-" and not a:match("^[+-]%d+$") then
          io.stderr:write("curse: pushd: " .. a .. ": invalid option\n"); sh.status = 2; return
        else nops = nops + 1; if not target then target = a end end
      end
      if nops > 1 then io.stderr:write("curse: pushd: too many arguments\n"); sh.status = 1; return end
      if not target then -- swap top two
        if #ds < 2 then io.stderr:write("curse: pushd: no other directory\n"); sh.status = 1; return end
        local prev = sh:pwd()
        ds[1], ds[2] = ds[2], ds[1]; cd_to(ds[1])
        sh:set_str("OLDPWD", prev)
      else
        local prev = sh:pwd()
        if C.chdir(target) ~= 0 then io.stderr:write("curse: pushd: " .. target .. ": No such file or directory\n"); sh.status = 1; return end
        local np = sh:phys_cwd(); sh:set_str("OLDPWD", prev)
        sh:export_str("PWD", np)
        table.insert(ds, 1, np)
      end
      local parts = {}; for k = 1, #ds do parts[k] = tilde(ds[k]) end
      sh:echo(table.concat(parts, " ")); sh.status = 0
    else -- popd
      for j = 2, #args do local a = args[j]
        if a == "--" then -- ok
        elseif a:sub(1, 1) == "-" and a ~= "-" and not a:match("^[+-]%d+$") then
          io.stderr:write("curse: popd: " .. a .. ": invalid option\n"); sh.status = 2; return
        elseif a ~= "-" then io.stderr:write("curse: popd: " .. a .. ": invalid argument\n"); sh.status = 2; return end
      end
      if #ds < 2 then sherr(sh, "curse: popd: directory stack empty\n"); sh.status = 1; return end
      table.remove(ds, 1); cd_to(ds[1])
      local parts = {}; for k = 1, #ds do parts[k] = tilde(ds[k]) end
      sh:echo(table.concat(parts, " ")); sh.status = 0
    end
  elseif cmd == "unset" then
    local fmode, vmode = false, false -- -f: functions only; -v: vars only; neither: var then function
    sh.status = 0
    for j = 2, #args do
      local a = args[j]
      if a == "-f" then fmode = true
      elseif a == "-v" then vmode = true
      elseif a:sub(1, 1) == "-" and #a > 1 then -- other flags: ignore
      elseif fmode then sh.functions[a] = nil
      else
        local nm, sub = a:match("^([%a_][%w_]*)%[(.+)%]$")
        if nm then if not sh:array_unset(nm, array_key(sh, nm, sub)) then
            io.stderr:write("curse: unset: " .. a .. ": bad array subscript\n"); sh.status = 1 end
        else
          local dn = sh:deref(a)
          local b = sh.vars[dn]
          if b and b.ro then -- readonly: cannot unset (bash: status 1, keep it)
            io.stderr:write("curse: unset: " .. a .. ": cannot unset: readonly variable\n"); sh.status = 1
          elseif b ~= nil or vmode then
            -- bash dynamic-scope unset: when the var is NOT local to the CURRENT
            -- frame but shadows a local declared in an ENCLOSING frame (e.g. an
            -- `unset -v` run from a nested `unlocal` helper), removing it REVEALS
            -- that outer binding instead of leaving the name unset.
            local revealed, env_done = false, false
            -- unset of a var LOCAL to the current frame just makes it appear unset
            -- (bash: the outer value stays hidden until the function returns). Only
            -- when the name is NOT local here does unset REVEAL a shadowed binding —
            -- and it peels the MOST RECENT layer, whether that's an enclosing `local`
            -- shadow (savedstack) or a tempenv `x=v cmd` binding (sh.tenv), ordered by
            -- a monotonic seq so interleaved local/tempenv layers unwind correctly.
            if not (sh.savedstack[sh.pd] and sh.savedstack[sh.pd][dn] ~= nil) then
              local best_seq, best_d, best_k = -1, nil, nil
              for d = (sh.pd or 0), 1, -1 do
                local ss = sh.savedstack[d]
                if ss and ss[dn] ~= nil and ss[dn].seq > best_seq then best_seq = ss[dn].seq; best_d = d; best_k = nil end
              end
              for k = #sh.tenv, 1, -1 do
                local e = sh.tenv[k]
                if not e.consumed and e.name == dn and e.seq > best_seq then best_seq = e.seq; best_k = k; best_d = nil end
              end
              if best_d then
                sh.vars[dn] = sh.savedstack[best_d][dn].box or nil -- false = was absent
                sh.savedstack[best_d][dn] = nil; revealed = true
              elseif best_k then
                local e = sh.tenv[best_k]
                sh.vars[dn] = e.box or nil; e.consumed = true; revealed = true
                if e.env then C.setenv(dn, e.env, 1) else C.unsetenv(dn) end
                env_done = true
              end
            end
            if not revealed then sh.vars[dn] = nil end
            if not env_done then C.unsetenv(a) end -- drop from the process env too
          elseif sh.functions[a] then sh.functions[a] = nil -- plain unset falls back to a function
          end
        end
      end
    end
  elseif cmd == "export" or cmd == "declare" or cmd == "typeset" or cmd == "readonly" then
    -- export/declare [-Apx] NAME[=val]…: set the var; export/-x also pushes it to
    -- the process env so posix_spawn children inherit it. -A marks associative,
    -- -p prints declarations.
    local doexport, assoc, printmode, nref, plusn = (cmd == "export"), false, false, false, false
    local plusx, gflag, unexport = false, false, false
    local funcnames, funcbody, iattr, lattr, uattr, rattr, aattr = false, false, false, false, false, false, false
    local rest = {}
    for j = 2, #args do
      local a = args[j]
      if a == "--" then -- end of flags
      elseif a:sub(1, 1) == "-" and #a > 1 then
        if a:find("A") then assoc = true end
        if a:find("p") then printmode = true end
        if a:find("x") then doexport = true end
        -- `-n` un-exports for `export`, but means nameref for declare/typeset/local
        if a:find("n") then if cmd == "export" then unexport = true else nref = true end end
        if a:find("F") then funcnames = true end
        if a:find("f") then funcbody = true end
        if a:find("i") then iattr = true end
        if a:find("l") then lattr = true end
        if a:find("u") then uattr = true end
        if a:find("r") then rattr = true end
        if a:find("a") then aattr = true end
        if a:find("g") then gflag = true end
      elseif a:sub(1, 1) == "+" and #a > 1 then
        if a:find("n") then plusn = true end
        if a:find("x") then plusx = true end -- +x: drop the export attribute
      else rest[#rest + 1] = a end
    end
    -- listing a subset of variables (bare `declare`/`export`/`readonly`, or with
    -- -p and no names): the builtin + attribute flags select which vars to print.
    local function decl_match(nm, b)
      if not b then return false end
      if cmd == "readonly" or rattr then return b.ro end
      if cmd == "export" or doexport then return b.exported end
      if nref then return b.ref end
      if assoc then return b.assoc end
      if aattr then return b.arr and not b.assoc end
      if iattr then return b.int end
      if lattr then return b.lower end
      if uattr then return b.upper end
      return true
    end
    local function list_decls()
      -- plain `declare`/`typeset` (no attribute flags, no -p) prints bare
      -- `name=value` like `set`; with a flag or -p it prints `declare -X name=…`.
      local bare = (cmd == "declare" or cmd == "typeset") and not printmode
        and not (doexport or rattr or iattr or lattr or uattr or aattr or assoc or nref)
      local names = {}; for nm in pairs(sh.vars) do names[#names + 1] = nm end
      table.sort(names)
      for _, nm in ipairs(names) do
        if decl_match(nm, sh.vars[nm]) then
          local d = bare and fmt_set_var(nm, sh.vars[nm]) or fmt_decl(sh, nm)
          if d then sh:echo(d) end
        end
      end
    end
    if funcnames or funcbody then
      -- declare -F [name…] lists `declare -f NAME`; -f prints bodies (not
      -- reconstructed here) — either way the exit status signals existence.
      local names, allok, named = rest, true, #rest > 0
      if #names == 0 then
        names = {}; for k in pairs(sh.functions) do names[#names + 1] = k end; table.sort(names)
      end
      for _, nm in ipairs(names) do
        -- `declare -f NAME` prints the verbatim definition (captured at parse time);
        -- `declare -F NAME` prints just NAME; bare `declare -F` prints `declare -f NAME`.
        if sh.functions[nm] then
          if funcbody then local d = sh.func_src and sh.func_src[nm]; if d then sh:echo(d) end
          elseif funcnames then sh:echo(named and nm or ("declare -f " .. nm)) end
        else allok = false end
      end
      sh.status = allok and 0 or 1
    elseif #rest == 0 then -- no operands: list matching declarations (declare -p, or bare)
      list_decls(); sh.status = 0
    elseif printmode then
      -- Only `declare`/`typeset -p NAME` prints a named declaration; `readonly -p
      -- NAME` and `export -p NAME` (with operands) print nothing (bash quirk — the
      -- no-operand forms still list all, handled above).
      if cmd == "readonly" or cmd == "export" then sh.status = 0
      else
        local allok = true
        for _, nm in ipairs(rest) do
          local d = fmt_decl(sh, nm)
          if d then sh:echo(d)
          else allok = false; io.stderr:write("curse: " .. cmd .. ": " .. nm .. ": not found\n") end
        end
        sh.status = allok and 0 or 1
      end
    else
      local roattr = (cmd == "readonly") or rattr
      -- `declare`/`typeset` in a function make each name LOCAL (like `local`),
      -- unless -g; `export`/`readonly` always act on the global var (bash).
      local localize = (cmd == "declare" or cmd == "typeset") and not gflag and (sh.calldepth or 0) > 0
      local allok = true
      for _, a in ipairs(rest) do
        local nm, op, val = a:match("^([%a_][%w_]*)(%+?=)(.*)$")
        if nm and sh.vars[sh:deref(nm)] and sh.vars[sh:deref(nm)].ro then
          -- reassigning a readonly variable is rejected (bash: `typeset +r r=v` too)
          io.stderr:write("curse: " .. cmd .. ": " .. nm .. ": readonly variable\n"); allok = false
        elseif nm and (aattr or assoc) and val:sub(1, 1) == "(" and val:sub(-1) == ")" then
          -- dynamic array literal: `declare -a "x=(1 2 3)"` (the -a/-A flag is required)
          if localize then sh:localVar(nm) end
          if assoc then sh:declare_assoc(nm) end
          local ast = P.parse(nm .. (op == "+=" and "+=" or "=") .. val)
          local st1 = ast.stmts[1]
          if st1 and st1.t == "arrayassign" then M.do_arrayassign(sh, st1) end
          local bb = sh.vars[sh:deref(nm)]
          if roattr and bb then bb.ro = true end
        elseif nm then
          if localize then sh:localVar(nm) end
          local ap = (op == "+=")
          if nref then
            if not sh:make_nameref(nm, val) then
              io.stderr:write("curse: " .. cmd .. ": `" .. (val or "") .. "': invalid variable name for name reference\n")
              allok = false
            end
          elseif iattr then -- declare -i: arith-evaluate the value, mark integer
            if ap then sh:aset(nm, sh:aget(nm) + eval(sh, P.arith(val)))
            else sh:aset(nm, eval(sh, P.arith(val))) end
            sh.vars[nm].int = true
          elseif lattr or uattr then -- declare -l/-u: lower/upper case attribute
            local nv = lattr and val:lower() or val:upper()
            sh:set_str(nm, ap and (sh:get(nm) .. nv) or nv)
            sh.vars[nm].lower = lattr or nil; sh.vars[nm].upper = uattr or nil
          else
            local eb = sh.vars[sh:deref(nm)]
            if eb and eb.arr and not eb.assoc and not assoc then -- scalar (+)= on an indexed array -> element 0
              sh:array_set(nm, array_key(sh, nm, "0"), val, ap)
            else
              if assoc then sh:declare_assoc(nm) end
              sh:set_str(nm, ap and (sh:get(nm) .. val) or val)
            end
          end
          local bb = sh.vars[sh:deref(nm)]
          if roattr and bb and not nref then bb.ro = true end -- bash ignores -r when -n is given
          -- export attribute: -n / +x clear it (keep the value), else export sets it
          if bb then
            if unexport or plusx then bb.exported = nil; C.unsetenv(nm)
            elseif doexport or sh.opt_a then bb.exported = true; C.setenv(nm, sh:get(nm), 1) end
          end
        elseif a:match("^[%a_][%w_]*$") then
          if localize then sh:localVar(a) end
          if plusn then sh:unref(a)
          elseif nref then
            if not sh:make_nameref(a) then -- existing value is an invalid nameref target
              io.stderr:write("curse: " .. cmd .. ": `" .. (sh.vars[a] and sh.vars[a].s or "") .. "': invalid variable name for name reference\n")
              allok = false
            end
          elseif iattr then sh.vars[a] = sh.vars[a] or {}; sh.vars[a].int = true
          elseif lattr or uattr then
            sh.vars[a] = sh.vars[a] or {}; sh.vars[a].lower = lattr or nil; sh.vars[a].upper = uattr or nil
          elseif assoc then -- bash forbids converting an existing indexed array to associative
            local b = sh.vars[sh:deref(a)]
            if b and b.arr and not b.assoc then
              io.stderr:write("curse: " .. cmd .. ": " .. a .. ": cannot convert indexed to associative array\n"); allok = false
            else sh:declare_assoc(a) end
          elseif aattr then -- `declare -a`: mark an (empty) indexed array; convert a scalar to [0]
            local b = sh.vars[a] or {}
            if b.assoc then -- …and the reverse conversion is forbidden too
              io.stderr:write("curse: " .. cmd .. ": " .. a .. ": cannot convert associative to indexed array\n"); allok = false
            else
              sh.vars[a] = b
              if b.s ~= nil and not b.arr then b.arr = { [0] = b.s }; b.s = nil; b.n = nil else b.arr = b.arr or {} end
            end
          else sh.vars[a] = sh.vars[a] or {} end -- `declare x` creates a declared-but-unset var
          local bb = sh.vars[sh:deref(a)]
          if roattr and bb and not nref then bb.ro = true end -- bash ignores -r when -n is given
          if bb then
            if unexport or plusx then bb.exported = nil; C.unsetenv(a)
            elseif doexport then
              bb.exported = true -- `export U` defers the env until U gets a value (bash)
              if bb.s ~= nil or bb.n ~= nil then C.setenv(a, sh:get(a), 1) end
            end
          end
        elseif a:find("[", 1, true) then -- name[subscript]=value : array-element form
          local anm, sub, aop, aval = a:match("^([%a_][%w_]*)%[(.-)%](%+?=)(.*)$")
          -- bash creates the element for declare/typeset/local, but NOT via a
          -- deferred `readonly a[i]=v` / `export a[i]=v` (those fail, status 1).
          if anm and (cmd == "declare" or cmd == "typeset") then
            if localize then sh:localVar(anm) end
            sh:array_set(anm, array_key(sh, anm, sub), aval, aop == "+=")
            local bb = sh.vars[sh:deref(anm)]; if roattr and bb then bb.ro = true end
          else
            allok = false
          end
        else -- a token that isn't a valid name (`FOO-BAR`, `1x`, …): bash errors
          io.stderr:write("curse: " .. cmd .. ": `" .. a .. "': not a valid identifier\n"); allok = false
        end
      end
      sh.status = allok and 0 or 1
    end
  elseif cmd == "set" then
    -- set [-e|+e|-o NAME|+o NAME|…] [--] [ARGS…]: options then positional params
    if #args == 1 then -- bare `set`: list all shell variables, sorted by name
      local names = {}
      for nm in pairs(sh.vars) do names[#names + 1] = nm end
      table.sort(names)
      for _, nm in ipairs(names) do
        local b = sh.vars[nm]
        if b and not (b.s == nil and b.n == nil and b.arr == nil) then
          sh.out(fmt_set_var(nm, b) .. "\n")
        end
      end
      sh.status = 0
      return
    end
    local j, dd = 2, false
    while j <= #args do
      local a = args[j]
      if a == "--" then dd = true; j = j + 1; break
      elseif a == "-o" or a == "+o" then
        local o, on = args[j + 1], (a == "-o")
        if o == nil then
          -- `set -o`: list options aligned; `set +o`: reproducible `set ±o NAME`.
          for _, ent in ipairs(SETOPTS) do
            if on then sh.out(("%-15s\t%s\n"):format(ent[1], opt_on(sh, ent[2]) and "on" or "off"))
            else sh.out(("set %so %s\n"):format(opt_on(sh, ent[2]) and "-" or "+", ent[1])) end
          end
          j = j + 1
        else
          if SETOPT[o] then set_opt(sh, SETOPT[o], on) end
          j = j + 2
        end
      elseif a == "-" then -- bare `-`: turn off -v/-x and stop option processing (rest = params)
        set_opt(sh, "opt_v", false); set_opt(sh, "opt_x", false); dd = true; j = j + 1; break
      elseif a == "+" then j = j + 1 -- bare `+`: an ignored no-op flag; keep scanning
      elseif a:match("^[-+][a-zA-Z]+$") then -- short flag bundle: -eu, +u, …
        local on = a:sub(1, 1) == "-"
        for f in a:sub(2):gmatch(".") do
          if SETFLAG[f] then set_opt(sh, SETFLAG[f], on) end
        end
        j = j + 1
      else break end
    end
    if dd or j <= #args then
      local np, n = {}, 0
      for k = j, #args do n = n + 1; np[n] = args[k] end
      sh.params = np; sh.nparams = n
    end
    sh.status = 0
  elseif cmd == "type" then
    -- type [-t|-p|-P] NAME…  (-t type word; -p path-if-file; -P force PATH search)
    local tflag, pflag, Pflag, fflag, aflag, j0 = false, false, false, false, false, 2
    while args[j0] and args[j0]:sub(1, 1) == "-" and #args[j0] > 1 do
      local f = args[j0]
      if f:find("t") then tflag = true end
      if f:find("p") then pflag = true end
      if f:find("P") then Pflag = true end
      if f:find("f") then fflag = true end -- -f: suppress shell-function lookup
      if f:find("a") then aflag = true end -- -a: list ALL locations (each PATH file too)
      j0 = j0 + 1
    end
    local allok = true
    for j = j0, #args do
      local nm = args[j]
      if Pflag then -- force PATH search (all files with -a, else the first)
        local ps = find_all_in_path(nm)
        if #ps == 0 then allok = false
        elseif aflag then for _, p in ipairs(ps) do sh:echo(p) end
        else sh:echo(ps[1]) end
      elseif pflag then -- print path(s); status tracks whether the name resolves at all
        if aflag then for _, p in ipairs(find_all_in_path(nm)) do sh:echo(p) end
        else local k, p = name_type(sh, nm, fflag); if k == "file" then sh:echo(p) end end
        if not name_type(sh, nm, fflag) then allok = false end
      elseif tflag then
        local k = name_type(sh, nm, fflag); if k then sh:echo(k) else allok = false end
      elseif aflag then -- every location, in resolution order
        local found = false
        if sh.aliases[nm] then sh:echo(nm .. " is aliased to `" .. sh.aliases[nm] .. "'"); found = true end
        if KEYWORDS[nm] then sh:echo(nm .. " is a shell keyword"); found = true end
        if not fflag and sh.functions[nm] then sh:echo(nm .. " is a function"); found = true end
        if BUILTINS[nm] then sh:echo(nm .. " is a shell builtin"); found = true end
        for _, p in ipairs(find_all_in_path(nm)) do sh:echo(nm .. " is " .. p); found = true end
        if not found then allok = false; io.stderr:write("curse: type: " .. nm .. ": not found\n") end
      else -- sentence form
        local k, p = name_type(sh, nm, fflag)
        if not k then allok = false; io.stderr:write("curse: type: " .. nm .. ": not found\n")
        elseif k == "alias" then sh:echo(nm .. " is aliased to `" .. sh.aliases[nm] .. "'")
        elseif k == "file" then sh:echo(nm .. " is " .. p)
        elseif k == "function" then sh:echo(nm .. " is a function")
          local d = sh.func_src and sh.func_src[nm]; if d then sh:echo(d) end -- verbatim body (bash prints it)
        elseif k == "keyword" then sh:echo(nm .. " is a shell keyword")
        else sh:echo(nm .. " is a shell builtin") end
      end
    end
    sh.status = allok and 0 or 1
  elseif cmd == "command" and (args[2] == "-v" or args[2] == "-V") then
    local verbose = args[2] == "-V"
    local anyfound = false
    for j = 3, #args do
      local k, p = name_type(sh, args[j])
      if not k then
        if verbose then io.stderr:write("curse: command: " .. args[j] .. ": not found\n") end
      else
        anyfound = true
        if verbose then
          if k == "alias" then sh:echo(args[j] .. " is aliased to `" .. sh.aliases[args[j]] .. "'")
          elseif k == "file" then sh:echo(args[j] .. " is " .. p)
          elseif k == "function" then sh:echo(args[j] .. " is a function")
            local d = sh.func_src and sh.func_src[args[j]]; if d then sh:echo(d) end -- verbatim body
          elseif k == "keyword" then sh:echo(args[j] .. " is a shell keyword")
          else sh:echo(args[j] .. " is a shell builtin") end
        else sh:echo(k == "file" and p or args[j]) end
      end
    end
    sh.status = anyfound and 0 or 1 -- bash: 0 if ANY name resolved (multiple names swallow misses)
  elseif cmd == "builtin" then
    -- builtin [--] NAME args: run NAME only if it's an actual shell builtin.
    local j = 2; if args[j] == "--" then j = j + 1 end
    if args[j] == nil then sh.status = 0
    elseif BUILTINS[args[j]] then exec_simple(sh, { unpack(args, j) }, hook, true) -- skip functions
    else io.stderr:write("curse: builtin: " .. args[j] .. ": not a shell builtin\n"); sh.status = 1 end
  elseif cmd == "command" then
    local j, usep = 2, false
    while args[j] == "-p" or args[j] == "-v" or args[j] == "-V" do
      if args[j] == "-p" then usep = true end; j = j + 1
    end
    if args[j] == nil then sh.status = 0
    elseif usep then
      -- -p: resolve against the standard-utility PATH (confstr _CS_PATH), not the
      -- caller's $PATH. Temporarily swap it (env + var) around the command.
      local DEFPATH = std_path()
      local oldenv, oldbox = os.getenv("PATH"), sh.vars["PATH"]
      sh:set_str("PATH", DEFPATH); C.setenv("PATH", DEFPATH, 1)
      local ok, err = pcall(exec_simple, sh, { unpack(args, j) }, hook, true)
      sh.vars["PATH"] = oldbox
      if oldenv then C.setenv("PATH", oldenv, 1) else C.unsetenv("PATH") end
      if not ok then error(err) end
    else exec_simple(sh, { unpack(args, j) }, hook, true) end -- run rest, skipping FUNCTION lookup
  elseif cmd == "compgen" then
    -- compgen [-A action|-f|-d|-c|…] [-W wl] [-F func] [-P pre] [-S suf] [-X filt] [word]
    local actions, wordlist, prefix, bad, cpre, csuf, xfilter, funcname = {}, nil, nil, false, "", "", nil, nil
    local VALID = { ["function"] = 1, alias = 1, builtin = 1, keyword = 1, variable = 1,
      command = 1, file = 1, directory = 1, setopt = 1, shopt = 1, arrayvar = 1,
      export = 1, helptopic = 1, user = 1, hostname = 1, group = 1, job = 1, service = 1,
      signal = 1, disabled = 1, enabled = 1, running = 1, stopped = 1 }
    local SHORT = { f = "file", d = "directory", c = "command", a = "alias", b = "builtin",
      k = "keyword", v = "variable", e = "export", g = "group", u = "user", j = "job", s = "service" }
    local j = 2
    while args[j] do
      local a = args[j]
      if a == "-A" then local act = args[j + 1]; if not VALID[act] then bad = true end; actions[#actions + 1] = act; j = j + 2
      elseif a == "-W" then wordlist = args[j + 1]; j = j + 2
      elseif a == "-P" then cpre = args[j + 1] or ""; j = j + 2
      elseif a == "-S" then csuf = args[j + 1] or ""; j = j + 2
      elseif a == "-X" then xfilter = args[j + 1]; j = j + 2
      elseif a == "-F" then funcname = args[j + 1]; j = j + 2
      elseif a == "-G" or a == "-C" or a == "-o" then j = j + 2 -- take+ignore
      elseif a:match("^-[fdcabkvegujs]+$") then for ch in a:sub(2):gmatch(".") do actions[#actions + 1] = SHORT[ch] end; j = j + 1
      elseif a:sub(1, 1) == "-" and #a > 1 then j = j + 1
      else if prefix == nil then prefix = a end; j = j + 1 end -- the word is the first operand
    end
    if bad then io.stderr:write("curse: compgen: invalid action\n"); sh.status = 2
    else
      local out, seen, werr = {}, {}, false
      local function emit(x) if (not prefix or x:sub(1, #prefix) == prefix) and not seen[x] then seen[x] = true; out[#out + 1] = x end end
      if funcname then
        -- -F NAME: set the completion context vars bash exposes, call the function,
        -- and take its COMPREPLY verbatim. bash does NOT prefix-filter -F results —
        -- the function itself is responsible for that; only -X/-P/-S post-process.
        sh:array_assign("COMP_WORDS", {}, false)
        sh:set_str("COMP_CWORD", "-1"); sh:set_str("COMP_LINE", ""); sh:set_str("COMP_POINT", "0")
        if sh.functions[funcname] then
          local ok, err = pcall(exec_simple, sh, { funcname, "compgen", prefix or "", "" }, hook)
          if ok then
            for _, v in ipairs(sh:array_values("COMPREPLY")) do out[#out + 1] = v end
          elseif not (type(err) == "table" and err.__curse_matherr) then
            error(err) -- exit/return/real errors propagate; only a math fault is caught
          end -- fatal arith error in the function: no candidates, status 1 (below)
        else
          for _, v in ipairs(sh:array_values("COMPREPLY")) do out[#out + 1] = v end
        end
      else
      -- -W words keep their insertion order; each -A action is sorted within itself,
      -- and actions emit in the order given (bash does not globally merge-sort them).
      if wordlist then
        -- -W expands the wordlist (params/$()/arith) THEN splits on IFS; a fatal
        -- expansion (bad ${…}, div-by-zero) makes compgen fail with status 1.
        local ok, expanded = pcall(expand_word, sh, P.parse_word(wordlist))
        if ok then
          for _, w in ipairs(rt.ifs_split(sh.vars["IFS"] and sh:get("IFS") or " \t\n", expanded)) do emit(w) end
        else werr = true end
      end
      for _, act in ipairs(actions) do
        local acc, nosort = {}, false
        local function add(x) acc[#acc + 1] = x end
        if act == "user" then -- users in /etc/passwd order (bash does NOT sort these)
          nosort = true
          C.setpwent()
          while true do local pw = C.getpwent(); if pw == nil then break end; add(ffi.string(pw.pw_name)) end
          C.endpwent()
        elseif act == "function" then for n in pairs(sh.functions) do add(n) end
        elseif act == "alias" then for n in pairs(sh.aliases) do add(n) end
        elseif act == "builtin" then for n in pairs(BUILTINS) do add(n) end
        elseif act == "keyword" then for n in pairs(KEYWORDS) do add(n) end
        elseif act == "variable" or act == "arrayvar" then
          for n in pairs(sh.vars) do add(n) end
          -- always-set dynamic specials bash reports too (PWD etc.)
          for _, n in ipairs({ "PWD", "OLDPWD", "PPID", "UID", "EUID", "RANDOM", "SECONDS", "LINENO", "HOSTNAME" }) do
            if sh.vars[n] == nil and sh:special_get(n) ~= "" then add(n) end
          end
        elseif act == "export" then
          for n in pairs(sh.vars) do if os.getenv(n) ~= nil then add(n) end end
          for _, n in ipairs({ "PWD", "OLDPWD" }) do if sh.vars[n] == nil and os.getenv(n) ~= nil then add(n) end end
        elseif act == "setopt" then for _, e in ipairs(SETOPTS) do add(e[1]) end
        elseif act == "shopt" then for _, n in ipairs(SHOPT_ORDER) do add(n) end
        elseif act == "helptopic" then
          for n in pairs(BUILTINS) do add(n) end; for n in pairs(KEYWORDS) do add(n) end
        elseif act == "file" or act == "directory" then
          local matches = rt.glob_expand((prefix or "") .. "*", { dotglob = false }) or {}
          for _, m in ipairs(matches) do if act == "file" or file_test("-d", m) then add(m) end end
        elseif act == "command" then -- aliases, keywords, builtins, functions + PATH externals
          for n in pairs(BUILTINS) do add(n) end; for n in pairs(sh.functions) do add(n) end
          for n in pairs(sh.aliases) do add(n) end; for n in pairs(KEYWORDS) do add(n) end
          local pfx = prefix or ""
          for dir in (sh:get("PATH") .. ":"):gmatch("([^:]*):") do
            local d = (dir == "" and "." or dir)
            local p = io.popen and io.popen("ls -1 '" .. d .. "' 2>/dev/null")
            if p then for name in p:lines() do
              if name:sub(1, #pfx) == pfx and C.access(d .. "/" .. name, 1) == 0 then add(name) end
            end; p:close() end
          end
        end
        if not nosort then table.sort(acc) end
        for _, n in ipairs(acc) do emit(n) end
      end
      end
      if xfilter and xfilter ~= "" then -- -X PAT removes matches; -X !PAT keeps only matches
        local neg = xfilter:sub(1, 1) == "!"
        local pat = neg and xfilter:sub(2) or xfilter
        local kept = {}
        for _, x in ipairs(out) do
          local m = rt.glob_match(x, pat)
          if (neg and m) or (not neg and not m) then kept[#kept + 1] = x end
        end
        out = kept
      end
      for _, x in ipairs(out) do sh:echo(cpre .. x .. csuf) end
      sh.status = (not werr and #out > 0) and 0 or 1
    end
  elseif cmd == "complete" then
    -- complete [-p] [opts] [name…]: store/print completion specs (registration only)
    if args[2] == nil or args[2] == "-p" then
      local ns = {}; for n in pairs(sh.complete or {}) do ns[#ns + 1] = n end; table.sort(ns)
      for _, n in ipairs(ns) do sh:echo(sh.complete[n] .. " " .. n) end
      sh.status = 0
    else
      -- split trailing NAMEs from the option part; -F/-C etc. with no name is a
      -- usage error UNLESS -D/-E/-I (default/empty/initial-word) is given.
      local opts, cmds, catchall = { "complete" }, {}, false
      local k = 2
      while args[k] do
        local a = args[k]
        if a == "-F" or a == "-C" or a == "-W" or a == "-A" or a == "-o" or a == "-P" or a == "-S" or a == "-X" or a == "-G" then
          opts[#opts + 1] = a; opts[#opts + 1] = sq(args[k + 1] or ""); k = k + 2
        elseif a == "-D" or a == "-E" or a == "-I" then catchall = true; opts[#opts + 1] = a; k = k + 1
        elseif a:sub(1, 1) == "-" then opts[#opts + 1] = a; k = k + 1
        else cmds[#cmds + 1] = a; k = k + 1 end
      end
      if #cmds == 0 and not catchall then io.stderr:write("curse: complete: usage error\n"); sh.status = 2
      else
        sh.complete = sh.complete or {}
        for _, c in ipairs(cmds) do sh.complete[c] = table.concat(opts, " ") end
        sh.status = 0
      end
    end
  elseif cmd == "compopt" then
    -- only valid inside a completion function; we don't run those, so: usage-error
    -- on a bad -o value (2), else "not in completion function" (1).
    for k = 2, #args do
      if args[k] == "-o" or args[k] == "+o" then
        local v = args[k + 1]
        local OK = { default = 1, nospace = 1, filenames = 1, dirnames = 1, bashdefault = 1, plusdirs = 1, nosort = 1 }
        if not OK[v] then io.stderr:write("curse: compopt: invalid option name\n"); sh.status = 2; return end
      end
    end
    sh.status = 1
  elseif cmd == "ulimit" then
    -- ulimit [-HSaflags] [limit]: get/set process resource limits (getrlimit/
    -- setrlimit). Reported/accepted in each resource's block unit; `unlimited`.
    local INF = 0xFFFFFFFFFFFFFFFFULL
    local RES = { -- flag -> { resource, bytes-per-unit, label, unit-name }
      t = { 0, 1, "cpu time", "seconds" }, f = { 1, 1024, "file size", "blocks" },
      d = { 2, 1024, "data seg size", "kbytes" }, s = { 3, 1024, "stack size", "kbytes" },
      c = { 4, 512, "core file size", "blocks" }, m = { 5, 1024, "max memory size", "kbytes" },
      l = { 8, 1024, "max locked memory", "kbytes" }, u = { 6, 1, "max user processes", "" },
      n = { 7, 1, "open files", "" }, v = { 9, 1024, "virtual memory", "kbytes" },
      p = { -1, 512, "pipe size", "512 bytes" },
    }
    local AORDER = { "t", "f", "d", "s", "c", "m", "l", "u", "n", "v" }
    local rl = ffi.new("struct curse_rlimit[1]")
    local hardflag, softflag = false, false
    -- GET one resource: -H reads the hard limit (rlim_max), else the soft (rlim_cur).
    local function report(fl)
      local r = RES[fl]; if not r or r[1] < 0 then return "unlimited" end
      if C.getrlimit(r[1], rl) ~= 0 then return nil end
      local v = hardflag and rl[0].rlim_max or rl[0].rlim_cur
      if v == INF then return "unlimited" end
      return (tostring(v / r[2]):gsub("[UuLl]+$", "")) -- drop LuaJIT's cdata "ULL" suffix
    end
    local flags, value = {}, nil
    local j = 2
    while args[j] do
      local a = args[j]
      if a == "--" then j = j + 1; break
      elseif a == "-a" or a == "--all" then flags = { "t", "f", "d", "s", "c", "m", "l", "u", "n", "v", "@all" }; j = j + 1
      elseif a:sub(1, 1) == "-" and #a > 1 then
        for k = 2, #a do local f = a:sub(k, k)
          if f == "H" then hardflag = true elseif f == "S" then softflag = true
          elseif RES[f] then flags[#flags + 1] = f
          else io.stderr:write("curse: ulimit: -" .. f .. ": invalid option\n"); sh.status = 2; return end
        end
        j = j + 1
      else break end
    end
    value = args[j] -- a trailing value; any further args are ignored (bash)
    if #flags == 0 then flags = { "f" } end -- default resource is -f
    local allmode = flags[#flags] == "@all"
    if allmode then flags[#flags] = nil end
    if allmode then value = nil end -- `ulimit -a` ignores a trailing value (bash prints all, status 0)
    if value ~= nil then -- SET each named resource
      -- with neither -S nor -H, bash sets BOTH; -S sets soft, -H sets hard.
      local setsoft, sethard = softflag or not hardflag, hardflag or not softflag
      sh.status = 0
      for _, fl in ipairs(flags) do
        local r = RES[fl]
        local nv
        if value == "unlimited" then nv = INF
        elseif value:match("^%d+$") then
          local num = tonumber(value)
          if num == nil or num * r[2] > 9223372036854775807 then sh.status = 0; return end -- overflow: bash leaves it
          nv = ffi.cast("uint64_t", num) * ffi.cast("uint64_t", r[2])
        else io.stderr:write("curse: ulimit: " .. value .. ": invalid number\n"); sh.status = 1; return end
        if r[1] < 0 or C.getrlimit(r[1], rl) ~= 0 then sh.status = 1
        else
          if setsoft then rl[0].rlim_cur = nv end
          if sethard then rl[0].rlim_max = nv end
          if C.setrlimit(r[1], rl) ~= 0 then sh.status = 1; io.stderr:write("curse: ulimit: cannot modify limit\n") end
        end
      end
    elseif allmode then -- -a: list all
      for _, fl in ipairs(AORDER) do
        local r = RES[fl]; local v = report(fl) or "unlimited"
        sh:echo(("%-24s(%s, -%s) %s"):format(r[3], r[4], fl, v))
      end
      sh.status = 0
    else -- print one or more resources
      sh.status = 0
      for _, fl in ipairs(flags) do
        local v = report(fl)
        if #flags > 1 then sh:echo(("%-24s(-%s) %s"):format(RES[fl][3], fl, v or "unlimited"))
        else sh:echo(v or "unlimited") end
      end
    end
  elseif cmd == "times" then
    -- Two lines: shell user/sys, then children user/sys, each `%dm%.3fs`.
    local function ct(s) return ("%dm%.3fs"):format(math.floor(s / 60), s % 60) end
    local c = os.clock()
    sh:echo(ct(c) .. " " .. ct(0))
    sh:echo(ct(0) .. " " .. ct(0))
    sh.status = 0
  elseif cmd == "pwd" then
    local phys = false
    for j = 2, #args do if args[j]:find("P") then phys = true elseif args[j]:find("L") then phys = false end end
    local out
    if phys then out = sh:phys_cwd()
    else
      -- pwd -L (default): use $PWD only when it actually names the current directory
      -- (an absolute path with the same dev+inode as "."); a lied-about `PWD=foo`
      -- falls back to the physical cwd. But when the cwd is gone (stat "." fails),
      -- getcwd can't help either, so bash keeps $PWD as-is — only validate when the
      -- current directory is still accessible.
      out = sh:pwd()
      local same = out:sub(1, 1) == "/" and C.curse_stat(out, statbuf) == 0 and C.curse_stat(".", statbuf2) == 0
        and ffi.cast("uint64_t *", statbuf)[0] == ffi.cast("uint64_t *", statbuf2)[0]        -- st_dev @ 0
        and ffi.cast("uint64_t *", statbuf + 8)[0] == ffi.cast("uint64_t *", statbuf2 + 8)[0] -- st_ino @ 8
      -- fall back to the physical cwd only when it's actually available: if getcwd
      -- fails (the cwd was removed), bash keeps $PWD rather than printing nothing.
      if not same then local pc = sh:phys_cwd(); if pc ~= "" then out = pc end end
    end
    sh:echo(out); sh.status = 0
  elseif cmd == "umask" then
    -- umask [-S] [MODE]: print (octal or -S symbolic) or set the file-creation mask.
    local sflag, pflag, badflag, pos = false, false, false, {}
    for j = 2, #args do
      local a = args[j]
      if a == "-S" then sflag = true
      elseif a == "-p" then pflag = true -- print in a form that can be eval'd
      elseif a:sub(1, 1) == "-" and #a > 1 then badflag = true
      else pos[#pos + 1] = a end
    end
    local cur = tonumber(C.umask(0)) % 512; C.umask(cur)
    if badflag then io.stderr:write("curse: umask: invalid option\n"); sh.status = 1
    elseif #pos == 0 then -- bash ignores extra args; it uses only the first MODE
      local body = sflag and umask_symbolic(cur) or string.format("%04o", cur)
      sh:echo(pflag and ("umask " .. (sflag and "-S " or "") .. body) or body); sh.status = 0
    else
      local m = parse_umask(pos[1], cur)
      if m == nil then io.stderr:write("curse: umask: `" .. pos[1] .. "': invalid symbolic mode\n"); sh.status = 1
      else C.umask(m); sh.status = 0 end
    end
  elseif cmd == "getopts" then
    -- getopts OPTSTRING NAME [args…]: parse one option per call using OPTIND (+ an
    -- internal char cursor for bundled opts); sets NAME, OPTARG; status 1 when done.
    local spec, vname = args[2] or "", args[3] or "?"
    local silent = spec:sub(1, 1) == ":"
    local src_get, src_n
    if #args >= 4 then src_n = #args - 3; src_get = function(k) return args[k + 3] end
    else src_n = sh.nparams; src_get = function(k) return sh.params[k] end end
    local optind = math.max(1, math.floor(tonumber(sh:get("OPTIND")) or 1))
    local cur = sh.getopts_cur or 1
    -- A leftover OPTIND pointing past a now-shorter argument list (e.g. after a
    -- fresh `set --`) means a new scan: bash resets OPTIND to 1.
    if optind > src_n + 1 then optind = 1; cur = 1 end
    local res
    while not res do
      local word = optind <= src_n and src_get(optind) or nil
      if not word or word == "-" or word:sub(1, 1) ~= "-" then res = { done = true }
      elseif word == "--" then optind = optind + 1; res = { done = true }
      else
        local oc = word:sub(1 + cur, 1 + cur)
        if oc == "" then optind = optind + 1; cur = 1
        else
          local pos = spec:find(oc, 1, true)
          if not pos or oc == ":" then
            cur = cur + 1; if 1 + cur > #word then optind = optind + 1; cur = 1 end
            res = { opt = "?", arg = silent and oc or nil, err = not silent and ("illegal option -- " .. oc) }
          elseif spec:sub(pos + 1, pos + 1) == ":" then -- takes an argument
            local rest = word:sub(2 + cur)
            if rest ~= "" then sh:set_str("OPTARG", rest); optind = optind + 1; cur = 1; res = { opt = oc }
            else
              local a = (optind + 1) <= src_n and src_get(optind + 1) or nil
              if a then sh:set_str("OPTARG", a); optind = optind + 2; cur = 1; res = { opt = oc }
              else optind = optind + 1; cur = 1
                res = silent and { opt = ":", arg = oc } or { opt = "?", err = "option requires an argument -- " .. oc }
              end
            end
          else -- flag, no argument
            cur = cur + 1; if 1 + cur > #word then optind = optind + 1; cur = 1 end
            res = { opt = oc, clr = true } -- a no-arg option UNSETS OPTARG (bash)
          end
        end
      end
    end
    sh.getopts_cur = cur
    sh:set_str("OPTIND", tostring(optind))
    local valid = vname:match("^[%a_][%w_]*$") -- an invalid NAME -> status 1, var not set
    if res.done then
      if valid then sh:set_str(vname, "?") end
      sh.getopts_cur = 1; sh.vars["OPTARG"] = nil; sh.status = 1 -- end of options: OPTARG unset
    else
      if valid then sh:set_str(vname, res.opt) end
      if res.arg ~= nil then sh:set_str("OPTARG", res.arg) elseif res.err or res.clr then sh.vars["OPTARG"] = nil end
      if res.err then io.stderr:write("curse: " .. res.err .. "\n") end
      sh.status = valid and 0 or 1
    end
  elseif cmd == "printf" then
    -- printf [-v VAR] FMT [ARGS…] — native, bash-compatible.
    if args[2] == "-v" then
      local target = args[3]
      if target == nil then io.stderr:write("curse: printf: -v: option requires an argument\n"); sh.status = 2
      else
        local res, st = sh_printf(args[4] or "", args, 5)
        -- target may be NAME or NAME[SUBSCRIPT]
        local nm, sub = target:match("^([%a_][%w_]*)%[(.*)%]$")
        if nm then
          if sub == "" then io.stderr:write("curse: printf: `" .. target .. "': bad array subscript\n"); sh.status = 2
          else sh:array_set(nm, array_key(sh, nm, sub), res, false); sh.status = st end
        elseif target:find("%[") then -- malformed subscript like `a[`
          io.stderr:write("curse: printf: `" .. target .. "': bad array subscript\n"); sh.status = 2
        else sh:set_str(target, res); sh.status = st end
      end
    else
      local fi = 2
      if args[fi] == "--" then fi = fi + 1 end -- end of options
      if args[fi] == nil then
        io.stderr:write("curse: printf: usage: printf [-v var] format [arguments]\n"); sh.status = 2
      else
        local res, st = sh_printf(args[fi], args, fi + 1)
        sh.out(res)
        if sh.out == io.write and not io.flush() then sh.write_err = true end -- full disk etc.
        sh.status = st
      end
    end
  elseif cmd == "read" then
    -- read [-r] [-a arr] [-p prompt] VAR...  (line from stdin, split on IFS)
    local raw, arr, j, nchars, ndelim, ufd = false, nil, 2, nil, false, 0
    local delim, tmout
    while j <= #args do
      local a = args[j]
      if a == "--" then j = j + 1; break
      elseif a:sub(1, 1) == "-" and #a > 1 then
        -- parse a bundle like -rd, -rN 6; an arg-taking flag takes the attached
        -- rest of the word or the next word, and ends the bundle.
        local k, advance = 2, 1
        while k <= #a do
          local f = a:sub(k, k)
          local function takearg()
            local r = a:sub(k + 1)
            if r ~= "" then k = #a + 1; return r else advance = 2; k = #a + 1; return args[j + 1] end
          end
          if f == "r" then raw = true; k = k + 1
          elseif f == "d" then delim = takearg() or "\n"
          elseif f == "n" then nchars = tonumber(takearg())
          elseif f == "N" then nchars = tonumber(takearg()); ndelim = true
          elseif f == "a" then arr = takearg()
          elseif f == "u" then ufd = tonumber(takearg()) or 0
          elseif f == "p" then takearg() -- prompt: consume + ignore (non-interactive)
          elseif f == "t" then tmout = takearg() -- timeout (only -t 0 is honored below)
          else k = k + 1 end -- -s etc.: ignore
        end
        j = j + advance
      else break end
    end
    -- `read -t 0`: don't read anything — just report whether input is available
    -- on the fd (bash: status 0 if a read wouldn't block, non-zero otherwise).
    if tmout and tonumber(tmout) == 0 then sh.status = fd_ready(ufd) and 0 or 1; return end
    local vars = {}
    for k = j, #args do vars[#vars + 1] = args[k] end
    local line, had_nl = nil, true
    -- Read from `ufd` one byte at a time (never over-reading past the terminator),
    -- honoring -r (backslash escaping), -d DELIM, and -n/-N char counts. `dch` is
    -- the record delimiter: the line terminator (\n) unless -d overrode it; -N
    -- ignores the delimiter entirely.
    local dch = delim == nil and "\n" or (delim == "" and "\0" or delim:sub(1, 1))
    do
      local buf, got = {}, false
      while true do
        if nchars and #buf >= nchars then had_nl = true; break end -- -n/-N char limit reached
        local c = fd_getc(ufd)
        if c == nil then had_nl = false; break end
        got = true
        if not raw and c == "\\" then
          -- \<newline> is a line continuation (splice); other \x escapes the char
          -- (marked with \1 so IFS splitting treats it as literal, bash's CTLESC).
          local d = fd_getc(ufd)
          if d == nil then buf[#buf + 1] = "\\"; had_nl = false; break end
          if d == "\n" then -- swallow both (continuation), unless -N counts raw
          else buf[#buf + 1] = "\1" .. d end
        elseif not ndelim and c == dch then had_nl = true; break -- -N ignores the delimiter
        else buf[#buf + 1] = c end
      end
      line = got and table.concat(buf) or nil
    end
    if line == nil then
      sh.status = 1 -- EOF: nothing read
    else
      local ifs = sh.vars["IFS"] and sh:get("IFS") or " \t\n"
      if arr then
        sh:array_assign(arr, rt.ifs_split(ifs, line), false)
      elseif ndelim then -- -N: no IFS processing; first var gets everything, rest empty
        local plain = line:gsub("\1", "")
        if #vars == 0 then sh:set_str("REPLY", plain)
        else sh:set_str(vars[1], plain); for k = 2, #vars do sh:set_str(vars[k], "") end end
      elseif #vars == 0 then
        sh:set_str("REPLY", (line:gsub("\1", ""))) -- REPLY: the raw line, no IFS stripping
      else
        local fields = read_split(ifs, line, #vars)
        for k = 1, #vars do sh:set_str(vars[k], fields[k] or "") end
      end
      sh.status = had_nl and 0 or 1
    end
  elseif cmd == "mapfile" or cmd == "readarray" then
    -- mapfile [-t] [-d delim] [ARRAY]: read stdin lines into ARRAY (default MAPFILE)
    local strip, arr, j, dch = false, "MAPFILE", 2, "\n"
    local nmax, origin, skip = nil, nil, 0
    while args[j] do
      local a = args[j]
      if a == "-t" then strip = true; j = j + 1
      elseif a == "-d" then dch = (args[j + 1] or "\n"):sub(1, 1); if dch == "" then dch = "\0" end; j = j + 2
      elseif a == "-n" then nmax = tonumber(args[j + 1]) or 0; j = j + 2 -- read at most N
      elseif a == "-O" then origin = tonumber(args[j + 1]) or 0; j = j + 2 -- store from index N (keep the rest)
      elseif a == "-s" then skip = tonumber(args[j + 1]) or 0; j = j + 2 -- discard the first N
      elseif a == "-u" or a == "-c" or a == "-C" then j = j + 2
      elseif a:sub(1, 1) == "-" and #a > 1 then j = j + 1
      else break end
    end
    if args[j] then arr = args[j] end
    local all, buf = {}, {}
    while true do
      local c = io.read(1)
      if c == nil then if #buf > 0 then all[#all + 1] = table.concat(buf) end break end
      buf[#buf + 1] = c
      if c == dch then all[#all + 1] = strip and table.concat(buf):sub(1, -2) or table.concat(buf); buf = {} end
    end
    -- -s skips leading items; -n caps the count taken after the skip.
    local lines = {}
    for k = skip + 1, #all do
      if nmax and nmax > 0 and #lines >= nmax then break end
      lines[#lines + 1] = all[k]
    end
    if origin then -- -O: overwrite from `origin`, leaving earlier elements intact
      for k, ln in ipairs(lines) do sh:array_set(arr, origin + k - 1, ln, false) end
    else
      sh:array_assign(arr, lines, false)
    end
    sh.status = 0
  elseif cmd == "shift" then
    if args[3] ~= nil or (args[2] and not tonumber(args[2])) then -- too many / non-numeric args
      io.stderr:write("curse: shift: " .. (args[3] ~= nil and "too many arguments" or (args[2] .. ": numeric argument required")) .. "\n")
      sh.status = 1; if sh.opt_c then error({ __curse_exit = 1 }) end
    else
    local nn = tonumber(args[2]) or 1
    if nn < 0 or nn > sh.nparams then sh.status = 1 -- out of range: no-op, status 1 (bash)
    else
      for k = 1, sh.nparams - nn do sh.params[k] = sh.params[k + nn] end
      for k = sh.nparams - nn + 1, sh.nparams do sh.params[k] = nil end
      sh.nparams = sh.nparams - nn
      sh.status = 0
    end
    end
  elseif cmd == "local" then
    -- local [-naA] [+n] NAME[=val]…: shadow the var in this scope, honoring
    -- nameref (-n), indexed (-a) and associative (-A) attributes.
    local nref, assoc, plusn, rest, lok = false, false, false, {}, true
    for j = 2, #args do
      local a = args[j]
      if a == "--" then
      elseif a:sub(1, 1) == "-" and #a > 1 then
        if a:find("n") then nref = true end
        if a:find("A") then assoc = true end
      elseif a:sub(1, 1) == "+" and #a > 1 then
        if a:find("n") then plusn = true end
      else rest[#rest + 1] = a end
    end
    if #rest == 0 and not (nref or assoc or plusn) then
      -- bare `local` / `local -p`: list this frame's local variables (bash format)
      local saved, names = sh.savedstack[sh.pd], {}
      if saved then for nm in pairs(saved) do names[#names + 1] = nm end end
      table.sort(names)
      for _, nm in ipairs(names) do local d = fmt_decl(sh, nm); if d then sh:echo(d) end end
      sh.status = 0
    elseif not (nref or assoc or plusn) then
      for _, a in ipairs(rest) do
        local anm, sub, aop, aval = a:match("^([%a_][%w_]*)%[(.-)%](%+?=)(.*)$")
        if anm then -- local a[i]=v : create the element in a local array
          sh:localVar(anm); sh:array_set(anm, array_key(sh, anm, sub), aval, aop == "+=")
        elseif not (a:match("^[%a_][%w_]*$") or a:match("^[%a_][%w_]*%+?=") or a:find("[", 1, true)) then
          io.stderr:write("curse: local: `" .. a .. "': not a valid identifier\n"); lok = false
        elseif (function() local ln = a:match("^([%a_][%w_]*)"); local lb = ln and sh.vars[sh:deref(ln)]; return lb and lb.ro end)() then
          -- a readonly var can't be localized (bash errors, skips it, continues)
          io.stderr:write("curse: local: " .. a:match("^([%a_][%w_]*)") .. ": readonly variable\n"); lok = false
        else
          sh:localAssign(a)
          if sh.opt_a then local nm = a:match("^([%a_][%w_]*)"); local b = nm and sh.vars[sh:deref(nm)]
            if b and not b.arr then b.exported = true; C.setenv(nm, sh:get(nm), 1) end end
        end
      end
    else
      for _, a in ipairs(rest) do
        local nm, val = a:match("^([%a_][%w_]*)=(.*)$")
        local vname = nm or a
        sh:localVar(vname)
        if nm then
          if nref then
            if not sh:make_nameref(nm, val) then
              io.stderr:write("curse: local: `" .. (val or "") .. "': invalid variable name for name reference\n")
              lok = false
            end
          else if assoc then sh:declare_assoc(nm) end; sh:set_str(nm, val) end
        elseif plusn then sh:unref(vname)
        elseif nref then
          if not sh:make_nameref(vname) then
            io.stderr:write("curse: local: `" .. (sh.vars[vname] and sh.vars[vname].s or "") .. "': invalid variable name for name reference\n")
            lok = false
          end
        elseif assoc then sh:declare_assoc(vname) end
      end
    end
    sh.status = lok and 0 or 1
  elseif sh.functions[cmd] and not no_func then run_function(sh, cmd, sh.functions[cmd], args, hook)
  else sh:exec(unpack(args)) end -- external command
end

-- [[ … ]] evaluation. Reuses the test builtin's unary/binary; == is a shell glob
-- (literal when the RHS was quoted), =~ a regex (Lua-pattern approximation of ERE).
-- [[ ]] operands undergo word-initial tilde expansion (bash), unlike a scalar
-- var value. Only an UNQUOTED literal `~…` at word start expands.
local function word_initial_tilde(w)
  local p1 = w and w.parts and w.parts[1]
  return p1 and p1.lit ~= nil and not p1.q and p1.lit:sub(1, 1) == "~"
end
local function dbracket_word(sh, w)
  local s = expand_word(sh, w)
  if word_initial_tilde(w) and s:sub(1, 1) == "~" then return tilde_prefix(sh, s) end
  return s
end
local function dbracket_pattern(sh, w)
  local p = expand_pattern(sh, w)
  if word_initial_tilde(w) and p:sub(1, 1) == "~" then return tilde_prefix(sh, p) end
  return p
end
local function eval_dbracket(sh, node)
  local k = node.kind
  if k == "and" then return eval_dbracket(sh, node.l) and eval_dbracket(sh, node.r) end
  if k == "or" then return eval_dbracket(sh, node.l) or eval_dbracket(sh, node.r) end
  if k == "not" then return not eval_dbracket(sh, node.e) end
  if k == "str" then return dbracket_word(sh, node.word) ~= "" end
  if k == "unary" and node.op == "-v" then return var_is_set(sh, expand_word(sh, node.word)) end
  if k == "unary" then return unary(sh, node.op, dbracket_word(sh, node.word)) end
  if k == "binary" then
    local l, r, op = dbracket_word(sh, node.l), dbracket_word(sh, node.r), node.op
    local ic = sh.shopt.nocasematch and true or nil -- shopt -s nocasematch: case-insensitive
    if op == "==" or op == "=" then
      if node.rq and not ic then return l == r else return rt.glob_match(l, dbracket_pattern(sh, node.r), ic) end
    elseif op == "!=" then
      if node.rq and not ic then return l ~= r else return not rt.glob_match(l, dbracket_pattern(sh, node.r), ic) end
    elseif op == "=~" then
      -- a quoted part of the regex is matched literally (bash), so re-expand with
      -- regex-escaping of quoted segments instead of using the plain rhs.
      local caps, bad = rt.regex_captures(l, expand_regex(sh, node.r), ic) -- real POSIX ERE + BASH_REMATCH
      if bad then error({ __curse_regexerr = true }) end -- invalid regex -> [[ ]] status 2
      sh:array_assign("BASH_REMATCH", caps or {}, false)
      return caps ~= nil
    elseif op == "-eq" or op == "-ne" or op == "-lt" or op == "-le" or op == "-gt" or op == "-ge" then
      -- [[ ]] arithmetic comparisons evaluate each side as an arith EXPRESSION
      -- (bash: [[ 1+2 -eq 3 ]] is true), unlike `test` which needs integer literals.
      local nl = eval(sh, P.arith(l == "" and "0" or l))
      local nr = eval(sh, P.arith(r == "" and "0" or r))
      if op == "-eq" then return nl == nr elseif op == "-ne" then return nl ~= nr
      elseif op == "-lt" then return nl < nr elseif op == "-le" then return nl <= nr
      elseif op == "-gt" then return nl > nr else return nl >= nr end
    else return binary(l, op, r) end -- < > (string comparisons)
  end
  return false
end

-- Run a loop body, catching break/continue (decrementing multi-level n and
-- re-raising when it targets an outer loop). Returns "break", "continue", or nil.
local function run_loop_body(sh, body, hook)
  local ok, err = pcall(exec_list, sh, body, hook, false)
  if ok then return nil end
  if type(err) == "table" then
    if err.__curse_break then
      if err.__curse_break > 1 then error({ __curse_break = err.__curse_break - 1 }) end
      return "break"
    elseif err.__curse_continue then
      if err.__curse_continue > 1 then error({ __curse_continue = err.__curse_continue - 1 }) end
      return "continue"
    end
  end
  error(err) -- exit/return/real error propagates
end

-- In a forked child (subshell/background/pipeline stage), translate an exit/return
-- thrown as a control table into $? so the child _exits with the right status.
-- (A non-table Lua error is left for the caller; forked children then _exit anyway.)
local function child_status(sh, ok, err)
  if not ok and type(err) == "table" then sh.status = err.__curse_exit or err.__curse_return or sh.status end
end

-- Snapshot the <()/>() counts before a command expands its words/redirs, so its
-- cleanup drains ONLY the procsubs it registered — not ones an enclosing group's
-- redirect (`{ …; } > >(tac)`) left pending, which drain after the whole group.
local function procsub_mark(sh)
  return (sh.procsub_pending and #sh.procsub_pending or 0), (sh.procsub_files and #sh.procsub_files or 0)
end
-- Process-substitution cleanup, run after the command a <()/>() was attached to:
-- feed each new >(cmd) its temp file, then remove the temp files it created. Only
-- entries added since the (np,nf) mark are handled; gated to the outer level.
local function drain_procsub(sh, np, nf)
  np, nf = np or 0, nf or 0
  if (sh.in_subprogram or 0) ~= 0 then return end
  local pend = sh.procsub_pending
  if pend then
    for i = np + 1, #pend do
      local ps = pend[i]; io.flush()
      -- Run the >(cmd) body in a forked child through curse's OWN interpreter
      -- (never `sh -c`, which would recurse once curse is /bin/sh), stdin from temp.
      local pid = C.fork()
      if pid == 0 then
        local fd = C.open(ps.file, 0, 0) -- O_RDONLY
        if fd >= 0 then C.dup2(fd, 0); C.close(fd) end
        sh.in_subprogram = (sh.in_subprogram or 0) + 1; sh.out = io.write
        local ok, err = pcall(function() exec_list(sh, P.parse(ps.cmd).stmts, function() end, false) end)
        child_status(sh, ok, err)
        io.flush(); C._exit(sh.status or 0)
      end
      local stbuf = ffi.new("int[1]"); C.waitpid(pid, stbuf, 0)
    end
    for i = #pend, np + 1, -1 do pend[i] = nil end
    if #pend == 0 then sh.procsub_pending = nil end
  end
  local files = sh.procsub_files
  if files then
    for i = #files, nf + 1, -1 do os.remove(files[i]); files[i] = nil end
    if #files == 0 then sh.procsub_files = nil end
  end
end

-- Expand a simple command's words into `args` (in place). Module-level (not a
-- per-command closure) so it can be pcall'd directly without allocating. When the
-- command is a static declaration builtin, `name=value` words are assignment words
-- (no split/glob); everything else goes through the field engine.
local function expand_args(sh, st, args, is_assign)
  for wi, w in ipairs(st.words) do
    local p1 = w.parts[1]
    if wi > 1 and is_assign and p1 and p1.lit and p1.lit:match("^[%a_][%w_]*%+?=") then
      args[#args + 1] = expand_assign_word(sh, w, true) -- name=value word: no glob, ~ after =/:
    else
      local fs = expand_to_fields(sh, w)
      for k = 1, #fs do args[#args + 1] = fs[k] end
    end
  end
end

-- Declaration builtins whose `name=value` arguments are assignment words.
local ASSIGN_CMD = { export = 1, declare = 1, typeset = 1, readonly = 1, ["local"] = 1 }
-- compound commands whose trailing redirs (`done < f`, `fi > f`) apply to the
-- whole construct; handled generically below (simple/group/subshell do their own).
local COMPOUND_REDIR = { whilec = true, forc = true, forin = true, ["if"] = true,
  case = true, arithcmd = true, dbracket = true, group = true }
-- DEBUG trap fires just before each of these "command" nodes (bash runs it before
-- every simple/pipeline/arith/[[/assignment); it preserves $? around the handler.
local DEBUG_FIRE = { simple = true, pipeline = true, arithcmd = true, dbracket = true,
  assign = true, assignlist = true }
local function run_debug(sh, line)
  local h = sh.traps and sh.traps.DEBUG
  if not h or h == "" or sh.in_debug then return end
  -- DEBUG fires only at the current level (bash): not for commands inside a
  -- function call, or a subshell/command substitution — unless functrace extends it.
  if not sh.opt_functrace and ((sh.calldepth or 0) > 0 or (sh.in_subprogram or 0) > 0) then return end
  sh.in_debug = true
  local saved = sh.status
  if line then sh.cur_line = line end
  local exited = run_trap(sh, h)
  local trap_status = sh.status
  sh.status = saved; sh.in_debug = false
  -- `exit` in a DEBUG trap exits the shell; a non-zero DEBUG return under errexit
  -- also exits (skipping the command), matching bash.
  if exited then error({ __curse_exit = trap_status }) end
  if sh.opt_e and trap_status ~= 0 then error({ __curse_exit = trap_status }) end
end

local tv_now = ffi.new("struct curse_timeval") -- reused buffer for `time`'s wall clock
local function wall_secs()
  C.gettimeofday(tv_now, nil); return tonumber(tv_now.tv_sec) + tonumber(tv_now.tv_usec) * 1e-6
end
local function fmt_time(s) return ("%dm%.3fs"):format(math.floor(s / 60), s % 60) end

local exec_stmt
exec_stmt = function(sh, st, hook)
  local t = st.t
  -- `time [-p] pipeline` reserved word: run the pipeline (with its own type/negate
  -- preserved for errexit), then report elapsed real/user/sys to STDERR like bash.
  if st.timed then
    st.timed = false
    local r0, c0 = wall_secs(), os.clock()
    local ok, err = pcall(exec_stmt, sh, st, hook)
    local real, cpu = wall_secs() - r0, os.clock() - c0
    st.timed = true
    if st.timed_p then io.stderr:write(("real %.2f\nuser %.2f\nsys %.2f\n"):format(real, cpu, 0))
    else io.stderr:write(("\nreal\t%s\nuser\t%s\nsys\t%s\n"):format(fmt_time(real), fmt_time(cpu), fmt_time(0))) end
    if not ok then error(err) end
    return
  end
  -- set -n (noexec): a non-interactive shell reads but does not execute. Once on,
  -- every later statement (including `set +n`) is skipped — matches bash.
  if sh.opt_n and not sh.opt_i then sh.status = 0; return end
  if DEBUG_FIRE[t] and not (sh.in_trap and sh.in_trap > 0) then run_debug(sh, st.line) end
  -- redirs trailing a compound command: apply around the whole thing, then run it
  -- with redirs temporarily detached (so this guard doesn't re-fire).
  if st.redirs and COMPOUND_REDIR[t] then
    local rd = st.redirs
    local pnp, pnf = procsub_mark(sh) -- a >() redirect target drains after the whole command
    local save, ok = apply_redirs(sh, rd)
    if not ok then sh.status = 1; restore_redirs(save)
      if sh.opt_e then error({ __curse_exit = 1 }) end -- errexit: a redirect failure exits
      return end
    local savedout = sh.out; if redirs_touch_stdout(rd) then sh.out = io.write end
    st.redirs = nil
    local pok, err = pcall(exec_stmt, sh, st, hook)
    st.redirs = rd
    io.flush(); sh.out = savedout; restore_redirs(save)
    drain_procsub(sh, pnp, pnf) -- a >() redirect target on a compound command runs after it
    if not pok then error(err) end
    return
  end
  if st.line and not (sh.in_trap and sh.in_trap > 0) then sh.cur_line = st.line end -- $LINENO (frozen in traps)
  if t == "assign" then
    if st.name == "SHELLOPTS" or st.name == "BASHOPTS" then -- readonly specials (bash)
      io.stderr:write("curse: " .. st.name .. ": readonly variable\n")
      sh.status = 1; if sh.opt_c or sh.opt_posix then error({ __curse_exit = 1 }) end; return
    end
    if st.index == "" then -- `a[]=v`: empty subscript is a bad array subscript (bash: status 1, no assign)
      io.stderr:write("curse: `" .. st.name .. "[]': bad array subscript\n"); sh.status = 1; return
    end
    local rb = sh.vars[sh:deref(st.name)]
    -- A nameref whose target carries a subscript (declare -n ref='A[K]'): a plain
    -- `ref=v` / `ref+=v` writes THROUGH to that element, not the base array's [0].
    local nref_base, nref_sub
    if not st.index and not st.arith then
      local nb = sh.vars[st.name]
      if nb and nb.ref and nb.s then
        -- a nameref cycle (ref1->ref2->ref1) derefs to "" — bash detects it on write
        if nb.s ~= "" and sh:deref(st.name) == "" then
          io.stderr:write("curse: warning: " .. st.name .. ": circular name reference\n")
          sh.status = 1; return
        end
        nref_base, nref_sub = nb.s:match("^([%a_][%w_]*)%[(.+)%]$")
      end
    end
    -- `ref[i]=` where ref is a nameref TO a subscripted element (`a[0]`) would be
    -- `a[0][i]` — not a valid identifier (bash: status 1, no assign).
    if st.index then
      local nb = sh.vars[st.name]
      if nb and nb.ref and nb.s and nb.s:match("^[%a_][%w_]*%[.+%]$") then
        io.stderr:write("curse: `" .. nb.s .. "': not a valid identifier\n"); sh.status = 1; return
      end
    end
    if rb and rb.ro then -- readonly: reject the assignment (status 1); fatal in `sh -c`
      io.stderr:write("curse: " .. st.name .. ": readonly variable\n") -- or posix mode; a plain script keeps going.
      sh.status = 1; if sh.opt_c or sh.opt_posix then error({ __curse_exit = 1 }) end; return
    else
    -- A bad substitution / invalid indirect in the RHS fails the assignment but is
    -- NON-fatal (bash: `x=${bad|y}` leaves x unset, status 1, script continues) —
    -- like a bad-subst in a command word. Catch it around the RHS expansion.
    local aok, aerr = pcall(function()
    if nref_base then
      sh:array_set(nref_base, array_key(sh, nref_base, nref_sub), expand_assign_word(sh, st.rhs), st.append)
    elseif st.index then
      if not sh:array_set(st.name, array_key(sh, st.name, st.index), expand_assign_word(sh, st.rhs), st.append) then
        error({ __curse_badsub = true })
      end
    elseif st.arith then
      sh:aset(st.name, eval(sh, st.arith))
    elseif st.append then
      local b = sh.vars[sh:deref(st.name)]
      if b and b.arr then -- `name+=value` on an array appends to element 0 (bash)
        sh:array_set(st.name, array_key(sh, st.name, "0"), expand_assign_word(sh, st.rhs), true)
      elseif b and b.int then -- integer var: += is arithmetic addition
        sh:aset(st.name, sh:aget(st.name) + eval(sh, P.arith(expand_word(sh, st.rhs))))
      else
        sh:set_str(st.name, sh:get(st.name) .. expand_assign_word(sh, st.rhs))
      end
    else
      local b = sh.vars[sh:deref(st.name)]
      if b and b.arr then -- plain `name=value` on an array var writes element 0 (bash)
        sh:array_set(st.name, array_key(sh, st.name, "0"), expand_assign_word(sh, st.rhs), false)
      elseif b and b.int then -- integer var (declare -i): assign arith-evaluates
        sh:aset(st.name, eval(sh, P.arith(expand_word(sh, st.rhs))))
      elseif b and (b.lower or b.upper) then -- declare -l/-u: case-fold on assign
        local v = expand_assign_word(sh, st.rhs)
        sh:set_str(st.name, b.lower and v:lower() or v:upper())
      else
        sh:set_str(st.name, expand_assign_word(sh, st.rhs))
      end
    end
    end)
    if not aok then
      if type(aerr) == "table" and aerr.__curse_badsub then
        io.stderr:write("curse: " .. st.name .. ": bad array subscript\n"); sh.status = 1; return
      elseif type(aerr) == "table" and aerr.__curse_experr then sh.status = 1; return -- bad-subst RHS: non-fatal
      else error(aerr) end -- a real error (exit, nounset, matherr) propagates
    end
    end
    -- set -a (allexport): a plain scalar assignment auto-exports the variable
    if sh.opt_a and not st.index then
      local b = sh.vars[sh:deref(st.name)]
      if b and not b.arr then b.exported = true; C.setenv(st.name, sh:get(st.name), 1) end
    end
    -- exit status of an assignment = the last command substitution's, else 0
    -- (skip when it was a rejected readonly assignment, which already set status 1)
    if not (rb and rb.ro) then
      local hascs = false
      if st.rhs then for _, p in ipairs(st.rhs.parts) do if p.cmdsub then hascs = true; break end end end
      if not hascs then sh.status = 0 end
    end
    sh:set_str("_", "") -- a bare assignment resets $_ to empty (bash)
  elseif t == "arrayassign" then
    local rb = sh.vars[sh:deref(st.name)]
    if st.index then -- `a[0]=(1 2)`: can't assign a list to an array MEMBER (bash)
      io.stderr:write("curse: " .. st.name .. "[" .. st.index .. "]: cannot assign list to array member\n"); sh.status = 1
    elseif rb and rb.ro then -- readonly array: reject the (re)assignment
      io.stderr:write("curse: " .. st.name .. ": readonly variable\n"); sh.status = 1
    else
      -- a failglob no-match inside `a=(*.ZZ)` fails the assignment non-fatally (bash)
      local aok, aerr = pcall(do_arrayassign, sh, st)
      if aok then sh.status = 0; sh:set_str("_", "")
      elseif type(aerr) == "table" and aerr.__curse_experr then
        sh.status = 1; if sh.opt_e then error({ __curse_exit = 1 }) end
      else error(aerr) end
    end
  elseif t == "funcdef" then
    sh.functions[st.name] = st.body
    sh.func_redirs = sh.func_redirs or {}; sh.func_redirs[st.name] = st.redirs -- `f(){ … } >&2`
    sh.func_src = sh.func_src or {}; sh.func_src[st.name] = st.deftext -- verbatim def for declare -f
    sh.status = 0
  elseif t == "assignlist" then
    for _, a in ipairs(st.list) do exec_stmt(sh, a, hook) end
    sh.status = 0
  elseif t == "simple" then
    local pnp, pnf = procsub_mark(sh) -- drain only <()/>() this command registers
    -- alias expansion (bash: only with `shopt -s expand_aliases`): if the command
    -- word is a defined alias not already expanded (loop guard), splice its parsed
    -- words in and re-dispatch — recursively expanding the new first word too.
    if sh.shopt.expand_aliases and st.words[1] then
      local cw = st.words[1]
      local nm = (#cw.parts == 1 and cw.parts[1].lit ~= nil and not cw.parts[1].q) and cw.parts[1].lit or nil
      local seen = st.alias_seen
      local av = nm and not (seen and seen[nm]) and sh.aliases[nm]
      if av then
        local parsed = P.parse(av)
        seen = seen or {}; seen[nm] = true
        if parsed.stmts and #parsed.stmts == 1 and parsed.stmts[1].t == "simple" then
          local nw = {}
          for _, w in ipairs(parsed.stmts[1].words) do nw[#nw + 1] = w end
          -- trailing-space chaining: when an alias value ends in a blank, the next
          -- word is also alias-expanded (bash). Keep chaining while that holds.
          local rest, ends_space = 2, av:match("%s$") ~= nil
          while ends_space and st.words[rest] do
            local w2 = st.words[rest]
            local nm2 = (#w2.parts == 1 and w2.parts[1].lit ~= nil and not w2.parts[1].q) and w2.parts[1].lit or nil
            local av2 = nm2 and not seen[nm2] and sh.aliases[nm2]
            if not av2 then break end
            local p2 = P.parse(av2)
            if not (p2.stmts and #p2.stmts == 1 and p2.stmts[1].t == "simple") then break end
            seen[nm2] = true
            for _, w in ipairs(p2.stmts[1].words) do nw[#nw + 1] = w end
            ends_space = av2:match("%s$") ~= nil; rest = rest + 1
          end
          for k = rest, #st.words do nw[#nw + 1] = st.words[k] end
          return exec_stmt(sh, { t = "simple", words = nw, redirs = st.redirs, assigns = st.assigns,
            arrayargs = parsed.stmts[1].arrayargs, alias_seen = seen }, hook)
        elseif parsed.stmts then
          for _, s in ipairs(parsed.stmts) do exec_stmt(sh, s, hook) end
          return
        end
      end
    end
    -- `name=value` arguments to a declaration builtin (ASSIGN_CMD, module-level)
    -- are ASSIGNMENT words: the value isn't word-split or globbed.
    -- Assignment-word treatment applies only when the command name is a STATIC
    -- (literal, unquoted) declaration builtin — `typeset x=$x` splits, but
    -- `cmd=typeset; $cmd x=$x` does NOT (bash: the name must be recognized before
    -- expansion). Detected from the pre-expansion first word, not the expanded one.
    local cw1 = st.words[1]
    local cw1lit = cw1 and #cw1.parts == 1 and cw1.parts[1].lit ~= nil and not cw1.parts[1].q
      and cw1.parts[1].lit or nil
    local is_assign = cw1lit ~= nil and ASSIGN_CMD[cw1lit] ~= nil
    local args = {}
    -- A word-expansion error (bad substitution, invalid indirect name) aborts the
    -- WHOLE simple command with status 1 but is non-fatal: the script continues.
    local eok, eerr = pcall(expand_args, sh, st, args, is_assign)
    if not eok then
      if type(eerr) == "table" and eerr.__curse_experr then
        sh.status = 1
        if sh.opt_e then error({ __curse_exit = 1 }) end
        return
      end
      error(eerr)
    end
    -- A command whose argv is empty after expansion but which contained command
    -- substitution(s) takes the LAST cmdsub's exit status (bash: `false` -> 1,
    -- $(exit 42) -> 42). With no cmdsub and no assigns it's a no-op (status 0).
    if #args == 0 and not st.arrayargs then
      -- No command word. Any prefix assignments are PERMANENT (there is no command
      -- to scope them to) and take effect even if a following redirect fails —
      -- bash applies `abc=def > /nonexistent` regardless (only the status is 1).
      if st.assigns then
        for _, a in ipairs(st.assigns) do
          if a.raw then sh:set_str(a.name, a.raw) else exec_stmt(sh, a, hook) end
        end
      else -- a bare $(...) / redirection: status is the last cmdsub's, else 0
        local hadcs = false
        for _, w in ipairs(st.words) do for _, p in ipairs(w.parts) do if p.cmdsub then hadcs = true; break end end end
        sh.status = hadcs and (sh.last_cmdsub_status or 0) or 0
      end
      -- a redirection with no command still opens/truncates its target (`> file`)
      if st.redirs then
        local save, ok = apply_redirs(sh, st.redirs)
        if not ok then sh.status = 1 end
        restore_redirs(save)
      end
      return
    end
    if st.arrayargs then -- `declare -A a=(...)` / `local -a b=(...)` array literals
      -- Only append the names now (so `declare -A a=(...)` isn't seen as a bare
      -- listing and so `local`/`declare` establishes the scope + attributes). The
      -- actual array assignment happens AFTER the builtin runs (below), so it lands
      -- in the freshly-declared/local variable.
      for _, aa in ipairs(st.arrayargs) do args[#args + 1] = aa.name end
    end
    -- `exec [redirs] [cmd…]`: redirections are permanent (not restored). With no
    -- command it just rewires the shell's own fds (e.g. `exec 3>file`); with a
    -- command it replaces the shell process with that command.
    if args[1] == "exec" then
      io.flush()
      local ok = true
      if st.redirs then _, ok = apply_redirs(sh, st.redirs) end
      -- exec [-a name] [--] [cmd…]
      local k, argv0 = 2, nil
      while args[k] == "-a" or args[k] == "--" or (args[k] and args[k]:sub(1, 2) == "-a") do
        if args[k] == "--" then k = k + 1; break
        elseif args[k] == "-a" then argv0 = args[k + 1]; k = k + 2
        else argv0 = args[k]:sub(3); k = k + 1 end
      end
      if k <= #args then
        local rest = { unpack(args, k) }
        if argv0 then sh.exec_argv0 = argv0 end -- exec -a NAME: override the child's argv[0]
        if st.assigns then -- prefix bindings become the exec'd command's environment (bash)
          for _, a in ipairs(st.assigns) do
            if a.raw then sh:set_str(a.name, a.raw); C.setenv(a.name, a.raw, 1)
            else exec_stmt(sh, a, hook); if not a.index then C.setenv(a.name, sh:get(a.name), 1) end end
          end
        end
        exec_simple(sh, rest, hook)
        io.flush(); os.exit(sh.status or 0)
      else
        sh.status = ok and 0 or 1
      end
      return
    end
    local function run_cmd()
      sh.write_err = nil -- a builtin sets this on an output write error (e.g. full disk)
      if st.redirs then
        local save, ok = apply_redirs(sh, st.redirs)
        if not ok then
          sh.status = 1; restore_redirs(save) -- open failed: skip the command
        else
          -- Only route builtin/captured output to the real fd 1 when a redirect
          -- actually targets stdout; a stdin-only redirect (heredoc, `<`) must not
          -- steal fd-1 output away from a $(...) capture buffer.
          local savedout = sh.out
          if redirs_touch_stdout(st.redirs) then sh.out = io.write end
          local pok, err = pcall(exec_simple, sh, args, hook)
          io.flush(); sh.out = savedout; restore_redirs(save)
          if pok and sh.write_err then sh.status = 1 end -- builtin hit a write error
          if not pok then error(err) end
        end
      else
        exec_simple(sh, args, hook)
        if sh.write_err then sh.status = 1 end -- builtin hit a write error (e.g. full disk)
      end
    end
    if st.assigns then
      -- prefix assignments: apply as a temporary, EXPORTED env for this command
      -- only, then restore (both the shell var and the process env). Each binding
      -- is pushed onto sh.tenv (LIFO) so an `unset` inside the command reveals the
      -- shadowed value beneath instead of leaving the name unset (bash dynamic
      -- scope); a consumed entry is skipped on restore.
      local base = #sh.tenv
      for _, a in ipairs(st.assigns) do
        local b = sh.vars[a.name] -- COPY the box: exec_stmt mutates it in place
        sh.vseq = sh.vseq + 1
        sh.tenv[#sh.tenv + 1] = { name = a.name, env = os.getenv(a.name), consumed = false, seq = sh.vseq,
          box = b and { s = b.s, n = b.n, arr = b.arr, assoc = b.assoc, order = b.order,
                        exported = b.exported, ro = b.ro, ref = b.ref } or false }
        if a.raw then -- NAME=(…) as a command prefix is a literal string, not an array (bash)
          sh:set_str(a.name, a.raw); C.setenv(a.name, a.raw, 1)
        else
          exec_stmt(sh, a, hook)
          -- An array-element prefix (`b[0]=2 cmd`) is a temporary assignment but is
          -- NOT put in the command's environment (bash), unlike a scalar `x=v cmd`.
          if not a.index then C.setenv(a.name, sh:get(a.name), 1) end
        end
      end
      -- mark these entries so a DIRECT function call (not `eval`/a builtin) can tag
      -- them with its frame: `local x` absorbs only its OWN call's tempenv.
      sh.tenv_call_base = base
      local ok, err = pcall(run_cmd)
      sh.tenv_call_base = nil
      for k = #sh.tenv, base + 1, -1 do
        local s = sh.tenv[k]; sh.tenv[k] = nil
        if not s.consumed then -- an `unset` inside the command already revealed it
          sh.vars[s.name] = s.box or nil
          if s.env then C.setenv(s.name, s.env, 1) else C.unsetenv(s.name) end
        end
      end
      if not ok then error(err) end
    else
      run_cmd()
    end
    -- Array literals for a declaration builtin are assigned AFTER it runs, so a
    -- `local a=(…)` / `declare -A a=(…)` lands in the now-local/assoc variable.
    -- Skip when the builtin failed (e.g. a rejected -A/-a type change): the array
    -- must stay untouched, not be mangled by the literal.
    if st.arrayargs and sh.status == 0 then for _, aa in ipairs(st.arrayargs) do do_arrayassign(sh, aa) end end
    -- $_ : the last argument (after expansion) of the command just run.
    if #args > 0 then sh:set_str("_", args[#args]) end
    -- PIPESTATUS for a simple command is a one-element array of its exit status.
    sh:array_assign("PIPESTATUS", { tostring(sh.status) }, false)
    drain_procsub(sh, pnp, pnf) -- feed >() temps, clean up <()/>() temp files
  elseif t == "forc" then
    if st.init then eval(sh, st.init) end
    local bodystatus = 0 -- a loop's status is its last body command's (0 if none)
    sh.loopdepth = (sh.loopdepth or 0) + 1
    while true do
      hook("loop", st.id)
      if st.cond and not truth(eval(sh, st.cond)) then break end
      local act = run_loop_body(sh, st.body, hook); bodystatus = sh.status
      if act == "break" then break end
      if st.step then eval(sh, st.step) end -- continue still runs the step
    end
    sh.loopdepth = sh.loopdepth - 1
    sh.status = bodystatus
  elseif t == "whilec" then
    local bodystatus = 0
    sh.loopdepth = (sh.loopdepth or 0) + 1
    while true do
      hook("loop", st.id)
      -- a break/continue in the CONDITION affects this loop too (bash)
      sh.noerr = sh.noerr + 1
      local cok, cerr = pcall(exec_list, sh, st.cond, hook, false)
      sh.noerr = sh.noerr - 1
      if not cok then
        if type(cerr) == "table" and cerr.__curse_break then break
        elseif type(cerr) == "table" and cerr.__curse_continue then -- fallthrough to re-test
        else sh.loopdepth = sh.loopdepth - 1; error(cerr) end
      end
      local go = (sh.status == 0)
      if st.negate then go = not go end -- until
      if not go then break end
      local act = run_loop_body(sh, st.body, hook); bodystatus = sh.status
      if act == "break" then break end
    end
    sh.loopdepth = sh.loopdepth - 1
    sh.status = bodystatus
  elseif t == "parse_error" then
    -- Reached the unparseable tail (e.g. a makeself binary payload) — bash would
    -- syntax-error here too. If an earlier exit fired, we never get here.
    io.stderr:write("curse: syntax error" .. (st.line and (": line " .. st.line) or "") .. "\n")
    error({ __curse_exit = 2, __curse_parseerr = true })
  elseif t == "group" then
    -- { list; } runs in the current shell. Any trailing redirs are applied by the
    -- COMPOUND_REDIR wrapper above (which checks open failures + errexit), so here
    -- st.redirs is already detached.
    exec_list(sh, st.body, hook, false)
  elseif t == "subshell" then
    -- ( list ) runs in a forked child: env/var changes don't escape, like bash
    io.flush() -- flush parent stdio so the fork doesn't duplicate buffered output
    -- Inside a $(…) capture, the child's stdout must reach the capture buffer, not
    -- the real fd 1 (a forked subshell would otherwise LEAK past the in-process
    -- capture) — route it through a pipe the parent drains into sh.out. A stdout
    -- redirect in the body still overrides fd 1 in the child (pipe drains empty).
    local cap = sh.capturing and true
    local pfd
    if cap then pfd = ffi.new("int[2]"); if C.pipe(pfd) ~= 0 then cap = false end end
    local pid = C.fork()
    if pid == 0 then
      if cap then C.close(pfd[0]); C.dup2(pfd[1], 1); C.close(pfd[1]) end
      sh.in_subprogram = (sh.in_subprogram or 0) + 1 -- ERR trap won't fire here (sans errtrace)
      sh.loopdepth = 0 -- a loop enclosing this subshell isn't ours to break/continue
      local ok, err = pcall(function()
        if st.redirs then apply_redirs(sh, st.redirs) end
        sh.out = io.write
        exec_list(sh, st.body, hook, false)
      end)
      child_status(sh, ok, err)
      io.flush() -- flush BEFORE _exit (which doesn't); exit/error skips an inline flush
      C._exit(sh.status or 0)
    end
    if cap then -- parent: drain the child's stdout into the capture buffer, then reap
      C.close(pfd[1])
      local rbuf = ffi.new("char[8192]")
      while true do
        local nr = tonumber(C.read(pfd[0], rbuf, 8192))
        if not nr or nr <= 0 then break end
        sh.out(ffi.string(rbuf, nr))
      end
      C.close(pfd[0])
    end
    local stbuf = ffi.new("int[1]"); C.waitpid(pid, stbuf, 0)
    sh.status = rt.wexit(stbuf[0])
  elseif t == "background" then
    -- cmd & : fork, run in the child; parent records $! and continues (status 0).
    io.flush()
    local pid = C.fork()
    if pid == 0 then
      -- Without job control, an async command's stdin is /dev/null (bash), so it
      -- can't steal the terminal — and it must not inherit a redirect it didn't ask for.
      local dn = C.open("/dev/null", 0, 0); if dn >= 0 then C.dup2(dn, 0); C.close(dn) end
      sh.in_subprogram = (sh.in_subprogram or 0) + 1 -- async subprogram: ERR trap won't fire (sans errtrace)
      sh.loopdepth = 0
      local ok, err = pcall(function() sh.out = io.write; exec_stmt(sh, st.cmd, hook) end)
      child_status(sh, ok, err)
      io.flush(); C._exit(sh.status or 0)
    end
    -- register the job (for `jobs`/`wait %spec`/`wait -n`); best-effort command text
    local c1 = st.cmd
    while c1 and (c1.t == "pipeline") and c1.cmds do c1 = c1.cmds[1] end
    local cmdstr = (c1 and c1.words and c1.words[1] and c1.words[1].parts[1] and c1.words[1].parts[1].lit) or "job"
    job_add(sh, pid, cmdstr)
    sh.bg_pids = sh.bg_pids or {}
    sh.bg_pids[#sh.bg_pids + 1] = pid
    sh.status = 0
  elseif t == "arithcmd" then
    -- A `(( expr ))` command (standalone or as an if/while condition) is NOT fatal
    -- on a division-by-zero — it just yields status 1 and execution continues
    -- (unlike a `$(( ))` word expansion, which aborts the command list).
    local ok, v = pcall(eval, sh, st.expr)
    if ok then sh.status = truth(v) and 0 or 1
    elseif type(v) == "table" and v.__curse_matherr then sh.status = 1
    else error(v) end
  elseif t == "dbracket" then
    if st.expr and st.expr.kind == "syntaxerr" then -- malformed [[ ]]: fatal syntax error (bash aborts)
      io.stderr:write("curse: syntax error in conditional expression\n"); sh.status = 2
      if not sh.opt_i then error({ __curse_exit = 2 }) end
      return
    end
    -- like `(( ))`, a `[[ ]]` test is not fatal on an arith error in an operand
    -- (e.g. `[[ a =~ $((1/0)) ]]`): it yields status 1 and execution continues.
    local ok, v = pcall(eval_dbracket, sh, st.expr)
    if ok then sh.status = v and 0 or 1
    elseif type(v) == "table" and v.__curse_regexerr then sh.status = 2
    elseif type(v) == "table" and v.__curse_matherr then sh.status = 1
    else error(v) end
  elseif t == "case" then
    local subj = expand_word(sh, st.subject)
    local fall = false -- carrying a `;&` fall-through into the next clause
    sh.status = 0
    for _, cl in ipairs(st.clauses) do
      local matched = fall
      if not matched then
        for _, pat in ipairs(cl.pats) do
          local g = expand_pattern(sh, P.parse_word(pat)) -- vars resolved; quoted metachars literal
          if rt.glob_match(subj, g, sh.shopt.nocasematch and true or nil) then matched = true; break end
        end
      end
      if matched then
        exec_list(sh, cl.body, hook, false)
        if cl.term == "fall" then fall = true -- ;& : run the next clause's body too
        elseif cl.term == "test" then fall = false -- ;;& : keep testing later patterns
        else break end -- ;; : done
      end
    end
  elseif t == "andor" then
    -- run each pipeline, short-circuiting on the running exit status
    local ran_last = false
    for k, it in ipairs(st.items) do
      local go
      if it.op == nil then go = true
      elseif it.op == "&&" then go = (sh.status == 0)
      else go = (sh.status ~= 0) end -- "||"
      if go then exec_stmt(sh, it.cmd, hook) end
      if k == #st.items then ran_last = go end
    end
    -- ERR/errexit apply to an &&/|| list only via its FINAL operand (bash exempts
    -- the earlier ones): fire if that operand ran and failed, outside a condition.
    if ran_last and sh.noerr == 0 and sh.status ~= 0 then fire_err(sh) end
  elseif t == "pipeline" then
    -- fork a child per stage wired by pipes; the last stage's exit status is the
    -- pipeline's. Each child is guarded so a failure can never return into the
    -- interpreter and fork-bomb. The last stage's stdout goes to the shell's fd 1,
    -- except inside $(...) (sh.capturing) where it is drained into the capture buffer.
    local cmds, nst = st.cmds, #st.cmds
    if nst == 1 then
      exec_stmt(sh, cmds[1], hook) -- just a `! cmd` negation, no real pipe
    else
      io.flush() -- flush parent stdio so forked stages don't duplicate buffered output
      -- shopt -s lastpipe (non-interactive): the LAST stage runs in the CURRENT
      -- shell (no fork), so its side effects — e.g. `read var` — persist.
      local lastpipe = sh.shopt.lastpipe and not sh.opt_i and nst >= 2
      local pids, prev_read, inline_status = {}, -1, nil
      for k = 1, nst do
        local rd, wr = -1, -1
        if k < nst then local p = ffi.new("int[2]"); C.pipe(p); rd, wr = p[0], p[1] end
        if k == nst and lastpipe then
          local save0 = C.dup(0)
          if prev_read >= 0 then C.dup2(prev_read, 0); C.close(prev_read); prev_read = -1 end
          local savedout = sh.out; sh.out = io.write
          local ok, err = pcall(exec_stmt, sh, cmds[k], hook)
          io.flush(); sh.out = savedout; C.dup2(save0, 0); C.close(save0)
          if not ok and type(err) == "table" then sh.status = err.__curse_exit or err.__curse_return or sh.status
          elseif not ok then error(err) end
          inline_status = sh.status or 0; pids[k] = -1
        elseif k == nst and sh.capturing then
          -- inside $(...): the last stage's stdout must land in the capture buffer,
          -- not the shell's real fd 1. Wire it to a pipe the parent drains into sh.out.
          local cp = ffi.new("int[2]"); C.pipe(cp)
          local pid = C.fork()
          if pid == 0 then
            local ok, err = pcall(function()
              if prev_read >= 0 then C.dup2(prev_read, 0); C.close(prev_read) end
              C.dup2(cp[1], 1); C.close(cp[1]); C.close(cp[0])
              sh.out = io.write
              exec_stmt(sh, cmds[k], hook)
            end)
            child_status(sh, ok, err)
            io.flush(); C._exit(sh.status or 0)
          end
          pids[k] = pid
          if prev_read >= 0 then C.close(prev_read); prev_read = -1 end
          C.close(cp[1]) -- parent keeps only the read end; drain to EOF before waitpid
          local chunks, rbuf = {}, ffi.new("char[65536]")
          while true do
            local n = tonumber(C.read(cp[0], rbuf, 65536))
            if n <= 0 then break end
            chunks[#chunks + 1] = ffi.string(rbuf, n)
          end
          C.close(cp[0]); sh.out(table.concat(chunks))
        else
          local pid = C.fork()
          if pid == 0 then
            local ok, err = pcall(function()
              if prev_read >= 0 then C.dup2(prev_read, 0); C.close(prev_read) end
              if wr >= 0 then C.dup2(wr, 1); C.close(wr) end
              if rd >= 0 then C.close(rd) end
              sh.out = io.write -- this stage writes to its fd 1 (the pipe / terminal)
              exec_stmt(sh, cmds[k], hook)
            end)
            child_status(sh, ok, err)
            io.flush() -- before _exit (exit/error in the stage would skip an inline flush)
            C._exit(sh.status or 0)
          end
          pids[k] = pid
          if prev_read >= 0 then C.close(prev_read) end
          if wr >= 0 then C.close(wr) end
          prev_read = rd
        end
      end
      if prev_read >= 0 then C.close(prev_read) end
      local stbuf = ffi.new("int[1]")
      local last, pipe, pstat = 0, 0, {}
      for k = 1, nst do
        local est
        if pids[k] == -1 then est = inline_status or 0 -- ran inline (lastpipe)
        else
          C.waitpid(pids[k], stbuf, 0)
          est = rt.wexit(stbuf[0])
        end
        pstat[k] = tostring(est)
        if k == nst then last = est end
        if est ~= 0 then pipe = est end -- rightmost non-zero (for pipefail)
      end
      sh:array_assign("PIPESTATUS", pstat, false) -- ${PIPESTATUS[@]}
      sh.status = sh.opt_pipefail and pipe or last
    end
    if st.negate then sh.status = (sh.status == 0) and 1 or 0 end
  elseif t == "forin" then
    -- expand the word list ONCE (bash semantics) and stash it in sh.forstate so
    -- a mid-loop OSR resumes the same list + index.
    local list = {}
    -- a failglob no-match while expanding the word list fails the `for` non-fatally
    -- (status 1, no iterations), like bash — not an abort.
    local eok, eerr = pcall(function()
      for _, w in ipairs(st.words) do
        local fs = expand_to_fields(sh, w)
        for k = 1, #fs do list[#list + 1] = fs[k] end
      end
    end)
    if not eok then
      if type(eerr) == "table" and eerr.__curse_experr then
        sh.status = 1; if sh.opt_e then error({ __curse_exit = 1 }) end; return
      end
      error(eerr)
    end
    sh.forstate[st.id] = { list = list, idx = 0 }
    local bodystatus = 0
    sh.loopdepth = (sh.loopdepth or 0) + 1
    while true do
      hook("loop", st.id)
      local fs = sh.forstate[st.id]
      fs.idx = fs.idx + 1
      if fs.idx > #fs.list then break end
      run_debug(sh, st.line) -- DEBUG fires at the `for` header before each iteration
      sh:set_str(st.name, fs.list[fs.idx])
      local act = run_loop_body(sh, st.body, hook); bodystatus = sh.status
      if act == "break" then break end
    end
    sh.loopdepth = sh.loopdepth - 1
    sh.status = bodystatus
  elseif t == "if" then
    local ran = false
    for _, cl in ipairs(st.clauses) do
      local take
      if cl.cond == nil then take = true
      else
        sh.noerr = sh.noerr + 1; exec_list(sh, cl.cond, hook, false); sh.noerr = sh.noerr - 1
        take = (sh.status == 0)
      end
      if take then exec_list(sh, cl.body, hook, false); ran = true; break end
    end
    if not ran then sh.status = 0 end -- no branch taken (no else) -> status 0, like bash
  else
    error("interp: bad stmt " .. tostring(t))
  end
end

M.exec_stmt = exec_stmt -- exposed so the compiled CFG can delegate cold statements

-- Run a trap handler string; preserves $LINENO (so an ERR/EXIT trap sees the
-- failing command's line, not the handler's). Returns true if it called exit.
run_trap = function(sh, code)
  local exited, savedline = false, sh.cur_line
  sh.in_trap = (sh.in_trap or 0) + 1
  local ok, err = pcall(function()
    for _, st in ipairs(P.parse(code).stmts) do exec_stmt(sh, st, function() end) end
  end)
  sh.in_trap = sh.in_trap - 1; sh.cur_line = savedline
  if not ok then
    if type(err) == "table" and err.__curse_parseerr then -- syntax error in the trap code: warned, non-fatal, doesn't exit or change status (bash)
    elseif type(err) == "table" and err.__curse_exit then sh.status = err.__curse_exit; exited = true
    elseif type(err) == "table" and err.__curse_return then sh.status = err.__curse_return -- `return N` in a trap sets its status
    else error(err) end -- a real error propagates
  end
  return exited
end

-- A statement that just failed and is subject to ERR/errexit: a bare
-- simple/pipeline/(( ))/assignment outside a condition (`noerr`), a `!`-negated
-- pipeline being exempt like a condition. (&&/|| lists have their own final-
-- operand rule and call fire_err directly.)
local function errexit_stmt(sh, st)
  return sh.noerr == 0 and sh.status ~= 0 and not st.negate
    and (st.t == "simple" or st.t == "pipeline" or st.t == "arithcmd"
      or st.t == "assign" or st.t == "assignlist"
      or st.t == "subshell" or st.t == "dbracket") -- a failing ( ) / [[ ]] also fires
end
-- Run the ERR trap (once, in scope: the main shell unless errtrace extends it to
-- functions/subprograms) preserving $?, then exit if errexit is on. Shared by
-- exec_list, run_lazy and the &&/|| handler (which previously drifted apart).
fire_err = function(sh)
  local h = sh.traps and sh.traps.ERR
  local errscope = sh.opt_errtrace or ((sh.calldepth or 0) == 0 and (sh.in_subprogram or 0) == 0)
  if h and h ~= "" and not sh.in_err_trap and errscope then
    sh.in_err_trap = true; local saved = sh.status
    run_trap(sh, h); sh.status = saved; sh.in_err_trap = false
  end
  if sh.opt_e then error({ __curse_exit = sh.status }) end
end

-- Run any trapped real signals that arrived (blocked → pending) since the last
-- check, in the current scope. Cheap no-op when no signal traps are set.
local function run_pending_signals(sh)
  if not sh.sigtraps or (sh.in_trap and sh.in_trap > 0) then return end
  C.sigemptyset(sigset_poll)
  local any = false
  for canon in pairs(sh.sigtraps) do
    local num = SIGNUM[canon:match("^SIG(.+)$") or ""]
    if num then C.sigaddset(sigset_poll, num); any = true end
  end
  if not any then return end
  while true do
    local sig = C.sigtimedwait(sigset_poll, nil, zero_ts)
    if sig < 0 then break end -- no more pending
    local h = sh.traps and sh.traps["SIG" .. (NUMSIG[sig] or "")]
    if h and h ~= "" then local saved = sh.status; run_trap(sh, h); sh.status = saved end
  end
end
M.run_pending_signals = run_pending_signals

exec_list = function(sh, stmts, hook, toplevel)
  for k = 1, #stmts do
    local st = stmts[k]
    if toplevel then hook("stmt", k) end
    exec_stmt(sh, st, hook)
    if errexit_stmt(sh, st) then fire_err(sh) end
    if sh.sigtraps then run_pending_signals(sh) end -- deliver any pending signal traps
  end
end
M.exec_list = exec_list

-- Run a trap handler string; returns true if it called exit (which wins).
local function finish(sh, ok, err)
  if not ok then
    if type(err) == "table" and err.__curse_exit then sh.status = err.__curse_exit
    elseif type(err) == "table" and err.__curse_return then sh.status = err.__curse_return
    else error(err) end
  end
  -- EXIT trap: runs once with $? = the final status; its own status is ignored
  -- unless it calls exit (bash semantics).
  local h = sh.traps and sh.traps.EXIT
  if h and h ~= "" and not sh.in_exit_trap then
    sh.in_exit_trap = true
    local saved = sh.status
    if not run_trap(sh, h) then sh.status = saved end
  end
end

-- Run a whole (already-parsed) program. `hook` defaults to a no-op. A top-level
-- `exit N` unwinds to here and sets $? (like bash ending the script).
function M.run(sh, ast, hook)
  hook = hook or function() end
  finish(sh, pcall(exec_list, sh, ast.stmts, hook, true))
end

-- Top-level exit/return/EXIT-trap handling for a compiled run: wrap the compiled
-- module's run() so `exit`, nounset, errexit etc. thrown from compiled/delegated
-- code unwind cleanly (setting $?) instead of crashing as an uncaught table.
function M.finish_run(sh, fn) finish(sh, pcall(fn)) end

-- Run LAZILY from source: parse one top-level statement, execute it, repeat.
-- Instant start on large scripts (no full parse up front), and it never
-- tokenizes past an `exit` — so a hybrid shell+binary installer just works with
-- no special-casing. `hook("stmt", k)` fires per top-level statement (same k as
-- the eager AST, so tier OSR-by-stmt still lines up).
function M.run_lazy(sh, src, hook)
  hook = hook or function() end
  local nextf = P.open(src)
  finish(sh, pcall(function()
    local k = 0
    while true do
      local st = nextf()
      if st == nil then break end
      k = k + 1
      hook("stmt", k)
      exec_stmt(sh, st, hook)
      if errexit_stmt(sh, st) then fire_err(sh) end
      if sh.sigtraps then run_pending_signals(sh) end -- deliver any pending signal traps
    end
  end))
end

return M
