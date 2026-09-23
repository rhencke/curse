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
-- Shell `set` option machinery lives in runtime now (option state is runtime data);
-- import it back so interp and the set/shopt builtins (via _int) keep using these names.
local SETOPTS, SETOPT, SETFLAG, SETDEFAULT, opt_on = rt.SETOPTS, rt.SETOPT, rt.SETFLAG, rt.SETDEFAULT, rt.opt_on
local function set_opt(sh, field, on)
	sh[field] = on
	-- emacs and vi line-editing modes are mutually exclusive.
	if on and field == "opt_emacs" then
		sh.opt_vi = false
	elseif on and field == "opt_vi" then
		sh.opt_emacs = false
	end
	-- if $SHELLOPTS is exported, keep the process env in sync so children inherit
	-- the current option set (bash's cross-process `set -x` etc.).
	if sh.shellopts_exported then
		ffi.C.setenv("SHELLOPTS", sh:shellopts(), 1)
	end
end

-- bash `shopt` options in bash's own listing order, with their default state.
-- Curse doesn't implement most behaviors, but validity + default + on/off display
-- must match bash. sh.shopt[name] overrides the default once set/unset.
local SHOPT_ORDER = {
	"autocd",
	"assoc_expand_once",
	"cdable_vars",
	"cdspell",
	"checkhash",
	"checkjobs",
	"checkwinsize",
	"cmdhist",
	"compat31",
	"compat32",
	"compat40",
	"compat41",
	"compat42",
	"compat43",
	"compat44",
	"complete_fullquote",
	"direxpand",
	"dirspell",
	"dotglob",
	"execfail",
	"expand_aliases",
	"extdebug",
	"extglob",
	"extquote",
	"failglob",
	"force_fignore",
	"globasciiranges",
	"globskipdots",
	"globstar",
	"gnu_errfmt",
	"histappend",
	"histreedit",
	"histverify",
	"hostcomplete",
	"huponexit",
	"inherit_errexit",
	"interactive_comments",
	"lastpipe",
	"lithist",
	"localvar_inherit",
	"localvar_unset",
	"login_shell",
	"mailwarn",
	"no_empty_cmd_completion",
	"nocaseglob",
	"nocasematch",
	"noexpand_translation",
	"nullglob",
	"patsub_replacement",
	"progcomp",
	"progcomp_alias",
	"promptvars",
	"restricted_shell",
	"shift_verbose",
	"sourcepath",
	"varredir_close",
	"xpg_echo",
}
local SHOPT_DEFAULT = {} -- name -> true (valid); default-on ones map to "on"
for _, n in ipairs(SHOPT_ORDER) do
	SHOPT_DEFAULT[n] = false
end
for _, n in ipairs({
	"checkwinsize",
	"cmdhist",
	"complete_fullquote",
	"extquote",
	"force_fignore",
	"globasciiranges",
	"globskipdots",
	"hostcomplete",
	"interactive_comments",
	"patsub_replacement",
	"progcomp",
	"promptvars",
	"sourcepath",
}) do
	SHOPT_DEFAULT[n] = true
end
local function shopt_on(sh, name)
	local v = sh.shopt[name]
	if v == nil then
		return SHOPT_DEFAULT[name]
	end
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
		else
			on = opt_on(self, field)
		end
		if on then
			names[#names + 1] = o[1]
		end
	end
	table.sort(names)
	return table.concat(names, ":")
end
function rt.Shell:bashopts()
	local names = {}
	for _, n in ipairs(SHOPT_ORDER) do
		if shopt_on(self, n) then
			names[#names + 1] = n
		end
	end
	table.sort(names)
	return table.concat(names, ":")
end

-- Quote a value the way `set`/`declare -p` do: bare if it's all "safe" chars,
-- else single-quoted with embedded quotes escaped as '\''.
local function sq(s)
	if s == "" then
		return "''"
	end
	if s == "'" then
		return "\\'" -- bash's sh_single_quote special case
	end
	-- bash's sh_contains_shell_metas: blanks, quotes, and the metacharacters anywhere; `~`
	-- only at the start or after `=`/`:`; `#` only at the start. Otherwise the value is bare.
	local metas = s:find("[ \t\n'\"\\|&;()<>!{}*%[%]?^$`]") or s:sub(1, 1) == "#" or s:sub(1, 1) == "~"
		or s:find("[=:]~")
	if not metas and not s:find("[%c\128-\255]") then
		return s
	end
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
	for c in ifs:gmatch(".") do
		ifsset[c] = true
		if c == " " or c == "\t" or c == "\n" then
			wsset[c] = true
		end
	end
	local cells, p, m = {}, 1, #line
	while p <= m do
		local c = line:sub(p, p)
		if c == "\1" and p < m then
			cells[#cells + 1] = { ch = line:sub(p + 1, p + 1), esc = true }
			p = p + 2
		else
			cells[#cells + 1] = { ch = c, esc = false }
			p = p + 1
		end
	end
	local n = #cells
	local function isws(k)
		local c = cells[k]
		return c and not c.esc and wsset[c.ch]
	end
	local function isifs(k)
		local c = cells[k]
		return c and not c.esc and ifsset[c.ch]
	end
	local function slice(a, b)
		local t = {}
		for k = a, b do
			t[#t + 1] = cells[k].ch
		end
		return table.concat(t)
	end
	local i = 1
	while i <= n and isws(i) do
		i = i + 1
	end -- leading IFS whitespace
	local out = {}
	for v = 1, nvars do
		if v == nvars then
			-- bash (read.def): extract one field from the remainder (consuming it plus its
			-- single trailing delimiter). If NOTHING remains after that, the value is just
			-- that field (its trailing delimiter stripped — so `IFS=x; read a b <<< axbx`
			-- gives b="b", and `xx` gives b=""). Otherwise the value is the raw remainder
			-- with only trailing IFS WHITESPACE stripped (interior/trailing non-ws kept).
			local s, j = i, i
			while j <= n and not isifs(j) do
				j = j + 1
			end -- field = s..j-1
			local fieldend = j - 1
			while j <= n and isws(j) do
				j = j + 1
			end -- delimiter: IFS whitespace
			if j <= n and isifs(j) then
				j = j + 1
				while j <= n and isws(j) do
					j = j + 1
				end
			end -- + one non-ws
			if j > n then
				out[v] = slice(s, fieldend) -- single field, delimiter stripped
			else
				-- bash's strip_trailing_ifs_whitespace (subst.c) runs on the RAW remainder,
				-- CTLESC (\1) markers and all: scan back while the byte is IFS whitespace, OR
				-- it's a \1 whose FOLLOWING byte is space/tab/nl — never removing the first
				-- byte. That strips a \1's escaped space while orphaning the bare \1, so a lone
				-- \001 leaks into the value (read.def bug; builtin-read "read bash bug"). Mirror
				-- it byte-for-byte by re-encoding cells[s..n] and dequoting only afterward.
				local raw = {}
				for k = s, n do
					raw[#raw + 1] = cells[k].esc and ("\1" .. cells[k].ch) or cells[k].ch
				end
				raw = table.concat(raw)
				local S = #raw
				local function sptn(c)
					return c == " " or c == "\t" or c == "\n"
				end
				while S > 1 and (wsset[raw:sub(S, S)] or (raw:sub(S, S) == "\1" and sptn(raw:sub(S + 1, S + 1)))) do
					S = S - 1
				end
				raw = raw:sub(1, S)
				local o, k2 = {}, 1 -- dequote: \1 escapes the next byte; a trailing lone \1 stays
				while k2 <= #raw do
					if raw:sub(k2, k2) == "\1" and k2 < #raw then
						o[#o + 1] = raw:sub(k2 + 1, k2 + 1)
						k2 = k2 + 2
					else
						o[#o + 1] = raw:sub(k2, k2)
						k2 = k2 + 1
					end
				end
				out[v] = table.concat(o)
			end
		else
			local s = i
			while i <= n and not isifs(i) do
				i = i + 1
			end
			out[v] = slice(s, i - 1)
			while i <= n and isws(i) do
				i = i + 1
			end -- delimiter: IFS whitespace
			if i <= n and isifs(i) then
				i = i + 1
				while i <= n and isws(i) do
					i = i + 1
				end
			end -- + one non-ws
		end
	end
	return out
end
-- `set` (no args) one-line rendering of a variable box.
local function fmt_set_var(name, b)
	if b.assoc and b.arr then
		local keys = {}
		for k in pairs(b.arr) do
			keys[#keys + 1] = k
		end
		table.sort(keys)
		local parts = {}
		for _, k in ipairs(keys) do
			local kq = tostring(k):match("^[%w_]+$") and tostring(k) or ('"' .. tostring(k):gsub('"', '\\"') .. '"')
			parts[#parts + 1] = ('[%s]="%s"'):format(kq, tostring(b.arr[k]):gsub('"', '\\"'))
		end
		return ("%s=(%s )"):format(name, table.concat(parts, " ")) -- trailing space, like bash
	elseif b.arr then
		local idx = {}
		for k in pairs(b.arr) do
			idx[#idx + 1] = k
		end
		table.sort(idx, function(x, y)
			return tonumber(x) < tonumber(y)
		end)
		local parts = {}
		for _, i in ipairs(idx) do
			parts[#parts + 1] = ('[%s]="%s"'):format(rt.i64_to_str(rt.key_i64(i)), tostring(b.arr[i]):gsub('"', '\\"'))
		end
		return ("%s=(%s)"):format(name, table.concat(parts, " "))
	else
		local v = b.s ~= nil and b.s or (b.n ~= nil and rt.i64_to_str(b.n) or "")
		return name .. "=" .. (v == "" and "" or sq(v)) -- `set` shows an empty value bare (bash)
	end
end

local function truth(n)
	return n ~= i64(0)
end
local function b2i(b)
	return b and 1LL or 0LL
end
-- ${…} operators whose default/alternate word is expanded lazily (only when used).
local TESTOP = { ["-"] = 1, [":-"] = 1, ["+"] = 1, [":+"] = 1, ["="] = 1, [":="] = 1, ["?"] = 1, [":?"] = 1 }

-- ---- `test` / `[` builtin ----
ffi.cdef([[
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
  int clearenv(void);
  unsigned int umask(unsigned int mask);
  long read(int fd, void *buf, unsigned long count);
  unsigned long confstr(int name, char *buf, unsigned long len);
  long long strtoll(const char *nptr, char **endptr, int base);
  unsigned long long strtoull(const char *nptr, char **endptr, int base);
  struct curse_passwd { char *pw_name; char *pw_passwd; unsigned int pw_uid; unsigned int pw_gid; char *pw_gecos; char *pw_dir; char *pw_shell; };
  struct curse_passwd *getpwnam(const char *name);
  int sigemptyset(void *set);
  int sigprocmask(int how, const void *set, void *oldset);
  /* curse async signal handling (lib_cursesig.c): a real handler installed without
   * SA_RESTART (blocking syscalls EINTR) that schedules a VM hook to run the trap. */
  int curse_sig_catch(int signum);
  int curse_sig_default(int signum);
  int curse_sig_ignore(int signum);
  void curse_sig_clearpending(void);
  void curse_sig_hold(int hold);
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
]])
local C = ffi.C

-- GNU readline via FFI for the `bind` builtin's introspection subcommands. bash
-- links the SAME library, so calling readline's own dumpers gives byte-identical
-- output with no terminal — the non-interactive half of `bind` (spec/stateful has
-- the rest). Lazy-loaded; nil if libreadline is absent (bind then degrades).
ffi.cdef([[
  int rl_initialize(void);
  const char **rl_funmap_names(void);
  void rl_variable_dumper(int);
  void rl_function_dumper(int);
  void rl_macro_dumper(int);
  typedef int curse_rl_cmd(int, int);
  curse_rl_cmd *rl_named_function(const char *);
  char **rl_invoking_keyseqs(curse_rl_cmd *);
  int rl_parse_and_bind(char *);
  int rl_bind_keyseq(const char *, curse_rl_cmd *);
  extern void *rl_outstream;
  void *fopen(const char *, const char *);
  int fclose(void *);
]])
local RL, rl_ready
local function rl_lib()
	if rl_ready ~= nil then
		return RL
	end
	rl_ready = false
	for _, nm in ipairs({ "readline", "libreadline.so.8", "libreadline.so.7", "libreadline.so" }) do
		local ok, lib = pcall(ffi.load, nm)
		if ok then
			RL = lib
			break
		end
	end
	if RL then
		pcall(RL.rl_initialize)
		rl_ready = true
	end
	return RL
end
-- Run a readline dumper with its output stream pointed at a temp file, and return
-- the lines it wrote (nil if readline is unavailable). Restores rl_outstream.
local function rl_capture(dumpfn)
	local rl = rl_lib()
	if not rl then
		return nil
	end
	local tmp = os.tmpname()
	local f = C.fopen(tmp, "w")
	if f == nil then
		os.remove(tmp)
		return nil
	end
	local save = rl.rl_outstream
	rl.rl_outstream = f
	pcall(dumpfn, rl)
	rl.rl_outstream = save
	C.fclose(f)
	local out = {}
	for line in io.lines(tmp) do
		out[#out + 1] = line
	end
	os.remove(tmp)
	return out
end

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
	rt.co_block(fd, 1) -- inside a pipeline stage: yield, don't stall the siblings
	local n = C.read(fd, rd1, 1)
	if n == 1 then
		return string.char(rd1[0] % 256)
	end
	return nil -- EOF or error
end
-- `read -t 0`: is a read on `fd` ready (data available OR EOF), so it wouldn't
-- block? poll with a 0 timeout (POLLIN=1); >0 means ready (POLLIN or POLLHUP).
local pollfd1 = ffi.new("struct curse_pollfd[1]")
local function fd_ready(fd)
	pollfd1[0].fd = fd
	pollfd1[0].events = 1
	pollfd1[0].revents = 0
	return C.poll(pollfd1, 1, 0) > 0
end
local statbuf = ffi.new("uint8_t[144]") -- glibc x86-64 struct stat is 144 bytes
-- Signal name/number normalization for `trap`.
local SIGNUM = {
	HUP = 1,
	INT = 2,
	QUIT = 3,
	ILL = 4,
	TRAP = 5,
	ABRT = 6,
	BUS = 7,
	FPE = 8,
	KILL = 9,
	USR1 = 10,
	SEGV = 11,
	USR2 = 12,
	PIPE = 13,
	ALRM = 14,
	TERM = 15,
	STKFLT = 16,
	CHLD = 17,
	CONT = 18,
	STOP = 19,
	TSTP = 20,
	TTIN = 21,
	TTOU = 22,
	URG = 23,
	XCPU = 24,
	XFSZ = 25,
	VTALRM = 26,
	PROF = 27,
	WINCH = 28,
	IO = 29,
	PWR = 30,
	SYS = 31,
}
local NUMSIG = {}
for k, v in pairs(SIGNUM) do
	NUMSIG[v] = k
end
-- Real-signal traps: install curse's async C handler (lib_cursesig.c), WITHOUT
-- SA_RESTART. It records the signal and schedules a VM hook (the only async-safe
-- work) that runs the trap directly at the next safepoint — so a blocking syscall
-- (read/waitpid/…) returns EINTR and the trap fires immediately (preemption), with
-- no polling and no pending queue. `block_sig(num, true)` installs the handler;
-- `block_sig(num, false)` restores the default disposition. (Was sigprocmask-block +
-- a sigtimedwait poll at every safepoint, which couldn't interrupt a blocked read.)
local function block_sig(signum, on)
	if on then
		C.curse_sig_catch(signum)
	else
		C.curse_sig_default(signum)
	end
end
-- Human-readable signal descriptions bash prints when a job is killed (`wait`).
local SIGDESC = {
	[1] = "Hangup",
	[2] = "Interrupt",
	[3] = "Quit",
	[4] = "Illegal instruction",
	[5] = "Trace/breakpoint trap",
	[6] = "Aborted",
	[7] = "Bus error",
	[8] = "Floating point exception",
	[9] = "Killed",
	[11] = "Segmentation fault",
	[13] = "Broken pipe",
	[14] = "Alarm clock",
	[15] = "Terminated",
}
local function canon_sig(s)
	s = s:upper()
	if s == "0" or s == "EXIT" then
		return "EXIT"
	end
	if s == "ERR" or s == "DEBUG" or s == "RETURN" then
		return s
	end
	s = s:gsub("^SIG", "")
	if s:match("^%d+$") then
		local nm = NUMSIG[tonumber(s)]
		return nm and ("SIG" .. nm) or nil
	end
	return SIGNUM[s] and ("SIG" .. s) or nil
end
local function sig_order(canon) -- for printing: EXIT=0, then by signal number
	if canon == "EXIT" then
		return 0
	end
	local nm = canon:gsub("^SIG", "")
	return SIGNUM[nm] or 99
end
-- A forked subshell (background `&`, `( )`, a pipeline stage, `>(…)`) resets
-- CAUGHT signal traps to their default DISPOSITION, like bash — the handler no
-- longer fires when the signal arrives (e.g. `kill -URG $!` after `trap … URG`).
-- bash's reset is deferred, though: `trap`/`trap -p` in the subshell still
-- DISPLAYS the inherited handler strings, so keep sh.traps[canon] and only drop
-- the entry from sh.sigtraps (which drives firing) and unblock the signal. A
-- signal set to be ignored (`trap '' SIG`) keeps both its ignore disposition and
-- its display.
local function reset_child_sigtraps(sh)
	if not sh.sigtraps then
		return
	end
	local kept
	for canon in pairs(sh.sigtraps) do
		if sh.traps[canon] == "" then -- ignored: keep ignore disposition and display
			kept = kept or {}
			kept[canon] = true
		else -- caught: revert to default disposition, but keep the string for `trap -p`
			local num = SIGNUM[canon:match("^SIG(.+)$") or ""]
			if num then
				block_sig(num, false)
			end -- restore default so the default action applies
		end
	end
	sh.sigtraps = kept
	-- Handlers are now default; discard any trap the child caught in the fork→reset
	-- window (e.g. `cmd & ; kill -SIG $!`) so it doesn't fire a spurious trap.
	C.curse_sig_clearpending()
end

-- file predicates + mtime/inode compares moved to runtime (pure stat FFI; shared with
-- the compiled tier and the builtins, which import them via _int -> rt). statbuf stays;
-- it is still used by the O_EXCL redirect check below.
local file_test = rt.file_test
local statbuf2 = ffi.new("uint8_t[144]")
local file_bincmp = rt.file_bincmp
local UNARY_STR = { ["-z"] = true, ["-n"] = true }
-- `test -v NAME` / `[[ -v NAME ]]`: is the variable (or array element) set?
local array_key -- forward (defined below)
-- The test/[ engine + var_is_set moved to runtime (its operand primitives are all
-- runtime funcs). Import the pieces interp's [[ ]] eval and the test/[ builtin call.
local var_is_set, unary, binary, do_test = rt.var_is_set, rt.test_unary, rt.test_binary, rt.do_test
M.do_test = do_test

local tilde_prefix -- forward (word-initial ~ expansion; defined below, used in paramexp)
local expand_word -- forward (used by eval's $-deferred arith and expand_part_str)
local expand_assign_word -- forward (assignment-RHS expander; ${-default} tilde ctx)
local expand_pattern -- forward (quote-aware glob-pattern expansion for ${v/…} etc.)
local indirect_part -- forward (${!ref} target resolution, re-parsed to a part)
local eval -- arithmetic evaluator (forward decl)
local arith_resolve -- var-value-as-arith-expression resolver (forward decl)
local arith_key -- array subscript in arith: string key for assoc, number for indexed
local arith_int -- forward: arith-eval a slice offset/length string
local run_trap -- trap-handler runner (forward decl; defined near the bottom)
local fire_err -- ERR-trap + errexit enforcement (forward decl; defined near exec_list)
local fire_err_trap -- the ERR-trap half of fire_err WITHOUT errexit-exit (used inside handlers)
local sherr -- error-message writer, capture-aware for `2>&1` in $() (defined w/ redirs)
-- Resolve a variable's string value in arithmetic. bash treats it as an arith
-- EXPRESSION: a bare number is its value, but a name (or `3+4`, `bar`) is
-- recursively parsed and evaluated (so bar=foo; foo=5; $((bar)) == 5). A pure
-- integer literal short-circuits (the hot path); a recursion guard bounds cycles.
local looks_numeric = rt.looks_numeric -- shared with the compiled tier (one source in runtime)
arith_resolve = function(sh, s)
	if s == nil or s:match("^%s*$") then
		return i64(0)
	end -- unset/blank value -> 0 (bash)
	if looks_numeric(s) then
		return rt.arith_num(s)
	end
	sh.arith_depth = (sh.arith_depth or 0) + 1
	if sh.arith_depth > 40 then
		sh.arith_depth = sh.arith_depth - 1
		return i64(0)
	end -- cycle guard
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
		if type(v) == "table" and (v.__curse_experr or v.__curse_matherr) then
			error(v)
		end
		return i64(0)
	end
	return v ~= nil and v or i64(0)
end

-- Division/modulo by zero is a fatal arithmetic error (bash aborts the current
-- command with status 1 and a diagnostic). Tagged __curse_matherr so a caller
-- that runs code in a protected context (compgen -F) can recover from it.
local function arith_div0()
	io.stderr:write("curse: division by 0\n")
	error({ __curse_exit = 1, __curse_matherr = true, __curse_lineabort = true })
end

-- Reading an unset variable in arithmetic under `set -u` is a fatal unbound-
-- variable error (bash), just like `$var`. Applies to plain reads and to the
-- read side of `+=`/`++`/`--`, but NOT to a pure `=` assignment (which defines).
local function arith_nounset(sh, name)
	if sh.opt_u and sh.vars[sh:deref(name)] == nil and sh:special_get(name) == "" then
		io.stderr:write("curse: " .. name .. ": unbound variable\n")
		error({ __curse_exit = sh.opt_c and 127 or 1, __curse_lineabort = sh.opt_i or nil })
	end
end

eval = function(sh, e)
	local k = e.k
	if k == "matherr" then -- a deferred arith parse error (bad lvalue): non-fatal in (( ))
		io.stderr:write("curse: arithmetic syntax error\n")
		error({ __curse_exit = 1, __curse_matherr = true })
	end
	if k == "num" then
		return rt.arith_num(e.v)
	end
	if k == "var" then
		if e.idxraw then
			arith_nounset(sh, e.name)
			return arith_resolve(sh, sh:array_get(e.name, arith_key(sh, e.name, e.idx, e.idxraw)))
		end
		arith_nounset(sh, e.name)
		-- Numeric-authoritative fast path: a scalar set via aset holds its i64 in b.n
		-- with b.s cleared. Reading it back through sh:get would stringify (i64_to_str)
		-- then arith_resolve would re-parse (arith_num) — a full round-trip per read in
		-- an arithmetic loop. Return b.n directly. Safe: b.n is only ever a non-integer
		-- (aget caching arith_num of a recursive expression) while b.s is still set, so
		-- the b.s==nil guard excludes that case and falls through to arith_resolve.
		local b = sh.vars[sh:deref(e.name)]
		if b and b.n ~= nil and b.s == nil and not b.arr then
			return b.n
		end
		local v = sh:get(e.name)
		-- `$name` (dollar): bash substitutes the value's TEXT into the arithmetic and
		-- re-parses, so a value with a binary operator re-associates with the surrounding
		-- ops (`x='1 + 2'; $(( $x * 3 ))` is `1 + 2 * 3` = 7, not (eval x)*3 = 9). A plain
		-- NUMBER binds like an atom (native == textual — the common hot-loop `$i`), so only a
		-- non-numeric $name value needs the textual path, signalled up to the xpand wrapper.
		if e.dollar and not looks_numeric(v) then
			error({ __arith_textual = true })
		end
		return arith_resolve(sh, v)
	end
	if k == "param" then
		return rt.str_to_i64(sh:param(e.n))
	end
	if k == "xpand" then -- deferred: expansions inside $(( )) resolved at runtime
		-- Fast path when the raw only uses $name/${…}/$digit (no $(…)/`…`/$*/glued name):
		-- parse it ONCE as a native tree and eval that, so a hot `(( $i < n ))` doesn't
		-- expand-and-reparse per iteration. Fall back to bash's textual substitution
		-- (expand the raw, re-parse the result) only when a value isn't a simple operand.
		if e.fast == nil then
			e.fast = not (
				e.raw:find("%$%(")
				or e.raw:find("`")
				or e.raw:find("%$[^%w_{]")
				or e.raw:find("[%w_]%$")
				or e.raw:find("}[%w_#]")
			)
		end
		if e.fast then
			e.native = e.native or P.arith(e.raw, true)
			local ok, r = pcall(eval, sh, e.native)
			if ok then
				return r
			end
			if not (type(r) == "table" and r.__arith_textual) then
				error(r)
			end
		end
		local text = expand_word(sh, P.parse_word(e.raw))
		local pok, ast = pcall(P.arith, text, true)
		if not pok then -- the EXPANDED text isn't valid arithmetic: an arith error (bash), not a crash
			local tok = text:match("^%s*(.-)%s*$")
			io.stderr:write("curse: " .. tok .. ": syntax error in expression\n")
			error({ __curse_exit = 1, __curse_matherr = true, __curse_lineabort = true })
		end
		return eval(sh, ast)
	end
	if k == "xpandleaf" then -- an opaque ${…} operand: expand it; a non-numeric value must
		local v = expand_word(sh, P.parse_word(e.raw)) -- take bash's textual substitution path
		if not looks_numeric(v) then
			error({ __arith_textual = true })
		end
		return arith_resolve(sh, v)
	end
	if k == "comma" then
		eval(sh, e.l)
		return eval(sh, e.r)
	end
	if k == "un" then
		local v = eval(sh, e.e)
		if e.op == "-" then
			return -v
		end
		if e.op == "!" then
			return b2i(not truth(v))
		end
		if e.op == "~" then
			return bit.bnot(v)
		end
	end
	if k == "tern" then
		if truth(eval(sh, e.c)) then
			return eval(sh, e.a)
		else
			return eval(sh, e.b)
		end
	end
	if k == "bin" then
		local op = e.op
		if op == "&&" then
			return b2i(truth(eval(sh, e.l)) and truth(eval(sh, e.r)))
		end
		if op == "||" then
			return b2i(truth(eval(sh, e.l)) or truth(eval(sh, e.r)))
		end
		local l, r = eval(sh, e.l), eval(sh, e.r)
		if op == "+" then
			return l + r
		end
		if op == "-" then
			return l - r
		end
		if op == "*" then
			return l * r
		end
		if op == "/" then
			if r == i64(0) then
				arith_div0()
			end
			return l / r
		end
		if op == "%" then
			if r == i64(0) then
				arith_div0()
			end
			return l % r
		end
		if op == "==" then
			return b2i(l == r)
		end
		if op == "!=" then
			return b2i(l ~= r)
		end
		if op == "<" then
			return b2i(l < r)
		end
		if op == "<=" then
			return b2i(l <= r)
		end
		if op == ">" then
			return b2i(l > r)
		end
		if op == ">=" then
			return b2i(l >= r)
		end
		if op == "&" then
			return bit.band(l, r)
		end
		if op == "|" then
			return bit.bor(l, r)
		end
		if op == "^" then
			return bit.bxor(l, r)
		end
		if op == "<<" then
			return bit.lshift(l, tonumber(r) % 64)
		end
		if op == ">>" then
			return bit.arshift(l, tonumber(r) % 64)
		end
		if op == "**" then
			local base, n, res = l, tonumber(r), i64(1)
			if n < 0 then -- bash disallows a negative exponent (fatal arith error)
				io.stderr:write("curse: exponent less than 0\n")
				error({ __curse_exit = 1, __curse_matherr = true })
			end
			for _ = 1, n do
				res = res * base
			end
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
			if o == "+" then
				v = cur + v
			elseif o == "-" then
				v = cur - v
			elseif o == "*" then
				v = cur * v
			elseif o == "/" then
				if v == i64(0) then
					arith_div0()
				end
				v = cur / v
			elseif o == "%" then
				if v == i64(0) then
					arith_div0()
				end
				v = cur % v
			elseif o == "&" then
				v = bit.band(cur, v)
			elseif o == "|" then
				v = bit.bor(cur, v)
			elseif o == "^" then
				v = bit.bxor(cur, v)
			elseif o == "<<" then
				v = bit.lshift(cur, tonumber(v) % 64)
			elseif o == ">>" then
				v = bit.arshift(cur, tonumber(v) % 64)
			end
		end
		if iv then
			sh:array_set(e.name, iv, rt.i64_to_str(v))
			return v
		end
		return sh:aset(e.name, v)
	end
	if k == "post" then
		arith_nounset(sh, e.name) -- x++ / x-- read x first
		if e.idxraw then
			local iv = arith_key(sh, e.name, e.idx, e.idxraw)
			local cur = rt.arith_num(sh:array_get(e.name, iv))
			sh:array_set(e.name, iv, rt.i64_to_str(cur + i64(e.d)))
			return cur
		end
		local cur = sh:aget(e.name)
		sh:aset(e.name, cur + i64(e.d))
		return cur
	end
	if k == "pre" then
		arith_nounset(sh, e.name) -- ++x / --x read x first
		if e.idxraw then
			local iv = arith_key(sh, e.name, e.idx, e.idxraw)
			local v = rt.arith_num(sh:array_get(e.name, iv)) + i64(e.d)
			sh:array_set(e.name, iv, rt.i64_to_str(v))
			return v
		end
		local v = sh:aget(e.name) + i64(e.d)
		return sh:aset(e.name, v)
	end
	error("interp: bad arith node " .. tostring(k))
end
M.eval = eval

-- Read a variable in ARITHMETIC context, exactly as the interpreter's `var` node
-- does: enforce nounset, then resolve the value AS AN ARITH EXPRESSION (a bare
-- number is itself; a name or "3+4" is recursively parsed+evaluated; an array
-- decays to [0]). The compiled tiers call this for every non-lifted arith read so
-- compiled == interp on recursive-name-eval / array decay / set -u. It may raise a
-- non-fatal matherr (bad expression) — the (( )) codegen catches it as status 1.
function M.arith_read(sh, name)
	arith_nounset(sh, name) -- set -u: unbound in arith is FATAL (throws, aborts — bash)
	local s = sh:get(name)
	if s == nil or s:match("^%s*$") then
		return i64(0)
	end
	if looks_numeric(s) then
		return rt.arith_num(s)
	end -- hot path: plain number, no parse/pcall
	if sh.arithfault and sh.in_arithcmd then
		return i64(0)
	end -- a prior read in THIS (( )) faulted
	-- a name/expression value ("bar", "1 3"): recursively parse+eval. A malformed value
	-- ("a[<(..)]") is a matherr. Inside a (( )) command (sh.in_arithcmd) it's NON-fatal —
	-- record it as a flag (the arithcmd codegen maps the flag to $?=1), so the common case
	-- needs no per-iter pcall. In a WORD/assignment `$((…))` bash instead ABORTS the rest
	-- of the line (like a div0), so raise a lineabort the tier catches ($?=1, line skipped).
	local ok, v = pcall(arith_resolve, sh, s)
	if ok then
		return v
	end
	if type(v) == "table" and (v.__curse_matherr or v.__curse_experr) then
		if sh.in_arithcmd then
			sh.arithfault = true
			return i64(0)
		end
		error({ __curse_lineabort = true })
	end
	error(v)
end

-- Compiled-tier helpers for `$name` arithmetic (the emit fast-xpand path):
-- arith_isnum gates the native compiled expression — true when the var's value binds
-- like an atom (a plain number, so native == bash's textual substitution). arith_textual
-- is the fallback for a non-numeric value: expand the raw arithmetic and re-parse it,
-- exactly as bash substitutes the value's TEXT (`x='1 + 2'; $(( $x*3 ))` -> 1 + 2 * 3).
function M.arith_isnum(sh, name)
	local s = sh.vars[sh:deref(name)]
	if s and s.n ~= nil and s.s == nil and not s.arr then
		return true
	end -- i64-authoritative
	return looks_numeric(sh:get(name)) ~= nil
end
function M.arith_textual(sh, raw)
	return eval(sh, P.arith(expand_word(sh, P.parse_word(raw)), true))
end

-- An array subscript used in arithmetic: an associative array takes the
-- evaluated-then-stringified value as its key ("5"), an indexed array a number.
arith_key = function(sh, name, idxexpr, idxraw)
	-- An associative-array subscript in (( )) is a LITERAL string key (parameter-
	-- expanded and quote-removed), NOT an arith expression: `A[K]` -> key "K",
	-- `A[$k]` -> the value of k, `A['x']` -> "x". Reuse the normal key resolver.
	if sh:is_assoc(name) then
		return array_key(sh, name, idxraw or "")
	end
	if idxexpr == nil then -- a non-arith subscript (e.g. quoted) on a NON-assoc array
		io.stderr:write("curse: " .. (idxraw or "") .. ": syntax error in expression\n")
		error({ __curse_exit = 1, __curse_matherr = true, __curse_experr = true })
	end
	return rt.to_arr_key(eval(sh, idxexpr))
end

-- Resolve an array subscript to a key: a string (word-expanded) for an
-- associative array, else an integer (arith-evaluated) for an indexed one.
array_key = function(sh, name, index_raw)
	if sh:is_assoc(name) then
		return expand_word(sh, P.parse_word(index_raw))
	end
	-- indexed: arith-evaluate the subscript. Parse the RAW subscript with arith (its
	-- defer/xpand handles $()/$vars) rather than word-expanding it first, so bash's
	-- arith quote rules apply — a double-quote PAIR strips to its content (`a["3"]`),
	-- a SINGLE quote is a syntax error (`a['3']` -> status 1, assignment skipped).
	if index_raw:match("^%s*$") then
		return 0
	end
	local ok, v = pcall(function()
		return rt.to_arr_key(eval(sh, P.arith(index_raw)))
	end)
	if not ok then
		io.stderr:write("curse: " .. index_raw .. ": syntax error in expression\n")
		-- an expansion error discards the rest of the top-level line (bash jump_to_top_level)
		error({ __curse_exit = 1, __curse_lineabort = true })
	end
	return v
end

-- Expand ONE part to its string value (a multi-element @/* part is joined here;
-- expand_to_fields treats those specially for word-splitting).
local function expand_part_str(sh, p, assign)
	if p.lit ~= nil then
		return p.lit
	elseif p.var then
		-- a nameref whose target has a subscript (`typeset -n ref='a[2]'`) reads as
		-- ${a[2]} — deref only yields the base name, so expand the target here.
		local rb = sh.vars[p.var]
		if rb and rb.ref and rb.s and rb.s:find("[", 1, true) then
			return expand_word(sh, P.parse_word("${" .. rb.s .. "}"))
		end
		local b = sh.vars[sh:deref(p.var)]
		-- `$x` reads ${x[0]}, so an array whose element 0 is unset (a bare `declare -a x`, a
		-- sparse array with no [0]) is unbound — not merely because b.arr exists.
		local unset
		if b == nil then
			unset = true
		elseif b.arr then
			unset = (b.assoc and b.arr["0"] or b.arr[0]) == nil
		else
			unset = b.s == nil and b.n == nil
		end
		if sh.opt_u and unset and sh:special_get(p.var) == "" then
			io.stderr:write("curse: " .. p.var .. ": unbound variable\n")
			error({ __curse_exit = sh.opt_c and 127 or 1, __curse_lineabort = sh.opt_i or nil })
		end
		return sh:get(p.var)
	elseif p.param then
		if sh.opt_u and p.param > sh.nparams then
			io.stderr:write("curse: " .. p.param .. ": unbound variable\n")
			error({ __curse_exit = sh.opt_c and 127 or 1, __curse_lineabort = sh.opt_i or nil })
		end
		return sh:param(p.param)
	elseif p.special then
		local v
		if p.special == "#" then
			v = tostring(sh.nparams)
		elseif p.special == "*" then -- $* joins on the first IFS char; $@ always on a space
			v = sh:paramsJoin(sh.vars["IFS"] and rt.ifs_first(sh:get("IFS")) or " ")
		elseif p.special == "@" then
			v = sh:paramsJoin(" ")
		elseif p.special == "?" then
			v = tostring(sh.status)
		elseif p.special == "$" then
			v = tostring(sh:pid())
		elseif p.special == "!" then
			v = sh.last_bg_pid or ""
		elseif p.special == "-" then
			v = sh:dash_flags()
		else
			v = ""
		end
		if p.lenof then
			return tostring(rt.mb_strlen(v))
		end -- ${##} ${#?} ${#-} ${#$} ${#!}: length
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
		-- <(cmd) / >(cmd): run cmd asynchronously on a pipe and substitute /dev/fd/N for
		-- the shell's end of it (bash: 63, then 62, …) — a real pipe, so the data is read
		-- once and a reader can start before the writer ends. The end stays open (and is
		-- inherited) until the command it was expanded for finishes (drain_procsub).
		rt.need_process(sh)
		io.flush()
		local pfd = ffi.new("int[2]")
		if C.pipe(pfd) ~= 0 then
			return "/dev/null"
		end
		local mine, theirs = pfd[p.dir == "<" and 0 or 1], pfd[p.dir == "<" and 1 or 0]
		local pid = rt.fork()
		if pid == 0 then
			C.close(mine)
			C.dup2(theirs, p.dir == "<" and 1 or 0)
			C.close(theirs)
			reset_child_sigtraps(sh) -- caught signal traps revert to default in the subshell
			sh.in_subprogram = (sh.in_subprogram or 0) + 1
			sh.out = io.write
			local ok, err = pcall(function()
				local stmts = P.parse(p.procsub).stmts
				local s1 = #stmts == 1 and stmts[1]
				if s1 and s1.t == "simple" and #(s1.words or {}) == 0 and s1.redirs and #s1.redirs == 1
					and s1.redirs[1].op == "in" and not s1.assigns then
					-- <(< file): the file's contents, like $(< file) (bash 5.2)
					local path = M.expand_assign_word(sh, P.parse_word(s1.redirs[1].target or ""))
					local f = io.open(path, "rb")
					if f then
						io.write(f:read("*a") or "")
						f:close()
						sh.status = 0
					else
						io.stderr:write("curse: " .. path .. ": No such file or directory\n")
						sh.status = 1
					end
					return
				end
				M.exec_list(sh, stmts, function() end, false)
			end)
			rt.child_status(sh, ok, err)
			rt.child_exit(sh, sh.status or 0) -- (never returns into the parent's script)
		end
		C.close(theirs)
		local fd = rt.fd_below(mine, 64)
		sh.procsub_files = sh.procsub_files or {}
		sh.procsub_files[#sh.procsub_files + 1] = { fd = fd, pid = pid }
		sh.last_bg_pid = tostring(pid) -- $! is the last process substitution (bash)
		return "/dev/fd/" .. fd
	elseif p.cmdsub then
		return sh:capture_src(p.cmdsub, p.backtick, p.noalias)
	elseif p.pexp then
		local pe = p.pexp
		if pe.op == "badsubst" then -- ${x|html} and other unrecognized ${…} forms
			sherr(sh, "curse: ${" .. (pe.raw or pe.name or "") .. "}: bad substitution\n")
			error({ __curse_exit = 1, __curse_lineabort = true }) -- discards the rest of the line (bash)
		end
		if pe.op == "@" and pe.arg == "P" then -- ${x@P}: decode prompt escapes, then expand
			return M.prompt_string(sh, sh:get_u(pe.name)) -- get_u: honor set -u
		end
		if pe.op == "indirect" then -- ${!ref} / ${!ref OP}: resolve the name, then expand it
			local ip = indirect_part(sh, pe)
			if not ip then
				return ""
			end
			ip.q = p.q
			return expand_part_str(sh, ip)
		end
		local subkey
		if pe.index and pe.index ~= "@" and pe.index ~= "*" then
			subkey = array_key(sh, pe.name, pe.index)
		end
		-- pattern-context ops (strip #/##/%/%%, subst /,//) treat quoted metachars
		-- literally; everything else (defaults :-/-, etc.) is an ordinary value.
		local patmode = pe.op == "/"
			or pe.op == "//"
			or pe.op == "#"
			or pe.op == "##"
			or pe.op == "%"
			or pe.op == "%%"
			or pe.op == "^"
			or pe.op == "^^"
			or pe.op == ","
			or pe.op == ",," -- case-fold pattern
		-- The word for -/:-/+/:+/=/:=/?/:? is only expanded WHEN USED (bash: a default
		-- with side effects like $((i++)) runs only if the branch is taken). Pass a thunk.
		-- (TESTOP is a module-level constant.)
		-- When the ${…} is inside double quotes, its default/alternate word follows
		-- double-quoted rules: single quotes are literal and a backslash is kept
		-- except before $ ` " \ (parse_heredoc has exactly these semantics). An inner
		-- double quote is syntactic (part of the outer quote), so `"${x:-"a b"}"`
		-- yields `a b` — strip the unescaped `"` before the heredoc-style parse.
		local function pw(txt)
			if not p.q then
				return P.parse_word(txt)
			end
			return P.parse_default_quoted(txt, pe.hd)
		end
		local arg
		if TESTOP[pe.op] then
			-- In an assignment RHS the default word gets the after-`:` tilde rule too
			-- (`x=${undef-~:~}` -> HOME:HOME), so use the assignment-aware expander.
			arg = pe.arg and function()
				if assign then
					return expand_assign_word(sh, pw(pe.arg))
				end
				return expand_word(sh, pw(pe.arg), true)
			end or nil
		else
			arg = pe.arg and (patmode and expand_pattern or expand_word)(sh, P.parse_word(pe.arg), true) or nil
		end
		local arg2 = pe.arg2 and expand_word(sh, P.parse_word(pe.arg2)) or nil
		if pe.op == "sub" then -- ${v:off:len}: offset/length are arithmetic expressions
			arg = arg and tostring(arith_int(sh, arg) or 0) or nil
			arg2 = arg2 and tostring(arith_int(sh, arg2) or 0) or nil
		elseif not TESTOP[pe.op] then
			-- a word-initial ~ in a pattern / replacement expands (${p//~/z}, ${p#~/x})
			if type(arg) == "string" then
				arg = tilde_prefix(sh, arg)
			end
			if arg2 then
				arg2 = tilde_prefix(sh, arg2)
			end
		end
		return sh:expand_param(pe, arg, arg2, subkey)
	end
	return ""
end

-- Expand a word to a single string (assignment RHS, case subject, arith index —
-- contexts that do NOT word-split).
-- Tilde expansion lives in runtime.lua (pure runtime: HOME/PWD/OLDPWD + passwd db).
-- interp aliases it locally; both tiers share the runtime version.
tilde_prefix = rt.tilde_prefix
M.tilde_prefix = tilde_prefix

-- Canonicalize an absolute path string LOGICALLY: resolve `.`/`..` textually,
-- without following symlinks (bash's default -L `cd` semantics — `..` pops the
-- previous name even when it is a symlink).
local function logical_canon(path)
	local parts = {}
	for seg in path:gmatch("[^/]+") do
		if seg == "." then -- drop
		elseif seg == ".." then
			if #parts > 0 then
				parts[#parts] = nil
			end
		else
			parts[#parts + 1] = seg
		end
	end
	return "/" .. table.concat(parts, "/")
end

-- Assignment-RHS and word-initial tilde expansion also live in runtime.lua; interp
-- aliases them locally so its expansion paths and M.* exports keep working.
local tilde_assign = rt.tilde_assign
local tilde_word_initial = rt.tilde_word_initial
M.tilde_word_initial = tilde_word_initial -- the compiled tier tilde-expands word-initial literals
M.tilde_assign = tilde_assign -- compiled tier tilde-expands each `:`-segment of an assignment RHS

-- Compiled-tier plain scalar assignment (`name=value`), mirroring interp's assign
-- handler for an ATTRIBUTED target: reject a readonly var ($?=1 + diagnostic, fatal
-- in -c/posix); write element [0] of an array var (bash: `a=v` on an array); arith-
-- evaluate for `declare -i`; case-fold for `declare -l/-u`; else a plain set. Only
-- emitted when the program creates such a var (else compiled uses sh:set_str).
function M.assign_scalar(sh, name, value)
	local direct = sh.vars[name]
	local b = sh.vars[sh:deref(name)]
	if b and b.ro then
		io.stderr:write("curse: " .. name .. ": readonly variable\n")
		sh.status = 1
		-- Writing THROUGH a nameref to a readonly target is NON-fatal (bash: status 1,
		-- continue). A DIRECT readonly assignment hard-exits in -c/posix, else aborts
		-- the rest of the line (like interp's assign handler).
		if direct and direct.ref then
			return
		end
		if sh.opt_c or sh.opt_posix then
			error({ __curse_exit = 1 })
		end
		error({ __curse_exit = 1, __curse_lineabort = true })
	end
	if b and b.arr then
		sh:array_set(name, array_key(sh, name, "0"), value, false)
	elseif b and b.int then
		sh:aset(name, eval(sh, P.arith(value)))
	elseif b and (b.lower or b.upper) then
		sh:set_str(name, b.lower and value:lower() or value:upper())
	else
		sh:set_str(name, value)
	end
	if sh.opt_a then -- set -a (allexport): a plain scalar assignment auto-exports (bash)
		local nb = sh.vars[sh:deref(name)]
		if nb and not nb.arr then
			nb.exported = true
			C.setenv(sh:deref(name), sh:get(name), 1)
		end
	end
end

-- `noassign`: a ${…} operand — only a word-initial ~ expands there, never the `NAME=…:~`
-- assignment form (bash: `${x:=P=~/b}` keeps its tildes)
expand_word = function(sh, w, noassign)
	local buf = {}
	for k, p in ipairs(w.parts) do
		local s = expand_part_str(sh, p)
		if k == 1 and p.lit ~= nil and not p.q then
			s = tilde_word_initial(sh, s, #w.parts > 1, noassign)
		end
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
			local more = i < #w.parts -- a prefix without `/` runs into the next part: literal
			if peel_name and i == 1 then
				local pre, rest = s:match("^([%a_][%w_]*%+?=)(.*)$")
				s = pre and (pre .. tilde_assign(sh, rest, more)) or tilde_assign(sh, s, more)
			else
				s = tilde_assign(sh, s, more, i > 1) -- (a later part continues the text before it)
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
		if p.q then
			s = s:gsub(charclass, "\\%0")
		end
		buf[#buf + 1] = s
	end
	return table.concat(buf)
end
-- glob PATTERN context (${v/pat/repl}, case, [[ == ]]): glob metacharacters.
local PAT_META = "[%*%?%[%]\\%(%)%|%+%@%!]"
expand_pattern = function(sh, w)
	-- a word-initial `~` tilde-expands (bash: `case ~ in ~)`), and the directory it
	-- yields matches literally
	local p1 = w.parts[1]
	if p1 and p1.lit and not p1.q and p1.lit:sub(1, 1) == "~" then
		local s = expand_part_str(sh, p1)
		local t = tilde_word_initial(sh, s, #w.parts > 1, true)
		if t ~= s then
			local rest = expand_escaped(sh, { parts = { unpack(w.parts, 2) } }, PAT_META)
			local tail = s:match("^~[^/]*(.*)$") or ""
			local dir = t:sub(1, #t - #tail)
			return dir:gsub(PAT_META, "\\%0") .. tail .. rest
		end
	end
	return expand_escaped(sh, w, PAT_META)
end
-- Does `subj` match any of the case-clause pattern strings? The compiled tier's case
-- codegen dispatches clauses natively but matches through this shared helper (vars in
-- a pattern expand; quoted metachars stay literal), honoring shopt nocasematch.
function M.case_match(sh, subj, pats)
	local ic = sh.shopt.nocasematch and true or nil
	for _, pat in ipairs(pats) do
		if rt.glob_match(subj, expand_pattern(sh, P.parse_word(pat)), ic) then
			return true
		end
	end
	return false
end
-- `=~` regex context: ERE metacharacters.
local function expand_regex(sh, w)
	return expand_escaped(sh, w, "[%.%^%$%*%+%?%(%)%[%]%{%}%|\\]")
end

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
		if b and b.ref and b.s and not pe.iop then
			return { lit = b.s }
		end
		if pe.name:match("^%d+$") then
			tname = sh:param(tonumber(pe.name)) -- ${!1}: positional
		else
			tname = (b and b.ref and b.s) or sh:get(pe.name)
		end
	end
	if tname == nil or tname == "" then
		-- bash 5.2: an indirect whose ref BASE VAR is UNSET (`${!undef}`, `${!a[@]OP}`
		-- with a unset) is an "invalid indirect expansion" — status 1, non-fatal (fatal
		-- under set -u, where the unset ref also trips nounset). A SET ref that merely
		-- resolves to empty (an assoc's empty scalar, `${!A@a}`) expands to empty, and a
		-- positional ref (`${!1}`) that is unset stays empty, as bash does.
		if pe.name and pe.name:match("^%d+$") then
			return nil
		end
		local bb = pe.name and sh.vars[pe.name]
		if bb and (bb.s ~= nil or bb.n ~= nil or bb.arr ~= nil) then
			return nil
		end
		io.stderr:write("curse: " .. (pe.name or "") .. ": invalid indirect expansion\n")
		if sh.opt_u then
			error({ __curse_exit = sh.opt_c and 127 or 1, __curse_lineabort = sh.opt_i or nil })
		end
		error({ __curse_exit = 1, __curse_lineabort = true })
	end
	-- ${!ref} to a special parameter: $?, $$, $!, $#, $-, $N, $@, $*
	if not pe.iop then
		if tname:match("^%d+$") then
			return { param = tonumber(tname) }
		end
		if #tname == 1 and tname:match("[%?%$!#%-@%*]") then
			return { special = tname }
		end
	end
	-- The resolved target must be a valid variable reference: an identifier,
	-- optionally with a [subscript]. Anything else (spaces, `/`, …) is invalid.
	local base = tname:match("^[%a_][%w_]*")
	if not base or (#tname > #base and tname:sub(#base + 1, #base + 1) ~= "[") then
		io.stderr:write("curse: " .. tname .. ": invalid variable name\n")
		error({ __curse_exit = 1, __curse_lineabort = true })
	end
	local ok, part = pcall(P.parse_paramexp, tname .. (pe.iop or ""))
	-- Mark the reconstructed part as coming through indirection: bash's `:-`/`:+`
	-- null test on an array reached via `${!ref:-…}` keys on the element COUNT
	-- (zero = null), unlike the DIRECT `${a[@]:-…}` which treats one empty element
	-- as null. (The `-`/`:+`-less `-` variant is already count-based for both.)
	if ok and part and part.pexp then
		part.pexp.via_indirect = true
	end
	return ok and part or nil
end
local is_multi
is_multi = function(sh, p)
	if not p.pexp then
		return p.special == "@" or p.special == "*"
	end
	if p.pexp.op == "len" then
		return false
	end
	if p.pexp.op == "prefix" then
		return true
	end -- ${!pfx@} / ${!pfx*}
	if p.pexp.op == "indirect" then
		local ip = indirect_part(sh, p.pexp)
		return ip ~= nil and is_multi(sh, ip)
	end
	-- $@/$* live in pexp.name (e.g. ${@:1}); array [@]/[*] live in pexp.index
	return p.pexp.index == "@" or p.pexp.index == "*" or p.pexp.name == "@" or p.pexp.name == "*"
end
-- arith-evaluate a slice offset/length expression (e.g. "i-4", "(-4)", "2").
arith_int = function(sh, s)
	if s == nil or s == "" then
		return nil
	end
	local ok, v = pcall(function()
		return tonumber(rt.i64_to_str(eval(sh, P.arith(s))))
	end)
	return (ok and v) or tonumber(s) or 0
end
-- ${a[@]:off:len}: select elements by (0-based, negatives-from-end) offset/length.
local function array_slice(els, off, len)
	local n = #els
	off = off or 0
	-- a negative offset counts from the end; if it reaches past the start, bash
	-- yields an EMPTY slice (not the whole array — don't clamp to 0).
	if off < 0 then
		off = n + off
		if off < 0 then
			return {}
		end
	end
	local last = n
	if len ~= nil then
		last = (len < 0) and (n + len) or (off + len)
	end
	local out = {}
	for i = off, last - 1 do
		if els[i + 1] ~= nil then
			out[#out + 1] = els[i + 1]
		end
	end
	return out
end
local function multi_elems(sh, p) -- returns element list, star?
	if p.pexp then
		local pe = p.pexp
		local star = (pe.index == "*" or pe.name == "*") -- $* / ${*:…} join when quoted
		-- Expand a default/alternate word (`:-`/`-`/`:+`/`+` arg). If it is itself a
		-- single array/$@ expansion (${d[@]}), preserve its elements as separate
		-- fields instead of flattening to one joined string.
		-- Returns the field list; for a QUOTED multi alternate (`${x+"${a[@]}"}`) it
		-- also returns (star, quoted=true) so the caller keeps the elements separate
		-- even when the outer ${…} is unquoted — the alternate's OWN quoting governs.
		local function defval(arg)
			if arg == nil then
				return { "" }
			end
			local w = P.parse_word(arg)
			if #w.parts == 1 and is_multi(sh, w.parts[1]) then
				local part = w.parts[1]
				part.q = p.q or part.q -- inner quoting is significant
				local e, s = multi_elems(sh, part)
				return e, s, part.q
			end
			return { expand_word(sh, w, true) }
		end
		if pe.op == "badsubst" then -- e.g. ${a[@]:} (empty offset): discards the rest of the line
			sherr(sh, "curse: ${" .. (pe.raw or pe.name or "") .. "}: bad substitution\n")
			error({ __curse_exit = 1, __curse_lineabort = true })
		end
		if pe.op == "indirect" then -- ${!ref} where ref names an array / $@ / subscript
			local ip = indirect_part(sh, pe)
			if ip then
				ip.q = p.q
				return multi_elems(sh, ip)
			end
			return {}, false
		end
		if pe.op == "indices" then -- ${!a[@]} -> the keys/indices
			if pe.drop then
				return {}, star
			end -- ${!a[@]@X}: a transform on the keys -> empty (bash)
			local ix = sh:array_indices(pe.name)
			local t = {}
			for i = 1, #ix do
				t[i] = tostring(ix[i])
			end
			return t, star
		end
		if pe.op == "prefix" then
			return sh:var_prefix_names(pe.name), pe.star
		end
		local els
		if pe.name == "@" or pe.name == "*" then
			-- $@ / $* operators (slice, @P/@Q transforms, …) run over the positional
			-- params; a slice is indexed over [$0, $1, …] so ${@:0} includes $0.
			els = {}
			if pe.op == "sub" then
				els[1] = sh.argv0 or ""
			end
			for i = 1, sh.nparams do
				els[#els + 1] = sh.params[i]
			end
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
				if off < 0 then
					off = (idx[#idx] or -1) + 1 + off
				end
				local out = {}
				if off >= 0 then -- an out-of-bounds negative offset (off < 0 here) is empty
					for i = 1, #idx do
						if idx[i] >= off then
							out[#out + 1] = els[i]
						end
					end
					if len ~= nil then
						local t = {}
						for i = 1, math.min(len, #out) do
							t[i] = out[i]
						end
						out = t
					end
				end
				els = out
			else -- $@/$* and assoc: position-based
				-- bash's assoc-array slice has an off-by-one quirk: offset N starts at
				-- element N-1 (so :0 and :1 give the same slice). $@/$* are normal.
				if off > 0 and sh:is_assoc(pe.name) then
					off = off - 1
				end
				els = array_slice(els, off, len)
			end
		elseif pe.op == "-" and #els == 0 then -- unset/empty array: the default
			local d, ds, dq = defval(pe.arg)
			return d, (dq ~= nil and ds or star), dq
		-- `:` null-test for @/* differs by form: a QUOTED `*` tests the IFS[0]-joined
		-- string (empty IFS -> concatenation), so `"${a[*]:-w}"` with ("" "") joins to
		-- "" and IS null; `@` (any quoting) and an UNQUOTED `*` test the element list
		-- instead — null iff there are no elements, or exactly one empty element.
		elseif pe.op == ":-" or pe.op == ":+" then
			local ne
			if pe.via_indirect then
				ne = #els > 0 -- indirect array :-/:+ tests element COUNT, not emptiness (bash)
			elseif star and p.q then
				ne = table.concat(els, sh.vars["IFS"] and rt.ifs_first(sh:get("IFS")) or " ") ~= ""
			else
				ne = #els > 1 or (els[1] ~= nil and els[1] ~= "")
			end
			if pe.op == ":-" then
				if not ne then
					local d, ds, dq = defval(pe.arg)
					return d, (dq ~= nil and ds or star), dq
				end
			elseif ne then
				local d, ds, dq = defval(pe.arg)
				return d, (dq ~= nil and ds or star), dq
			else
				return {}, star
			end
		elseif pe.op == "+" then -- alternate iff the array has any element (is set)
			if #els > 0 then
				local d, ds, dq = defval(pe.arg)
				return d, (dq ~= nil and ds or star), dq
			else
				return {}, star
			end
		elseif pe.op == "@" and pe.arg == "A" and pe.name ~= "@" and pe.name ~= "*" then
			-- ${a[@]@A}: the whole array as the declaration that recreates it (one word)
			local d = M._int.fmt_decl(sh, pe.name)
			return d and { d } or {}, star
		elseif pe.op == "@" and pe.arg == "a" then -- ${a[@]@a}: the variable's attribute string, per element
			local attr = sh:attr_string(pe.name)
			local out = {}
			for i = 1, #els do
				out[i] = attr
			end
			els = out
		elseif pe.op and pe.op ~= ":-" and pe.op ~= "-" and pe.op ~= ":+" and pe.op ~= "+" then
			-- strip/subst/case per element: the PATTERN is quote-aware (a quoted `'*'` is a literal
			-- `*`, not a glob) — expand_pattern, like the scalar path (getpattern in bash). Only the
			-- replacement (arg2) is plain quote-removal (expand_word).
			local arg = pe.arg and expand_pattern(sh, P.parse_word(pe.arg)) or ""
			local arg2 = pe.arg2 and expand_word(sh, P.parse_word(pe.arg2)) or nil
			local out = {}
			for i, v in ipairs(els) do
				out[i] = sh:apply_str_op(pe.op, v, arg, arg2)
			end
			els = out
		end
		return els, star
	end
	local els = {}
	for i = 1, sh.nparams do
		els[i] = sh.params[i]
	end
	return els, (p.special == "*")
end

-- ${!ref}: return (element list, star) for the compiled tier's multi-segment. A target that
-- resolves to an array/$@ is multi (multi_elems); a scalar target is a 1-element list of the
-- scalar indirect value. An empty/absent resolution (a set ref whose value is "", an unset
-- positional ref) is ONE empty field ("" — matching the scalar path, which yields one field
-- when quoted); an invalid indirect (unset ref base) raises in indirect_part.
function M.indirect_seg(sh, pe, q)
	local part = { pexp = pe, q = q }
	if is_multi(sh, part) then
		return multi_elems(sh, part)
	end
	local ip = indirect_part(sh, pe)
	if not ip then
		return { "" }, false
	end -- set-ref-empty / unset-positional: one empty field
	ip.q = q
	return { expand_part_str(sh, ip) }, false
end

-- Expand a word to a LIST of fields (command args, for-in lists): unquoted
-- expansions split on default-IFS whitespace; quoted text never splits; "$@" /
-- "${a[@]}" yield one field per element.
-- bash glob_pattern_p on a plain (already-expanded) string: `*`/`?` always
-- active, `[` only with a later `]`. Conservative — never reports inactive for a
-- real glob — so the caller may safely skip pathname expansion when it's false.
local function str_glob_active(s)
	local open = false
	for i = 1, #s do
		local c = s:sub(i, i)
		if c == "*" or c == "?" then
			return true
		elseif c == "[" then
			open = true
		elseif c == "/" then
			open = false -- (a bracket expression can't span a `/`)
		elseif c == "]" then
			if open then
				return true
			end
		elseif (c == "+" or c == "@" or c == "!") and s:sub(i + 1, i + 1) == "(" then
			return true
		end
	end
	return false
end

local function expand_to_fields(sh, w)
	-- Fast path: a single literal part — the common shape of command words (`[`,
	-- operators, numbers, most argv). No expansion, no IFS split, and (when it has
	-- no active glob metachar and no `~`) no pathname expansion either — so skip the
	-- entire per-word setup (closures, IFS parse, glob machinery). A quoted literal
	-- is atomic and never globs; an unquoted one needs the full path only for a
	-- word-initial `~` or an active glob.
	if #w.parts == 1 then
		local p = w.parts[1]
		if p.lit ~= nil and not p.pexp and not is_multi(sh, p) then
			local s = expand_part_str(sh, p)
			if p.q then
				return { s }
			end
			if not s:find("~", 1, true) and (sh.opt_f or not str_glob_active(s)) then
				return { s }
			end
		end
	end
	-- Concatenate-then-split model: build the word left to right, splitting the
	-- chars that came from UNQUOTED expansions on $IFS (default: space/tab/newline),
	-- while literal/quoted chars are never delimiters. This is what bash does, and
	-- it handles concatenation ($x-, pre$x) and custom IFS correctly. Fields also
	-- track `unq` for glob eligibility (quoted glob chars stay literal).
	local ifs = sh.vars["IFS"] and sh:get("IFS") or " \t\n"
	-- IFS is a SET of characters; a delimiter may be multibyte (`IFS=ç`), so index by
	-- whole codepoint, not byte (byte-indexing splits ç's two bytes as two delimiters).
	-- Memoize the parse keyed on the IFS string: it changes rarely but this runs per
	-- word, and rt.mb_chars uses per-char mbrtowc FFI calls — costly in a hot loop.
	local ic = sh._ifscache
	if not ic or ic.ifs ~= ifs then
		local set = {}
		for _, ch in ipairs(rt.mb_chars(ifs)) do
			set[ch.s] = true
		end
		ic = { ifs = ifs, set = set, mbifs = rt.lc_mb_cur_max() > 1 and ifs:find("[\128-\255]") ~= nil } -- any multibyte IFS char?
		sh._ifscache = ic
	end
	local ifsset, mbifs = ic.set, ic.mbifs
	local function isws(c)
		return c == " " or c == "\t" or c == "\n"
	end
	local function inifs(c)
		return c ~= "" and ifsset[c]
	end
	local function clen(v, i) -- byte length of the char at i (fast for ASCII)
		if not mbifs or v:byte(i) < 0x80 then
			return 1
		end
		return rt.mb_charlen(v, i)
	end
	-- `q` is a per-character literal-mask parallel to the field's string ("1" = the
	-- char came from QUOTED/escaped text so it's literal in pathname expansion, "0" =
	-- glob-active). Kept OUT OF BAND (not an escape byte) so it can't collide with a
	-- real byte in the data — curse is byte-transparent, so `'[bc]'*.mm` matches the
	-- file [bc]ar.mm while a $'\x01' byte passes through untouched.
	local fields, cur, cur_unq, cur_q = {}, nil, false, nil
	local function brk()
		if cur ~= nil then
			fields[#fields + 1] = { s = cur, unq = cur_unq, q = cur_q }
			cur, cur_unq, cur_q = nil, false, nil
		end
	end
	local function add(s, unq)
		cur = (cur or "") .. s
		cur_q = (cur_q or "") .. (unq and "0" or "1"):rep(#s)
		if unq then
			cur_unq = true
		end
	end
	local function feed_split(v) -- unquoted expansion text: split on $IFS
		local i, n = 1, #v
		while i <= n do
			local cl = clen(v, i)
			local c = cl == 1 and v:sub(i, i) or v:sub(i, i + cl - 1)
			if inifs(c) then
				if isws(c) then -- whitespace IFS chars are always single-byte
					if cur ~= nil then
						brk()
					end
					i = i + 1
					while i <= n and isws(v:sub(i, i)) do
						i = i + 1
					end
					if i <= n then
						local nl = clen(v, i)
						local nc = nl == 1 and v:sub(i, i) or v:sub(i, i + nl - 1)
						if inifs(nc) and not isws(nc) then
							i = i + nl
							while i <= n and isws(v:sub(i, i)) do
								i = i + 1
							end
						end
					end
				else -- non-whitespace IFS delimiter (may be multibyte)
					if cur == nil then
						cur = ""
					end -- a delimiter always ends a field (empty ok)
					cur_unq = true
					brk()
					i = i + cl
					while i <= n and isws(v:sub(i, i)) do
						i = i + 1
					end
				end
			else
				add(c, true)
				i = i + cl
			end
		end
	end
	for pi, p in ipairs(w.parts) do
		if is_multi(sh, p) then
			local els, star, qforced = multi_elems(sh, p) -- qforced: a quoted multi alternate
			if p.q or qforced then
				if star then -- "$*" / "${a[*]}" join with the first char of IFS
					local sep = sh.vars["IFS"] and rt.ifs_first(sh:get("IFS")) or " "
					add(table.concat(els, sep), false)
				else
					for k = 1, #els do
						if k > 1 then
							brk()
						end
						add(els[k], false)
					end
				end -- one field per element
			else
				-- unquoted $@/$*/array: bash joins the elements with IFS[0] (space when IFS
				-- is whitespace/unset) into ONE string and word-splits that — so empty
				-- elements survive under a non-whitespace IFS (`=$@=` on empty params gives
				-- `= '' '' '' =`) and an empty middle element becomes an empty field. With
				-- IFS='' there is no splitting, so keep the per-element model (empty drops).
				local pe = p.pexp
				if star and pe and (pe.op == "prefix" or pe.op == "indices") then
					-- The INDIRECT `${!pfx*}` / `${!a[*]}` `*` forms join into ONE string
					-- BEFORE word-splitting even under IFS='' (unlike `$*`/`${a[*]}`, which
					-- stay per-element there). Join with IFS[0]; when IFS is empty the prefix
					-- form concatenates but the KEYS form falls back to a space (bug #627).
					local sep = sh.vars["IFS"] and rt.ifs_first(sh:get("IFS")) or " "
					if sep == "" and pe.op == "indices" then
						sep = " "
					end
					feed_split(table.concat(els, sep))
				elseif ifs == "" then
					for k = 1, #els do
						if k > 1 then
							brk()
						end
						feed_split(els[k])
					end
				else
					feed_split(table.concat(els, rt.ifs_first(ifs)))
				end
			end
		elseif
			p.pexp
			and not p.q
			and (p.pexp.op == ":-" or p.pexp.op == "-" or p.pexp.op == ":+" or p.pexp.op == "+")
			and not p.pexp.index
			and p.pexp.name ~= "@"
			and p.pexp.name ~= "*"
		then
			-- unquoted ${x:-word}/-/:+/+: when the WORD branch is taken, the word's OWN quoting
			-- governs splitting (bash), so expand it field-wise rather than as a flat string —
			-- and a quoted "$@"/"${a[@]}" in it keeps its separate words (${1+"$@"})
			local pe = p.pexp
			local b = sh.vars[sh:deref(pe.name)]
			local hasval = b ~= nil and (b.s ~= nil or b.n ~= nil or b.arr ~= nil) or sh:special_get(pe.name) ~= ""
			local pn = tonumber(pe.name) -- a positional parameter is set when within $#
			if pn then
				hasval = pn == 0 or pn <= sh.nparams
			end
			local nonnull = sh:get(pe.name) ~= ""
			local useword
			if pe.op == ":-" then
				useword = not nonnull
			elseif pe.op == "-" then
				useword = not hasval
			elseif pe.op == ":+" then
				useword = nonnull
			else
				useword = hasval
			end
			if useword and pe.arg then
				-- expand the default's parts: a QUOTED part is one atomic (sub)field, an
				-- unquoted part word-splits — so 'a b' stays one field but a b splits.
				for k, sp in ipairs(P.parse_word(pe.arg).parts) do
					if sp.q and is_multi(sh, sp) then
						local els, star = multi_elems(sh, sp)
						if star then
							add(table.concat(els, sh.vars["IFS"] and rt.ifs_first(sh:get("IFS")) or " "), false)
						else
							for e = 1, #els do
								if e > 1 then
									brk()
								end
								add(els[e], false)
							end
						end
					elseif is_multi(sh, sp) then -- unquoted $@/$*: as at the top level of a word
						local els = multi_elems(sh, sp)
						if ifs == "" then
							for e = 1, #els do
								if e > 1 then
									brk()
								end
								feed_split(els[e])
							end
						else
							feed_split(table.concat(els, rt.ifs_first(ifs)))
						end
					else
						local s = expand_part_str(sh, sp)
						if k == 1 and sp.lit ~= nil and not sp.q then
							s = tilde_prefix(sh, s)
						end -- word-initial ~
						if sp.q then
							add(s, false)
						else
							feed_split(s)
						end
					end
				end
			elseif pe.op == ":-" or pe.op == "-" then
				feed_split(sh:get(pe.name))
			end
		else
			local s = expand_part_str(sh, p)
			if pi == 1 and p.lit ~= nil and not p.q then
				-- (posix: `NAME=` args tilde-expand only for declaration builtins — parser
				-- marks the other commands' args `plainarg`)
				s = tilde_word_initial(sh, s, #w.parts > 1, sh.opt_posix and w.plainarg)
			end -- word-initial / NAME= ~
			if p.q or p.lit ~= nil then
				add(s, not p.q)
			else
				feed_split(s)
			end
		end
	end
	brk()
	-- pathname expansion on fields with unquoted glob metacharacters
	local out = {}
	-- GLOBIGNORE (set & non-null): filter matches by its `:`-separated patterns and
	-- enable dotglob (leading-dot names then match); `.`/`..` are always excluded.
	local gi = sh:get("GLOBIGNORE")
	-- The dotglob + `.`/`..`-exclusion SIDE EFFECT triggers when GLOBIGNORE merely
	-- EXISTS (bash: `GLOBIGNORE=` empty still enables it — only `unset` reverts);
	-- the pattern FILTERING needs it non-empty.
	local gi_exists = sh.vars[sh:deref("GLOBIGNORE")] ~= nil
	local giset = gi_exists and gi ~= ""
	local dotglob = gi_exists or (sh.shopt.dotglob and true)
	local nullglob = sh.shopt.nullglob and true
	local gipats
	if giset then -- split on ':' but NOT inside [...] (a `[[:alnum:]]` class holds colons)
		gipats = {}
		local depth, cur = 0, {}
		for k = 1, #gi do
			local c = gi:sub(k, k)
			if c == "[" then
				depth = depth + 1
				cur[#cur + 1] = c
			elseif c == "]" then
				if depth > 0 then
					depth = depth - 1
				end
				cur[#cur + 1] = c
			elseif c == ":" and depth == 0 then
				if #cur > 0 then
					gipats[#gipats + 1] = table.concat(cur)
					cur = {}
				end
			else
				cur[#cur + 1] = c
			end
		end
		if #cur > 0 then
			gipats[#gipats + 1] = table.concat(cur)
		end
	end
	local noglob = sh.opt_f -- set -f: pathname expansion disabled; globs stay literal
	local GLOBSPECIAL = {
		["*"] = 1,
		["?"] = 1,
		["["] = 1,
		["]"] = 1,
		["\\"] = 1,
		["+"] = 1,
		["@"] = 1,
		["!"] = 1,
		["("] = 1,
		[")"] = 1,
		["|"] = 1,
	} -- `|` protects a
	-- quoted/escaped extglob alternation bar (`@(a|'b|c')`) from split_arms
	-- is there a glob metacharacter at a NON-masked (glob-active) position?
	-- bash glob_pattern_p: `*`/`?` are always active; `[` only counts when a later
	-- (unmasked) `]` closes it — a lone `[` (e.g. the `[` test builtin) is literal,
	-- so it must NOT trigger a directory scan. Mirrors glob_conv's own "no closing
	-- ] → literal [" rule; keeping them in sync avoids pointless per-word globbing.
	local glob_active = rt.field_glob_active
	-- build the glob pattern: a masked (quoted) glob-special char is backslash-escaped
	-- so glob_conv treats it literally; the stored value f.s is left byte-for-byte intact.
	local function glob_pat(f)
		if not f.q or not f.q:find("1") then
			return f.s
		end
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
			local m = rt.glob_expand(
				glob_pat(f),
				{
					dotglob = dotglob,
					skipdots = giset or shopt_on(sh, "globskipdots"),
					globstar = shopt_on(sh, "globstar"),
				}
			)
			if m and gipats then
				local filt = {}
				for _, x in ipairs(m) do
					local ig = false
					for _, p in ipairs(gipats) do
						if rt.glob_ignore_match(x, p) then
							ig = true
							break
						end
					end
					if not ig then
						filt[#filt + 1] = x
					end
				end
				m = (#filt > 0) and filt or nil
			end
			if m then
				for _, x in ipairs(m) do
					out[#out + 1] = x
				end
			elseif sh.shopt.failglob then -- shopt -s failglob: no match aborts the rest of
				-- the current LINE (bash: like a fatal expansion error), so tag lineabort
				-- (not experr) — run_lazy fast-forwards past same-line statements.
				io.stderr:write("curse: no match: " .. f.s .. "\n")
				error({ __curse_exit = 1, __curse_lineabort = true })
			elseif nullglob then -- no matches: nullglob drops the field entirely
			else
				out[#out + 1] = f.s
			end
		else
			out[#out + 1] = f.s
		end
	end
	return out
end
M.expand_to_fields = expand_to_fields -- the compiled tier builds argv fields for a word AST

local exec_list -- forward

-- ---- redirections ----
-- Apply a command's redirs, saving fds 0/1/2 for restore. open flags: 577 =
-- O_WRONLY|O_CREAT|O_TRUNC, 1089 = |O_APPEND, 0 = O_RDONLY; mode 0644.
-- Feed a string as a command's stdin (heredoc/herestring): write to a temp file,
-- open it, dup2 onto fd 0, unlink (the open fd keeps the inode alive).
-- Move an opened fd `f` onto target `fd`. If open() already handed us the target
-- (it returns the lowest free fd, e.g. 3 for `3<file`), dup2/close would close the
-- very fd we just set up — so only dup2+close when they differ.
local function place_fd(f, fd)
	if f ~= fd then
		C.dup2(f, fd)
		C.close(f)
	end
end
local function feed_stdin(fd, body)
	local tmp = os.tmpname()
	local w = io.open(tmp, "w")
	if w then
		w:write(body)
		w:close()
	end
	local f = C.open(tmp, 0, 0)
	if f >= 0 then
		place_fd(f, fd)
	end
	os.remove(tmp)
end
-- Apply redirections, backing up each touched fd (any fd, not just 0/1/2) so it
-- can be restored. Returns (save, ok); ok is false when an open() failed (bash
-- then skips the command and reports failure).
-- Lowest free fd >= 10 (bash allocates named-fd redirs here); F_GETFD=1 on a
-- closed fd returns -1 (EBADF).
local function alloc_fd()
	for fd = 10, 250 do
		if C.fcntl(fd, 1) == -1 then
			return fd
		end
	end
	return -1
end
-- Open a `>`/`&>` target honoring noclobber (set -C): with noclobber, `>` must
-- not overwrite an existing REGULAR file, but may still write non-regular files
-- (/dev/null, fifos, devices). Returns the fd, or -1 on a noclobber clobber error.
local function open_out(sh, path, mode)
	if not sh.opt_C then
		return C.open(path, 577, mode)
	end -- O_WRONLY|O_CREAT|O_TRUNC
	local f = C.open(path, 705, mode) -- + O_EXCL
	if f >= 0 then
		return f
	end
	local ok, rc = pcall(C.curse_stat, path, statbuf) -- O_EXCL failed: allow non-regular
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
	-- Named-fd (`{var}>`) targets are NOT restored after the command: bash leaves
	-- them open (so a later `{var}>` gets the next fd), unlike a numeric redirect.
	local persist = {}
	local function backup(fd)
		if not persist[fd] then
			save[#save + 1] = { fd = fd, saved = rt.save_fd(fd) }
		end
	end
	-- redirect targets are word-expanded at runtime (e.g. `> $TMP/f`, `>& $myfd`).
	local function tgt(r)
		return expand_word(sh, P.parse_word(r.target or ""))
	end
	-- A FILE redirect target is glob-expanded and word-split like any word; bash
	-- requires it to resolve to EXACTLY ONE word, else "ambiguous redirect".
	local function ftgt(r)
		local raw = r.target or ""
		-- bash brace-expands the target too; more than one word -> ambiguous redirect.
		if P.brace_count(raw) > 1 then
			io.stderr:write("curse: " .. raw .. ": ambiguous redirect\n")
			return nil
		end
		-- expansion can also fail non-fatally (e.g. failglob no-match): the redirect
		-- then fails (status 1) rather than aborting the script.
		local eok, fs = rt.redir_noglob(sh, expand_to_fields, sh, P.parse_word(raw))
		if not eok then
			return nil
		end
		if #fs ~= 1 then
			io.stderr:write("curse: " .. raw .. ": ambiguous redirect\n")
			return nil
		end
		if sh.opt_r and r.op ~= "in" then -- restricted: no output to files (fd dups still work)
			io.stderr:write("curse: " .. fs[1] .. ": restricted: cannot redirect output\n")
			return nil
		end
		return fs[1]
	end
	for _, r in ipairs(redirs) do
		-- `{var}>…`: allocate a fresh fd (>=10), store it in `var`, and redirect there.
		-- `{var}>&-` instead closes the fd already stored in `var` (no allocation).
		-- {v} or an array element {a[i]}: where the allocated fd number is stored/read
		local fvn, fvs = nil, nil
		if r.fdvar then
			fvn, fvs = r.fdvar:match("^([%a_][%w_]*)%[(.*)%]$")
		end
		local function fdvar_get()
			if fvn then
				return sh:array_get(fvn, array_key(sh, fvn, fvs))
			end
			return sh:get(r.fdvar)
		end
		local function fdvar_set(v)
			if fvn then
				sh:array_set(fvn, array_key(sh, fvn, fvs), v, false)
			else
				sh:set_str(r.fdvar, v)
			end
		end
		local fdb = r.fdvar and sh.vars[sh:deref(fvn or r.fdvar)]
		if fdb and fdb.ro and not ((r.op == "dup" or r.op == "dupin") and r.target == "-") then
			-- `{v}>…` with v readonly: bash refuses (no fd is allocated) and the command fails
			io.stderr:write("curse: " .. r.fdvar .. ": readonly variable\n")
			io.stderr:write("curse: " .. r.fdvar .. ": cannot assign fd to variable\n")
			ok = false
			break
		end
		if r.fdvar then
			if (r.op == "dup" or r.op == "dupin") and r.target == "-" then
				r = setmetatable({ fd = tonumber(fdvar_get()) or -1 }, { __index = r })
			else
				local nf = alloc_fd()
				fdvar_set(tostring(nf))
				persist[nf] = true
				r = setmetatable({ fd = nf }, { __index = r }) -- shadow r.fd, inherit op/target
			end
		end
		if
			((r.op == "out" or r.op == "clobber" or r.op == "app" or r.op == "rw") and r.fd == 1)
			or r.op == "outboth"
			or r.op == "appboth"
		then
			fd1file = true
		end
		if r.op == "out" then
			-- noclobber (set -C): `>` fails on an existing regular file (open_out)
			local t = ftgt(r)
			if not t then
				ok = false
			else
				backup(r.fd)
				local f = open_out(sh, t, 438)
				if f < 0 then
					rt.open_fail(sh, t)
				end
				if f >= 0 then
					place_fd(f, r.fd)
				else
					ok = false
				end
			end
		elseif r.op == "clobber" then -- `>|` truncates regardless of noclobber
			local t = ftgt(r)
			if not t then
				ok = false
			else
				backup(r.fd)
				local f = C.open(t, 577, 438)
				if f < 0 then
					rt.open_fail(sh, t)
				end
				if f >= 0 then
					place_fd(f, r.fd)
				else
					ok = false
				end
			end
		elseif r.op == "app" then
			local t = ftgt(r)
			if not t then
				ok = false
			else
				backup(r.fd)
				local f = C.open(t, 1089, 438)
				if f < 0 then
					rt.open_fail(sh, t)
				end
				if f >= 0 then
					place_fd(f, r.fd)
				else
					ok = false
				end
			end
		elseif r.op == "in" then
			local t = ftgt(r)
			if not t then
				ok = false
			else
				backup(r.fd)
				local f = C.open(t, 0, 0)
				if f < 0 then
					rt.open_fail(sh, t)
				end
				if f >= 0 then
					place_fd(f, r.fd)
				else
					ok = false
				end
			end
		elseif r.op == "rw" then -- `N<>file`: open read+write (O_RDWR|O_CREAT, no truncate)
			local t = ftgt(r)
			if not t then
				ok = false
			else
				backup(r.fd)
				local f = C.open(t, 66, 438)
				if f < 0 then
					rt.open_fail(sh, t)
				end
				if f >= 0 then
					place_fd(f, r.fd)
				else
					ok = false
				end
			end
		elseif r.op == "outboth" then -- `&>` truncation honors noclobber too
			local t = ftgt(r)
			if not t then
				ok = false
			else
				backup(1)
				backup(2)
				local f = open_out(sh, t, 438)
				if f < 0 then
					rt.open_fail(sh, t)
				end
				if f >= 0 then
					C.dup2(f, 1)
					C.dup2(f, 2)
					C.close(f)
				else
					ok = false
				end
			end
		elseif r.op == "appboth" then -- `&>>`: append stdout+stderr (append ignores noclobber)
			local t = ftgt(r)
			if not t then
				ok = false
			else
				backup(1)
				backup(2)
				local f = C.open(t, 1089, 438)
				if f < 0 then
					rt.open_fail(sh, t)
				end
				if f >= 0 then
					C.dup2(f, 1)
					C.dup2(f, 2)
					C.close(f)
				else
					ok = false
				end
			end
		elseif r.op == "heredoc" then
			local body = r.body or ""
			local hok = true
			if r.expand then
				-- an unterminated $( in the body fails the redirection (bash: status 1)
				local pok, pw = pcall(P.parse_heredoc, body, true)
				if pok then
					body = expand_word(sh, pw)
				else
					io.stderr:write("curse: command substitution: unexpected EOF while looking for matching `)'\n")
					hok, ok = false, false
				end
			end
			if hok then
				backup(r.fd or 0)
				feed_stdin(r.fd or 0, body)
			end
		elseif r.op == "herestring" then
			local body = expand_word(sh, P.parse_word(r.word or "")) .. "\n"
			backup(r.fd or 0)
			feed_stdin(r.fd or 0, body)
		elseif r.op == "dup" or r.op == "dupin" then
			-- the `>&`/`<&` target is field-split like a file target: more than one field
			-- (e.g. `>& "$@"` with several params) is an ambiguous redirect (bash).
			local tv = ftgt(r)
			if not tv then
				ok = false
			elseif tv == "-" then
				backup(r.fd)
				C.close(r.fd) -- `N>&-` closes fd N
			else
				local movesrc = tv:match("^(%d+)%-$") -- `N>&M-`: dup then close the source (move)
				local m = tonumber(movesrc or tv)
				if m then
					-- Validate the source fd is open BEFORE backing up the destination: a
					-- dup-based backup would otherwise reuse a just-closed source fd number,
					-- making a stale `>&N` spuriously succeed (fd N reopened as the backup).
					if C.fcntl(m, 1) == -1 then -- F_GETFD on a closed fd returns -1 (EBADF)
						-- (bash names the target as written: `$v: Bad file descriptor`)
						io.stderr:write("curse: " .. (r.target or tv) .. ": Bad file descriptor\n")
						ok = false
					else
						backup(r.fd)
						C.dup2(m, r.fd)
						if movesrc then
							C.close(m)
						end
						-- `2>&1` while capturing (fd 1 not a file): route curse's OWN error
						-- output into the capture buffer too (bash captures it; our in-process
						-- capture leaves fd 1 real, so the error would otherwise leak). See sherr.
						if r.fd == 2 and m == 1 and sh.capturing and not fd1file then
							save.e2o = (save.e2o or 0) + 1
							save._sh = sh
							sh.err2out = (sh.err2out or 0) + 1
						end
					end
				elseif r.op == "dup" and tv ~= "" and sh.opt_r then
					io.stderr:write("curse: " .. tv .. ": restricted: cannot redirect output\n")
					ok = false
				elseif r.op == "dup" and tv ~= "" then -- `>&word` (non-number): open the file for
					backup(r.fd)
					backup(2)
					local f = C.open(tv, sh.opt_C and 705 or 577, 438) -- both stdout AND stderr
					if f >= 0 then
						C.dup2(f, r.fd)
						C.dup2(f, 2)
						C.close(f)
					else
						ok = false
					end
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
		if
			not r.fdvar
			and (
				r.op == "outboth"
				or r.op == "appboth"
				or (
					r.fd == 1
					and (r.op == "out" or r.op == "app" or r.op == "clobber" or r.op == "dup" or r.op == "rw")
				)
			)
		then
			return true
		end
	end
	return false
end
local function restore_redirs(save)
	if save.e2o and save._sh then
		save._sh.err2out = (save._sh.err2out or 0) - save.e2o
	end -- undo 2>&1 capture routing
	for k = #save, 1, -1 do
		local s = save[k]
		if s.saved >= 0 then
			C.dup2(s.saved, s.fd)
			C.close(s.saved)
		else
			C.close(s.fd)
		end
	end
end
-- Write a curse error message. Inside a `$(...)` capture where `2>&1` is active,
-- route it into the capture buffer (sh.out) so it's captured like bash does;
-- otherwise to real stderr.
sherr = function(sh, msg)
	if sh.capturing and (sh.err2out or 0) > 0 then
		sh.out(msg)
	else
		io.stderr:write(msg)
	end
end

-- name classification for `type` / `command -v`
-- Builtins whose implementation is extracted into a lazily-loaded feature module
-- (name -> module). exec_simple routes these through require() instead of its
-- inline dispatch, so a cold script that never uses them never loads their code.
local BUILTIN_LAZY = rt.BUILTIN_LAZY -- one source of truth (runtime); shared with the compiled tier
local LATE_FORK_BUILTIN = rt.LATE_FORK_BUILTIN
local BUILTINS = {
	echo = 1,
	[":"] = 1,
	["true"] = 1,
	["false"] = 1,
	["["] = 1,
	test = 1,
	["return"] = 1,
	exit = 1,
	cd = 1,
	unset = 1,
	export = 1,
	declare = 1,
	typeset = 1,
	set = 1,
	shift = 1,
	read = 1,
	getopts = 1,
	printf = 1,
	["local"] = 1,
	command = 1,
	type = 1,
	pwd = 1,
	eval = 1,
	source = 1,
	["."] = 1,
	["break"] = 1,
	["continue"] = 1,
	["true"] = 1,
	exec = 1,
	readonly = 1,
	umask = 1,
	alias = 1,
	unalias = 1,
	shopt = 1,
	wait = 1,
	fg = 1,
	bg = 1,
	trap = 1,
	mapfile = 1,
	readarray = 1,
	compgen = 1,
	complete = 1,
	compopt = 1,
	pushd = 1,
	popd = 1,
	dirs = 1,
	builtin = 1,
	kill = 1,
	ulimit = 1,
	jobs = 1,
	history = 1,
	fc = 1,
	hash = 1,
	["let"] = 1,
	times = 1,
	bind = 1,
	help = 1,
}
M.BUILTINS = BUILTINS -- exposed so the compiled backend delegates the same set
local KEYWORDS = {
	["if"] = 1,
	["then"] = 1,
	["else"] = 1,
	["elif"] = 1,
	["fi"] = 1,
	["for"] = 1,
	["while"] = 1,
	["until"] = 1,
	["do"] = 1,
	["done"] = 1,
	["case"] = 1,
	["esac"] = 1,
	["function"] = 1,
	["in"] = 1,
	["select"] = 1,
	["{"] = 1,
	["}"] = 1,
	["!"] = 1,
	["time"] = 1,
	["[["] = 1,
	["]]"] = 1,
	["coproc"] = 1,
}

-- A function's text as bash prints it (`declare -f`, `type`, `command -V`): the
-- print_cmd.c-exact deparse (deparse.lua, loaded only when something is printed), falling
-- back to the verbatim definition text for a construct it can't reproduce.
local function deparse_func(name, st)
	return require("deparse").func(name, st.body, st.redirs, st.subbody) or st.deftext
end
M.deparse_func = deparse_func -- also used by emit.lua at compile time (parity)
-- The stored function body text for `declare -f`/`type`/`command -V`: the
-- bash-canonical deparse, computed at DEFINITION time in both tiers (so interp
-- and compiled print identically) and falling back to the verbatim source.
-- An exported function's environment text (BASH_FUNC_name%%): re-parse the printed
-- definition (every function has one — compiled ones embed it) and print it flat.
local func_body_text
local function func_export_text(sh, name)
	local txt = func_body_text(sh, name)
	local ok, ast = pcall(P.parse, txt or "")
	local st = ok and type(ast) == "table" and ast.stmts and ast.stmts[1]
	if not (st and st.t == "funcdef") then
		return nil
	end
	return require("deparse").export_text(st)
end
func_body_text = function(sh, name)
	local src = sh.func_src and sh.func_src[name]
	if src == nil and sh.func_def and sh.func_def[name] then -- deparsed on first print
		src = deparse_func(name, sh.func_def[name])
		sh.func_src[name] = src
	end
	return src
end

-- Find `name` in PATH (existence, F_OK — bash's type/command-v report a
-- non-executable file too; execution then fails 126 via posix_spawn).
-- Every PATH match for `name`, in search order, as `type`/`command -v` report
-- them. Executables are preferred: when any exist they ARE the result; only when
-- none is executable do we fall back to non-executable regular files (bash still
-- reports those — unlike actual command execution, which requires +x).
local function find_all_in_path(name)
	if name == "" then
		return {}
	end
	local function isfile(p)
		return C.access(p, 0) == 0 and not file_test("-d", p)
	end
	local function isexec(p)
		return C.access(p, 1) == 0 and not file_test("-d", p)
	end
	if name:find("/", 1, true) then
		return isexec(name) and { name } or {}
	end -- a path operand still needs +x
	local path = os.getenv("PATH") or "/usr/bin:/bin"
	local exe, nonexe = {}, {}
	for dir in path:gmatch("[^:]+") do
		local p = dir .. "/" .. name
		if isexec(p) then
			exe[#exe + 1] = p
		elseif isfile(p) then
			nonexe[#nonexe + 1] = p
		end
	end
	return #exe > 0 and exe or nonexe
end
local function find_in_path(name)
	return find_all_in_path(name)[1]
end
local function name_type(sh, name, nofunc)
	-- an alias only counts while aliases expand (bash: a non-interactive shell has
	-- expand_aliases off, so `type m` doesn't see `alias m=…`)
	if sh.aliases[name] and (sh.shopt.expand_aliases or sh.opt_i) then
		return "alias"
	end
	if KEYWORDS[name] then
		return "keyword"
	end
	if not nofunc and sh.functions[name] then
		return "function"
	end -- `type -f` skips functions
	if BUILTINS[name] then
		return "builtin"
	end
	-- a remembered location (`hash`, `hash -p`, or an earlier run) wins, and counts a hit
	-- (bash: `type` reports it "hashed"); the table empties when $PATH changes
	local hc = not name:find("/", 1, true) and sh.hashcache and sh.hashcache[name]
	if hc and sh.hashpath == sh:get("PATH") then
		hc.hits = hc.hits + 1
		return "file", hc.path, true
	end
	local p = find_in_path(name)
	if p then
		return "file", p
	end
	return nil
end

-- Execute an array literal assignment `name=(...)` / `name+=(...)`. bash evaluates
-- in two phases: expand every RHS against the OLD array state first, then evaluate
-- indices left-to-right against the array as it is being built.
local function do_arrayassign(sh, st)
	-- through a nameref (`local -n r=arr; r+=(x)`) the literal lands in the referenced array
	local name = sh:deref(st.name)
	local isassoc = sh:is_assoc(name)
	local anykeyed = false
	for _, e in ipairs(st.elems) do
		if e.key ~= nil then
			anykeyed = true
			break
		end
	end
	local items = {}
	for _, e in ipairs(st.elems) do
		if e.key ~= nil and not (e.brace_bare and not isassoc) then
			-- keyed: an associative array (always keyed), or an indexed key with no brace.
			items[#items + 1] = { key = e.key, op = e.op, val = expand_assign_word(sh, e.word) }
		else
			-- bare: a genuine bare element, OR an indexed keyed element whose value
			-- brace-expands (bash de-keys it — `[k]=` becomes literal in each bare word).
			for _, bw in ipairs(e.brace_bare or { e.word }) do
				for _, f in ipairs(expand_to_fields(sh, bw)) do
					items[#items + 1] = { key = nil, op = "=", val = f }
				end
			end
		end
	end
	-- bash quirk (ASSOCIATIVE arrays only): inside a `=` (not `+=`) compound literal, a
	-- `[k]+=v` element appends to the value a[k] had BEFORE the whole statement — NOT the
	-- (cleared) value nor one set by an earlier element in the same literal. So snapshot
	-- the old element map before clearing. INDEXED arrays instead append to the current
	-- (post-clear) value, and `a+=(...)` keeps the normal "append to current" too.
	local snap
	if not st.append then -- plain assignment resets the array (keep assoc-ness)
		local b = sh.vars[name]
		if isassoc then
			snap = b and b.arr or nil
		end
		if not b then
			sh:array_assign(name, {}, false)
			b = sh.vars[name]
		end
		b.arr = {}
		b.s = nil
		b.n = nil
		b.empty_decl = nil -- assigned now (even `a=()` -> shows =())
		if isassoc then
			b.order = {}
		end
	end
	if isassoc then
		if anykeyed then -- keyed elements assigned; bare ones are an error in bash (skip)
			for _, it in ipairs(items) do
				if it.key ~= nil then
					local idx = array_key(sh, name, it.key)
					if it.op == "+=" and not st.append then -- append to the pre-statement value (see snap)
						sh:array_set(name, idx, (snap and snap[idx] or "") .. it.val, false)
					else
						sh:array_set(name, idx, it.val, it.op == "+=")
					end
				end
			end
		else -- all-bare assoc: alternating key value pairs
			for k = 1, #items, 2 do
				sh:array_set(name, items[k].val, items[k + 1] and items[k + 1].val or "", false)
			end
		end
	else
		local auto = 0
		if st.append then
			local mx, b = -1, sh.vars[name]
			if b and b.s ~= nil and not b.arr then
				b.arr = { [0] = b.s }
				b.s = nil
				b.n = nil
			end -- scalar -> [0]
			if b and b.arr then
				for kk in pairs(b.arr) do
					if kk > mx then
						mx = kk
					end
				end
			end
			auto = mx + 1
		end
		for _, it in ipairs(items) do
			if it.key ~= nil then
				local idx = array_key(sh, name, it.key)
				sh:array_set(name, idx, it.val, it.op == "+=") -- indexed += appends to CURRENT (unlike assoc)
				auto = idx + 1
			else
				sh:array_set(name, auto, it.val, false)
				auto = auto + 1
			end
		end
	end
	-- An array can't live in the process environment: converting a variable to an
	-- array drops it from the env (so a child sees nothing), though bash keeps the
	-- export ATTRIBUTE on the shell variable itself.
	local b = sh.vars[name]
	if b and b.exported then
		C.unsetenv(name)
	end
end
M.do_arrayassign = do_arrayassign
-- Whole `a=(…)` statement (readonly/index checks + error-contained assign + status/$_),
-- so the compiled tier runs it as a runtime primitive instead of delegating to exec_stmt.
function M.run_arrayassign(sh, st)
	local rb = sh.vars[sh:deref(st.name)]
	local nb = sh.vars[st.name]
	if nb and nb.ref and nb.s and nb.s:find("[", 1, true) then -- nameref to an element/`a[@]`
		io.stderr:write("curse: `" .. nb.s .. "': not a valid identifier\n")
		sh.status = 1
	elseif st.index then
		io.stderr:write("curse: " .. st.name .. "[" .. st.index .. "]: cannot assign list to array member\n")
		sh.status = 1
	elseif rb and rb.ro then
		io.stderr:write("curse: " .. st.name .. ": readonly variable\n")
		sh.status = 1
	else
		local aok, aerr = pcall(do_arrayassign, sh, st)
		if aok then
			sh.status = 0
			sh:set_str("_", "")
		elseif type(aerr) == "table" and aerr.__curse_experr then
			sh.status = 1
			if sh.opt_e then
				error({ __curse_exit = 1 })
			end
		else
			error(aerr)
		end
	end
end

-- Quote a value the way `declare -p` does: double-quoted with \ " $ ` escaped.
local function decl_quote(s)
	-- a control char or high byte forces $'…' (bash: `declare -- x=$'a\nb'`);
	-- otherwise the usual double-quoted form.
	if s:find("[%z\1-\31\127-\255]") then
		return rt.shell_quote(s)
	end
	s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("%$", "\\$"):gsub("`", "\\`")
	return '"' .. s .. '"'
end
-- Format one variable as a `declare -p` line, or nil if it is unset.
local function fmt_decl(sh, name)
	-- SHELLOPTS/BASHOPTS are readonly, exported, derived specials with no var box.
	if (name == "SHELLOPTS" or name == "BASHOPTS") and sh.shellopts then
		return "declare -r " .. name .. "=" .. decl_quote(sh:special_get(name))
	end
	local b = sh.vars[name]
	if b == nil then
		return nil
	end
	if b.ref then -- bash shows the export letter on a nameref as `declare -nx`
		return "declare -n" .. (os.getenv(name) ~= nil and "x" or "") .. " " .. name .. "=" .. decl_quote(b.s or "")
	end
	if b.assoc or b.arr then
		-- array/assoc flag letters, bash order: a/A then i(integer) r(readonly) x(export).
		-- Export shows from the ATTRIBUTE (an array is never in the process env, unlike a
		-- scalar), verified: `declare -aix` -> `declare -aix`, `declare -Air` -> `declare -Air`.
		local fl = (b.assoc and "A" or "a")
			.. (b.int and "i" or "")
			.. (b.ro and "r" or "")
			.. (b.exported and "x" or "")
		local parts = {}
		for _, k in ipairs(sh:array_indices(name)) do
			local ks = tostring(k)
			-- an assoc key with shell metacharacters (or control chars) is quoted like a value
			if b.assoc and (ks == "" or ks:find("[^%w_%%+,./:@%-]")) then
				ks = decl_quote(ks)
			end
			parts[#parts + 1] = "[" .. ks .. "]=" .. decl_quote(sh:array_get(name, k))
		end
		if b.assoc then
			if #parts == 0 then
				return b.empty_decl and ("declare -" .. fl .. " " .. name) or ("declare -" .. fl .. " " .. name .. "=()")
			end
			return "declare -" .. fl .. " " .. name .. "=(" .. table.concat(parts, " ") .. " )"
		end
		-- declared with `declare -a` but never assigned (not even `a=()`) -> no =value
		if #parts == 0 and b.empty_decl then
			return "declare -" .. fl .. " " .. name
		end
		return "declare -" .. fl .. " " .. name .. "=(" .. table.concat(parts, " ") .. ")"
	else
		-- attribute letters in bash's canonical order: integer, readonly, export, lower,
		-- upper (verified: `declare -irx` -> `declare -irx`, `declare -xl` -> `declare -xl`).
		local a = (b.int and "i" or "")
			.. (b.ro and "r" or "")
			.. (os.getenv(name) ~= nil and "x" or "")
			.. (b.lower and "l" or "")
			.. (b.upper and "u" or "")
			.. (b.cap and "c" or "")
		local pre = "declare " .. (a == "" and "--" or "-" .. a) .. " " .. name
		if b.s == nil and b.n == nil then
			return pre
		end -- declared but unset: no =value
		return pre .. "=" .. decl_quote(sh:get(name))
	end
end

-- ---- umask helpers ----
local function perms_str(bits)
	return (bit.band(bits, 4) ~= 0 and "r" or "")
		.. (bit.band(bits, 2) ~= 0 and "w" or "")
		.. (bit.band(bits, 1) ~= 0 and "x" or "")
end
local function umask_symbolic(cur)
	local allowed = bit.band(bit.bnot(cur), 511)
	return "u="
		.. perms_str(bit.band(bit.rshift(allowed, 6), 7))
		.. ",g="
		.. perms_str(bit.band(bit.rshift(allowed, 3), 7))
		.. ",o="
		.. perms_str(bit.band(allowed, 7))
end
-- Parse a umask MODE (octal like 0022, or symbolic like u=rwx,go=rx) against the
-- current mask; returns the new mask, or nil on a syntax error.
local function parse_umask(s, cur)
	if s == "" then
		return nil
	end
	if s:match("^[0-7]+$") then
		local v = tonumber(s, 8)
		if v > 511 then
			return nil
		end -- > 0777: out of range (bash errors; it doesn't truncate)
		return v
	end
	local allowed = bit.band(bit.bnot(cur), 511) -- symbolic works on allowed perms
	-- iterate clauses INCLUDING empty ones (`u-r,,u-r`) so an empty clause is a
	-- syntax error, not silently skipped (gmatch "[^,]+" would drop it).
	for clause in (s .. ","):gmatch("([^,]*),") do
		local who, op, perms = clause:match("^([ugoa]*)([=+-])([rwx]*)$")
		if not who then
			return nil
		end
		local pv = 0
		for ch in perms:gmatch(".") do
			pv = bit.bor(pv, ch == "r" and 4 or ch == "w" and 2 or 1)
		end
		if who == "" then
			who = "a"
		end
		local whos = {}
		for c in who:gmatch(".") do
			if c == "a" then
				whos = { "u", "g", "o" }
				break
			else
				whos[#whos + 1] = c
			end
		end
		for _, wc in ipairs(whos) do
			local sh4 = wc == "u" and 6 or wc == "g" and 3 or 0
			local cbits = bit.band(bit.rshift(allowed, sh4), 7)
			if op == "=" then
				cbits = pv
			elseif op == "+" then
				cbits = bit.bor(cbits, pv)
			else
				cbits = bit.band(cbits, bit.band(bit.bnot(pv), 7))
			end
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
-- printf "'X" / '"X': the numeric value of the FIRST CHARACTER — its codepoint in
-- the current locale (bash), falling back to the first byte for invalid UTF-8.
local function char_value(s)
	if s == "" then
		return 0
	end
	local ch = rt.mb_chars(s)[1]
	return (ch and ch.wc) or s:byte(1)
end
local function printf_int(s, uns)
	if s == nil or s == "" then
		return 0, true
	end
	local c = s:sub(1, 1)
	if c == "'" or c == '"' then
		return char_value(s:sub(2)), true
	end
	-- strtoll semantics (NOT shell arithmetic): skip leading blanks, read a single
	-- [sign] hex/octal/decimal integer, and any leftover (trailing chars OR blanks,
	-- and no base#N) makes it invalid — bash still prints the parsed value, status 1.
	local rest = s:gsub("^[ \t\n]+", "")
	local tok = rest:match("^[%+%-]?0[xX]%x+") -- 0x hex
		or rest:match("^[%+%-]?0[0-7]*") -- 0 / 0NNN octal
		or rest:match("^[%+%-]?%d+") -- decimal
	if not tok then
		return 0, false
	end -- no digits at all ("xyz") -> 0, invalid
	-- libc strtoll/strtoull clamp out-of-range values to the type limits (and
	-- strtoull wraps a negative modulo 2^64), exactly matching bash's printf. Cast
	-- to the int64_t/uint64_t typedefs so string.format formats them directly.
	local v = uns and u64(C.strtoull(tok, nil, 0)) or i64(C.strtoll(tok, nil, 0))
	return v, (rest:sub(#tok + 1) == "") -- fully consumed?
end
-- A floating printf argument (for %f/%e/%g): C strtod semantics via tonumber.
local function printf_float(s)
	if s == nil or s == "" then
		return 0, true
	end
	local c = s:sub(1, 1)
	if c == "'" or c == '"' then
		return char_value(s:sub(2)), true
	end
	local v = tonumber(s)
	if v then
		return v, true
	end
	return 0, false
end
-- width/precision for %s or a %(…)T result via string.format on a plain string.
-- printf %q: quote so the result re-reads as the same word (bash style: backslash-
-- escape metacharacters/whitespace; $'…' when control chars are present).
local function printf_q(s)
	if s == "" then
		return "''"
	end
	-- Decode per the locale (bash does the same, with invalid-UTF-8 error recovery):
	-- $'…' is used only when a CONTROL/non-printable/bad char is present; a printable
	-- multibyte char (μ) is kept RAW, not octal-escaped.
	local chars = rt.mb_chars(s)
	local needc = false
	for _, ch in ipairs(chars) do
		if not ch.wc or ch.wc < 32 or ch.wc == 127 or rt.iswprint(ch.wc) == 0 then
			needc = true
			break
		end
	end
	if needc then
		local out = { "$'" }
		for _, ch in ipairs(chars) do
			if ch.wc and ch.wc >= 32 and ch.wc ~= 127 and rt.iswprint(ch.wc) ~= 0 then
				if ch.s == "'" then
					out[#out + 1] = "\\'"
				elseif ch.s == "\\" then
					out[#out + 1] = "\\\\"
				else
					out[#out + 1] = ch.s
				end -- printable codepoint kept raw
			else
				for i = 1, #ch.s do
					local ch2, b = ch.s:sub(i, i), ch.s:byte(i)
					if ch2 == "\n" then
						out[#out + 1] = "\\n"
					elseif ch2 == "\t" then
						out[#out + 1] = "\\t"
					elseif ch2 == "\r" then
						out[#out + 1] = "\\r"
					elseif b < 32 or b >= 127 then
						out[#out + 1] = string.format("\\%03o", b)
					elseif ch2 == "'" then
						out[#out + 1] = "\\'"
					elseif ch2 == "\\" then
						out[#out + 1] = "\\\\"
					else
						out[#out + 1] = ch2
					end
				end
			end
		end
		out[#out + 1] = "'"
		return table.concat(out)
	end
	if s:match("^[%w_@%%%+%-%./,:=^]+$") then
		return s
	end -- nothing to quote: bare
	-- backslash-escape shell metacharacters; printable multibyte bytes are kept raw
	return (s:gsub("[%s\"'\\|&;<>()$`?*%[%]#~=!{}^]", "\\%0"))
end
-- Format one numeric %-conversion from a raw arg string. Returns (string, ok).
local function printf_conv(full, conv, arg)
	if conv == "d" or conv == "i" then
		local v, ok = printf_int(arg)
		return string.format(full .. "d", v), ok
	elseif conv == "u" then
		local v, ok = printf_int(arg, true)
		return string.format(full .. "u", v), ok
	elseif conv == "o" or conv == "x" or conv == "X" then
		local v, ok = printf_int(arg, true)
		return string.format(full .. conv, v), ok
	elseif
		conv == "f"
		or conv == "F"
		or conv == "e"
		or conv == "E"
		or conv == "g"
		or conv == "G"
		or conv == "a"
		or conv == "A"
	then
		local v, ok = printf_float(arg)
		local r = string.format(full .. (conv == "F" and "f" or conv), v)
		local dp = rt.decimal_point() -- (the locale's radix character: `1,0000` under de_DE)
		if dp ~= "." then
			r = r:gsub("%.", dp, 1)
		end
		return r, ok
	end
	return nil, true -- unknown conversion
end
-- The full printf engine. `argv[start..]` are the data args; the format is reused
-- until they're exhausted. Returns (output, status).
-- printf format parse, MEMOIZED by format string (pure function of `fmt`). Backslash
-- escapes are static, so they fold into literal-string tokens; each %-conversion becomes a
-- {conv/strftime, spec, width|dynw, prec|dynp} token. The executor (sh_printf) then walks the
-- cached token list instead of re-scanning the format every call — the common `printf FMT …`
-- in a loop re-uses the same FMT. Bounded by a flush so a long-lived daemon can't grow it.
local _pf_cache, _pf_n = {}, 0
local function printf_parse(fmt)
	local toks, lit = {}, {}
	local function flush()
		if lit[1] then
			toks[#toks + 1] = table.concat(lit)
			lit = {}
		end
	end
	local i, n = 1, #fmt
	while i <= n do
		local c = fmt:sub(i, i)
		if c == "\\" then -- format-level backslash escapes -> static literal chars
			local d = fmt:sub(i + 1, i + 1)
			if d == "n" then
				lit[#lit + 1] = "\n"
				i = i + 2
			elseif d == "t" then
				lit[#lit + 1] = "\t"
				i = i + 2
			elseif d == "r" then
				lit[#lit + 1] = "\r"
				i = i + 2
			elseif d == "\\" then
				lit[#lit + 1] = "\\"
				i = i + 2
			elseif d == "a" then
				lit[#lit + 1] = "\7"
				i = i + 2
			elseif d == "b" then
				lit[#lit + 1] = "\8"
				i = i + 2
			elseif d == "f" then
				lit[#lit + 1] = "\12"
				i = i + 2
			elseif d == "v" then
				lit[#lit + 1] = "\11"
				i = i + 2
			elseif d == "'" or d == '"' or d == "?" then -- (the format knows these; %b doesn't)
				lit[#lit + 1] = d
				i = i + 2
			elseif d == "e" or d == "E" then
				lit[#lit + 1] = "\27"
				i = i + 2
			elseif d == "x" then
				local h = fmt:match("^%x%x?", i + 2)
				if h then
					lit[#lit + 1] = string.char(tonumber(h, 16))
					i = i + 2 + #h
				else
					lit[#lit + 1] = "\\"
					i = i + 1
				end
			elseif d == "u" or d == "U" then
				local h = fmt:match(d == "u" and "^%x%x?%x?%x?" or "^%x%x?%x?%x?%x?%x?%x?%x?", i + 2)
				if h then
					lit[#lit + 1] = rt.utf8_char(tonumber(h, 16))
					i = i + 2 + #h
				else
					lit[#lit + 1] = "\\"
					i = i + 1
				end
			elseif d:match("[0-7]") then
				local o = fmt:match("^[0-7][0-7]?[0-7]?", i + 1)
				lit[#lit + 1] = string.char(tonumber(o, 8) % 256)
				i = i + 1 + #o
			else
				lit[#lit + 1] = "\\"
				i = i + 1
			end
		elseif c == "%" then
			local j = i + 1
			if fmt:sub(j, j) == "%" then
				lit[#lit + 1] = "%"
				i = j + 1
			else
				flush()
				local spec = "%"
				while fmt:sub(j, j):match("[-+ #0]") do
					local fl = fmt:sub(j, j)
					if not spec:find(fl, 2, true) then -- (each flag once: `%000…0d` is `%0d`)
						spec = spec .. fl
					end
					j = j + 1
				end
				local width, dynw = "", false
				if fmt:sub(j, j) == "*" then
					dynw = true
					j = j + 1
				else
					while fmt:sub(j, j):match("%d") do
						width = width .. fmt:sub(j, j)
						j = j + 1
					end
				end
				local prec, dynp = nil, false
				if fmt:sub(j, j) == "." then
					j = j + 1
					prec = ""
					if fmt:sub(j, j) == "*" then
						dynp = true
						j = j + 1
					else
						while fmt:sub(j, j):match("%d") do
							prec = prec .. fmt:sub(j, j)
							j = j + 1
						end
					end
				end
				while fmt:sub(j, j):match("[lhLjzt]") do
					j = j + 1
				end
				if fmt:sub(j, j) == "(" then -- %(FORMAT)T strftime (parens inside FORMAT nest)
					local depth, close = 1, nil
					for q = j + 1, n do
						local ch = fmt:sub(q, q)
						if ch == "(" then
							depth = depth + 1
						elseif ch == ")" then
							depth = depth - 1
							if depth == 0 then
								close = q
								break
							end
						end
					end
					if close and fmt:sub(close + 1, close + 1) == "T" then
						local tfmt = fmt:sub(j + 1, close - 1)
						if tfmt == "" then
							tfmt = "%X" -- (an empty format is the locale's time, bash)
						end
						toks[#toks + 1] =
							{ strftime = true, spec = spec, width = width, dynw = dynw, prec = prec, dynp = dynp, tfmt = tfmt }
						i = close + 2
					else -- not a %(…)T: bash warns and prints it as written
						local stop = close and close + 1 or n
						io.stderr:write("curse: printf: `" .. fmt:sub(stop, stop) .. "': invalid time format specification\n")
						lit[#lit + 1] = fmt:sub(i, stop)
						i = stop + 1
					end
				else
					toks[#toks + 1] =
						{ conv = fmt:sub(j, j), spec = spec, width = width, dynw = dynw, prec = prec, dynp = dynp }
					i = j + 1
				end
			end
		else
			lit[#lit + 1] = c
			i = i + 1
		end
	end
	flush()
	return toks
end
-- `nsets` (optional): collects %n requests as { name, byte-count-so-far } for the caller
local function sh_printf(fmt, argv, start, nsets)
	local toks = _pf_cache[fmt]
	if not toks then
		toks = printf_parse(fmt)
		if _pf_n >= 512 then
			_pf_cache, _pf_n = {}, 0
		end
		_pf_cache[fmt] = toks
		_pf_n = _pf_n + 1
	end
	local out, status, ai = {}, 0, start
	local nargs = #argv
	local function nextarg()
		local v = argv[ai]
		if v ~= nil then
			ai = ai + 1
		end
		return v or ""
	end
	repeat
		local pass_start = ai
		for t = 1, #toks do
			local tk = toks[t]
			if type(tk) == "string" then -- literal chunk
				out[#out + 1] = tk
			else
				local spec, width, prec = tk.spec, tk.width, tk.prec
				if tk.dynw then
					width = tostring(math.floor(tonumber((printf_int(nextarg())))))
				end
				if tk.dynp then
					prec = tostring(math.floor(tonumber((printf_int(nextarg())))))
				end
				if tk.strftime then
					local arg = nextarg()
					local epoch = (arg == "" or arg == "-1") and os.time() or (tonumber(arg) or os.time())
					local sres = os.date(tk.tfmt, epoch) or ""
					if #sres >= 128 then
						sres = ""
					end
					if prec then
						sres = sres:sub(1, tonumber(prec))
					end
					out[#out + 1] = string.format("%" .. spec:sub(2) .. width .. "s", sres)
				else
					local conv = tk.conv
					-- a width past what string.format takes (2 digits): format without it, pad after
					local bigw = tonumber(width)
					if bigw and bigw > 99 then
						width = ""
					else
						bigw = nil
					end
					local full = spec .. width .. (prec and ("." .. prec) or "")
					if conv == "n" then -- %n: store the number of bytes written so far in NAME
						local nm = nextarg()
						if nsets then
							nsets[#nsets + 1] = { nm, #table.concat(out) }
						end
						out[#out + 1] = ""
					elseif conv == "s" then
						out[#out + 1] = string.format(
							(spec:gsub("0", "", 1)) .. width .. (prec and ("." .. prec) or "") .. "s",
							nextarg()
						)
					elseif conv == "c" then
						out[#out + 1] = string.format("%" .. spec:sub(2) .. width .. "s", nextarg():sub(1, 1))
					elseif conv == "b" then
						local bs, bstop = rt.ansi_unescape(nextarg(), "b")
						-- (width AND precision apply to the expanded string, like %s)
						out[#out + 1] = string.format(
							(spec:gsub("0", "", 1)) .. width .. (prec and ("." .. prec) or "") .. "s", bs)
						if bstop then
							return table.concat(out), status
						end
					elseif conv == "q" then
						local s = printf_q(nextarg())
						out[#out + 1] = width ~= "" and string.format("%" .. spec:sub(2) .. width .. "s", s) or s
					else
						local r, ok = printf_conv(full, conv, nextarg())
						if not ok then
							status = 1
						end
						if r == nil then -- invalid conversion: bash reports it and STOPS the output there
							io.stderr:write("curse: printf: `" .. conv .. "': invalid conversion specification\n")
							return table.concat(out), 1
						end
						out[#out + 1] = r
					end
					local s = bigw and out[#out]
					if s and #s < bigw then
						if spec:find("-", 1, true) then
							s = s .. (" "):rep(bigw - #s)
						elseif spec:find("0", 1, true) and not prec and conv:match("[diouxXeEfFgGaA]") then
							local pre, rest = s:match("^([+%- ]?0?[xX]?)(.*)$")
							s = pre .. ("0"):rep(bigw - #s) .. rest
						else
							s = (" "):rep(bigw - #s) .. s
						end
						out[#out] = s
					end
				end
			end
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
	-- $FUNCNEST: past that many nested calls, the call fails (status 1) — bash
	if sh.vars.FUNCNEST then
		local lim = tonumber(sh:get("FUNCNEST"))
		if lim and lim > 0 and (sh.calldepth or 0) >= lim then
			io.stderr:write("curse: " .. cmd .. ": maximum function nesting level exceeded (" .. lim .. ")\n")
			sh.status = 1
			return
		end
	end
	local savedline = sh.cur_line -- the call-site line: $LINENO is restored to it on return
	sh.calldepth = sh.calldepth + 1 -- OSR gate: no handoff inside a call
	sh:pushCall(unpack(args, 2))
	-- Tempenv bindings applied as THIS call's prefix (`x=v func`) belong to this new
	-- frame — tag them so a `local x` in the body absorbs its own call's tempenv
	-- (but not an outer/eval tempenv). See Shell:localVar.
	if tenv_base then
		for k = tenv_base + 1, #sh.tenv do
			sh.tenv[k].frame = sh.pd
		end
	end
	sh.funcstack = sh.funcstack or {}
	table.insert(sh.funcstack, 1, cmd) -- $FUNCNAME[0] = the function now running
	-- Parallel call-stack for ${BASH_LINENO[@]}/${BASH_SOURCE[@]}: the call SITE's
	-- line, and the file it ran in (single-file scripts: the main script path).
	sh.linestack = sh.linestack or {}
	table.insert(sh.linestack, 1, sh.cur_line or 0)
	sh.srcstack = sh.srcstack or {}
	table.insert(sh.srcstack, 1, sh.cur_source or sh.argv0 or "")
	-- ${BASH_SOURCE[0]} in the body is the file the function was DEFINED in
	local saved_src = sh.cur_source
	local deffile = sh.func_file and sh.func_file[cmd]
	if deffile and deffile ~= "" then
		sh.cur_source = deffile
	end
	local saved_ld = sh.loopdepth
	sh.loopdepth = 0 -- break/continue don't cross into a function
	local dbg_saved = rt.debug_enter(sh, cmd)
	-- Redirects on the definition (`f(){ … } >&2`) apply to the whole body per call.
	local fr = sh.func_redirs and sh.func_redirs[cmd]
	local rsave, rsavedout, rok
	if fr then
		rsave, rok = apply_redirs(sh, fr)
		rsavedout = sh.out
		if redirs_touch_stdout(fr) then
			sh.out = io.write
		end
	end
	local ok, err = true, nil
	if fr and rok == false then
		sh.status = 1 -- a failed redirect skips the body (bash)
	elseif type(fn) == "function" then
		ok, err = pcall(fn, sh) -- a COMPILED function closure
	else
		ok, err = pcall(exec_list, sh, fn, hook, false)
	end -- an interp AST body
	if fr then
		io.flush()
		sh.out = rsavedout
		restore_redirs(rsave)
	end
	sh.loopdepth = saved_ld
	rt.debug_leave(sh, dbg_saved)
	table.remove(sh.funcstack, 1)
	table.remove(sh.linestack, 1)
	table.remove(sh.srcstack, 1)
	sh.cur_source = saved_src
	sh:popCall()
	sh.calldepth = sh.calldepth - 1
	sh.cur_line = savedline -- back in the caller: $LINENO (e.g. for a top-level ERR trap) is the call site
	if not ok then
		if type(err) == "table" and err.__curse_return then
			sh.status = err.__curse_return
		else
			error(err)
		end
	end
	-- RETURN trap: fires after the function body returns (in the caller's scope),
	-- preserving the function's exit status. A top-level RETURN trap is NOT inherited
	-- by a function unless functrace (`set -T`) is on (bash) — a sourced script's
	-- return fires it regardless (see the `.`/source builtin).
	local rt_h = (sh.opt_functrace or (sh.fn_trace and sh.fn_trace[cmd])) and sh.traps and sh.traps.RETURN
	if rt_h and rt_h ~= "" and not sh.in_return_trap then
		sh.in_return_trap = true
		local saved = sh.status
		run_trap(sh, rt_h)
		sh.status = saved
		sh.in_return_trap = false
	end
end

-- ---- background job table (for `jobs`, `wait -n`, `wait %jobspec`) ----
local WNOHANG = 1
local job_add = rt.job_add -- (moved to runtime; the compiled tier's run_background uses it too)
-- Reap a job (blocking unless nohang); caches its exit status. Returns the status,
-- or nil if it's still running (nohang) / already gone.
local function job_reap(sh, job, nohang)
	if job.done then
		return job.status
	end
	local sb = ffi.new("int[1]")
	local r = C.waitpid(job.pid, sb, nohang and WNOHANG or 0)
	if r > 0 then
		job.done = true
		job.status = rt.wexit(sb[0])
		if sh.coprocs then
			rt.coproc_dispose(sh, job.pid)
		end
		local s = bit.band(sb[0], 0x7f)
		if s ~= 0 and s ~= 0x7f then
			job.sig = s
		end -- killed by a signal
		return job.status
	end
	if r < 0 and not nohang then
		job.done = true
		job.status = 127
		return 127
	end -- already gone
	return nil -- still running (or, in a subshell, not our child to reap — keep it listed)
end
-- Resolve a `%…` jobspec to a job: %N by id, %+/%% current, %- previous, %str prefix.
local function job_resolve(sh, spec)
	local active = {}
	for _, j in ipairs(sh.jobs or {}) do
		if not j.done then
			active[#active + 1] = j
		end
	end
	if spec == "%%" or spec == "%+" then
		return active[#active]
	end
	if spec == "%-" then
		return active[#active - 1]
	end
	local n = spec:match("^%%(%d+)$")
	if n then
		for _, j in ipairs(sh.jobs or {}) do
			if j.id == tonumber(n) and not j.done then
				return j
			end
		end
		return nil
	end
	local str = spec:match("^%%%%?(.+)$") -- %str / %%str: command-prefix match
	if str then
		for _, j in ipairs(active) do
			if j.cmd:sub(1, #str) == str then
				return j
			end
		end
	end
	return nil
end

local SPECIAL_BUILTIN -- forward decl (assigned below); posix dispatch/funcdef rules
-- xtrace (`set -x`): before running a command, write `$PS4<cmd words>` to stderr,
-- single-quoting any word that isn't a plain token (bash). PS4's first char is
-- repeated by call depth. A plain token is bare; anything else is quoted the way
-- bash quotes it (shell_quote: `$'…'` for control/non-printable, else `'…'`).
local function xtrace_quote(w)
	if w == "" then
		return "''"
	end
	if w:match("^[%w_@%%+=:,./%-]+$") then
		return w
	end
	return rt.shell_quote(w)
end
-- one xtrace line: $PS4 (its first char repeated per call depth) + `text`
local function xtrace_line(sh, text)
	local ps4 = sh:get("PS4")
	if ps4 == "" then
		ps4 = "+ "
	end
	local lead = ps4:sub(1, 1)
	local depth = (sh.xdepth or 0) -- nesting of $(…) (not function calls or subshells)
	local pre = ps4
	if lead ~= "" and depth > 0 then
		pre = lead:rep(depth) .. ps4
	end
	M.xtrace_write(sh, pre .. text .. "\n")
end
M.xtrace_line = xtrace_line
local function xtrace(sh, args, prequoted)
	local parts = {}
	for i = 1, #args do
		parts[i] = prequoted and args[i] or xtrace_quote(args[i])
	end
	xtrace_line(sh, table.concat(parts, " "))
end
-- xtrace output goes to fd $BASH_XTRACEFD when that's set to an open fd (bash), else stderr
M.xtrace_write = function(sh, s)
	local fd = sh.vars.BASH_XTRACEFD and tonumber(sh:get("BASH_XTRACEFD"))
	if fd and fd ~= 2 and fd >= 0 and fd == math.floor(fd) then
		io.flush() -- (our buffered stdout first: fd 1 may be the trace fd)
		if rt.fd_write(fd, s) then
			return
		end
	end
	io.stderr:write(s)
end

local function exec_simple(sh, args, hook, no_func)
	local cmd = args[1]
	-- Consume any pending tempenv-call marker (set by exec_stmt for `x=v cmd`): only
	-- the FIRST command dispatched under it may claim those bindings. A direct
	-- function call tags them with its frame; anything else (a builtin like `eval`,
	-- an external) just drops the marker so a function it later invokes can't absorb.
	local tcb = sh.tenv_call_base
	sh.tenv_call_base = nil
	-- A user function overrides a builtin of the same name (bash), so it wins here
	-- — unless invoked via `command` (no_func), the word is a keyword/assignment
	-- builtin a function can't stand in for, OR (posix mode) it's a SPECIAL builtin,
	-- which is found before the function (so an `eval`/`set`/… function is bypassed).
	if cmd ~= nil and not no_func and sh.functions[cmd] and not (sh.opt_posix and SPECIAL_BUILTIN[cmd]) then
		return run_function(sh, cmd, sh.functions[cmd], args, hook, tcb)
	end
	-- Rarely-used builtins live in lazily-loaded feature modules (kept out of the
	-- cold path). Route them there before the inline dispatch; require caches, so a
	-- feature loads at most once. A user function of the same name already won above.
	-- inside an in-process subshell/$(…), a builtin that needs its own process (fds/process
	-- image, rlimits, signal dispositions, the builtin table, waiting on its own children)
	-- late-forks first (rt.need_process): from here on this runs in a real child
	if LATE_FORK_BUILTIN[cmd] and sh.iso_ctx and sh.iso_ctx[1] then
		rt.need_process(sh)
	end
	local lz = BUILTIN_LAZY[cmd]
	if lz then
		return require(lz)(sh, cmd, args, hook, tcb)
	end
	if cmd == nil then
		sh.status = 0
	elseif cmd == ":" or cmd == "true" then
		sh.status = 0
	elseif cmd == "false" then
		sh.status = 1
	elseif cmd == "break" then -- outside a loop: a no-op (bash), not a fatal unwind
		if args[3] ~= nil then -- too many arguments: usage error; bash still BREAKS the loop
			io.stderr:write("curse: break: too many arguments\n")
			sh.status = 1
			if sh.opt_c then
				error({ __curse_exit = 1 })
			elseif (sh.loopdepth or 0) > 0 then
				error({ __curse_break = 1 })
			end
		elseif args[2] and not tonumber(args[2]) then -- non-numeric count: FATAL (status 128) in a
			io.stderr:write("curse: break: " .. args[2] .. ": numeric argument required\n")
			sh.status = 128 -- non-interactive shell (bash exits); interactive just aborts it
			if not sh.opt_i then
				error({ __curse_exit = 128 })
			end
		else
			sh.status = 0
			if (sh.loopdepth or 0) > 0 then
				error({ __curse_break = tonumber(args[2]) or 1 })
			end
		end
	elseif cmd == "continue" then
		if args[3] ~= nil then -- too many arguments: bash BREAKS the loop (not continue!)
			io.stderr:write("curse: continue: too many arguments\n")
			sh.status = 1
			if sh.opt_c then
				error({ __curse_exit = 1 })
			elseif (sh.loopdepth or 0) > 0 then
				error({ __curse_break = 1 })
			end
		elseif args[2] and not tonumber(args[2]) then -- non-numeric count: fatal, like break
			io.stderr:write("curse: continue: " .. args[2] .. ": numeric argument required\n")
			sh.status = 128
			if not sh.opt_i then
				error({ __curse_exit = 128 })
			end
		else
			sh.status = 0
			if (sh.loopdepth or 0) > 0 then
				error({ __curse_continue = tonumber(args[2]) or 1 })
			end
		end
	elseif cmd == "[" or cmd == "test" then
		do_test(sh, args)
	elseif cmd == "return" then
		-- `return` is only valid inside a function, a sourced script, or a trap;
		-- elsewhere bash reports an error (status 2) but keeps running (no unwind).
		if (sh.calldepth or 0) == 0 and (sh.sourcedepth or 0) == 0 and (sh.in_trap or 0) == 0 then
			io.stderr:write("curse: return: can only `return' from a function or sourced script\n")
			sh.status = 2
			if sh.opt_posix and not sh.opt_i then -- a special builtin's error ends a posix shell
				error({ __curse_exit = 2 })
			end
			return
		end
		if args[2] and not tonumber(args[2]) then
			io.stderr:write("curse: return: " .. args[2] .. ": numeric argument required\n")
			error({ __curse_return = 2 })
		end
		error({ __curse_return = args[2] and (tonumber(args[2]) % 256) or sh.status })
	elseif cmd == "exit" then
		if #args > 2 then
			io.stderr:write("curse: exit: too many arguments\n")
			sh.status = 1
			return
		end -- bash: non-fatal
		if args[2] and not tonumber(args[2]) then
			io.stderr:write("curse: exit: " .. args[2] .. ": numeric argument required\n")
			error({ __curse_exit = 2 })
		end
		error({ __curse_exit = args[2] and (tonumber(args[2]) % 256) or sh.status })
	elseif cmd == "command" and (args[2] == "-v" or args[2] == "-V") then
		local verbose = args[2] == "-V"
		local anyfound = false
		for j = 3, #args do
			local k, p, hashed = name_type(sh, args[j])
			if not k then
				if verbose then
					io.stderr:write("curse: command: " .. args[j] .. ": not found\n")
				end
			else
				anyfound = true
				if verbose then
					if k == "alias" then
						sh:echo(args[j] .. " is aliased to `" .. sh.aliases[args[j]] .. "'")
					elseif k == "file" then
						sh:echo(args[j] .. (hashed and " is hashed (" .. p .. ")" or " is " .. p))
					elseif k == "function" then
						sh:echo(args[j] .. " is a function")
						local d = func_body_text(sh, args[j])
						if d then
							sh:echo(d)
						end -- canonical (or verbatim) body
					elseif k == "keyword" then
						sh:echo(args[j] .. " is a shell keyword")
					else
						sh:echo(args[j] .. " is a shell builtin")
					end
				elseif k == "alias" then
					sh:echo("alias " .. args[j] .. "='" .. sh.aliases[args[j]] .. "'")
				else
					sh:echo(k == "file" and p or args[j])
				end
			end
		end
		sh.status = anyfound and 0 or 1 -- bash: 0 if ANY name resolved (multiple names swallow misses)
	elseif cmd == "command" then
		local j, usep = 2, false
		while args[j] == "-p" or args[j] == "-v" or args[j] == "-V" do
			if args[j] == "-p" then
				usep = true
			end
			j = j + 1
		end
		if usep and rt.restricted(sh, "command: -p: restricted") then
			return
		end
		if args[j] == nil then
			sh.status = 0
		elseif usep then
			-- -p: resolve against the standard-utility PATH (confstr _CS_PATH), not the
			-- caller's $PATH. Temporarily swap it (env + var) around the command.
			local DEFPATH = std_path()
			local oldenv, oldbox = os.getenv("PATH"), sh.vars["PATH"]
			sh:set_str("PATH", DEFPATH)
			C.setenv("PATH", DEFPATH, 1)
			local ok, err = pcall(exec_simple, sh, { unpack(args, j) }, hook, true)
			sh.vars["PATH"] = oldbox
			if oldenv then
				C.setenv("PATH", oldenv, 1)
			else
				C.unsetenv("PATH")
			end
			if not ok then
				error(err)
			end
		else
			exec_simple(sh, { unpack(args, j) }, hook, true)
		end -- run rest, skipping FUNCTION lookup
	elseif sh.functions[cmd] and not no_func then
		run_function(sh, cmd, sh.functions[cmd], args, hook)
	else
		sh:exec(unpack(args))
	end -- external command
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
	if word_initial_tilde(w) and s:sub(1, 1) == "~" then
		return tilde_prefix(sh, s)
	end
	return s
end
local function dbracket_pattern(sh, w)
	local p = expand_pattern(sh, w)
	if word_initial_tilde(w) and p:sub(1, 1) == "~" then
		return tilde_prefix(sh, p)
	end
	return p
end
-- xtrace: each [[ ]] test primary is traced as it's evaluated, operands expanded (bash)
-- xtrace of an arithmetic text ((( )), a for (( )) slot): expanded like a "…" string first
local function arith_trace(sh, s)
	if s:find("[$`]") then
		s = expand_word(sh, P.parse_heredoc(s, false))
	end
	xtrace_line(sh, "(( " .. s .. " ))")
end
local function dbracket_trace(sh, text)
	xtrace_line(sh, "[[ " .. (sh.dbneg and "! " or "") .. text .. " ]]")
	sh.dbneg = nil
end
local function eval_dbracket(sh, node)
	local k = node.kind
	if k == "and" then
		return eval_dbracket(sh, node.l) and eval_dbracket(sh, node.r)
	end
	if k == "or" then
		return eval_dbracket(sh, node.l) or eval_dbracket(sh, node.r)
	end
	if k == "not" then
		if sh.opt_x and node.e.kind ~= "and" and node.e.kind ~= "or" and node.e.kind ~= "not" then
			sh.dbneg = true -- (xtrace: a negated test prints as `[[ ! … ]]`)
		end
		return not eval_dbracket(sh, node.e)
	end
	if k == "str" then
		local v = dbracket_word(sh, node.word)
		if sh.opt_x then
			dbracket_trace(sh, "-n " .. v)
		end
		return v ~= ""
	end
	if k == "unary" and node.op == "-v" then
		local v = expand_word(sh, node.word)
		if sh.opt_x then
			dbracket_trace(sh, "-v " .. v)
		end
		return var_is_set(sh, v)
	end
	if k == "unary" then
		local v = dbracket_word(sh, node.word)
		if sh.opt_x then
			dbracket_trace(sh, node.op .. " " .. v)
		end
		return unary(sh, node.op, v)
	end
	if k == "binary" then
		local l, r, op = dbracket_word(sh, node.l), dbracket_word(sh, node.r), node.op
		if sh.opt_x then
			dbracket_trace(sh, l .. " " .. op .. " " .. r)
		end
		local ic = sh.shopt.nocasematch and true or nil -- shopt -s nocasematch: case-insensitive
		if op == "==" or op == "=" then
			if node.rq and not ic then
				return l == r
			else
				return rt.glob_match(l, dbracket_pattern(sh, node.r), ic)
			end
		elseif op == "!=" then
			if node.rq and not ic then
				return l ~= r
			else
				return not rt.glob_match(l, dbracket_pattern(sh, node.r), ic)
			end
		elseif op == "=~" then
			-- a quoted part of the regex is matched literally (bash), so re-expand with
			-- regex-escaping of quoted segments instead of using the plain rhs.
			-- bash also tilde-expands a word-initial ~ on the =~ RHS and matches THAT
			-- expansion literally (a tilde prefix isn't part of the regex): split off the
			-- ~-token, expand it, and re-expand it as a quoted (regex-escaped) segment.
			local rnode = node.r
			if word_initial_tilde(rnode) then
				local p1 = rnode.parts[1]
				local tok, restlit = p1.lit:match("^(~[^/:]*)(.*)$")
				local exp = tok and tilde_prefix(sh, tok)
				if exp and exp ~= tok then
					local rw = { k = "word", parts = { { lit = exp, q = true } } }
					if restlit ~= "" then
						rw.parts[#rw.parts + 1] = { lit = restlit, q = p1.q }
					end
					for i = 2, #rnode.parts do
						rw.parts[#rw.parts + 1] = rnode.parts[i]
					end
					rnode = rw
				end
			end
			local caps, bad = rt.regex_captures(l, expand_regex(sh, rnode), ic) -- real POSIX ERE + BASH_REMATCH
			if bad then
				error({ __curse_regexerr = true })
			end -- invalid regex -> [[ ]] status 2
			sh:array_assign("BASH_REMATCH", caps or {}, false)
			return caps ~= nil
		elseif op == "-eq" or op == "-ne" or op == "-lt" or op == "-le" or op == "-gt" or op == "-ge" then
			-- [[ ]] arithmetic comparisons evaluate each side as an arith EXPRESSION
			-- (bash: [[ 1+2 -eq 3 ]] is true), unlike `test` which needs integer literals.
			local nl = eval(sh, P.arith(l == "" and "0" or l))
			local nr = eval(sh, P.arith(r == "" and "0" or r))
			if op == "-eq" then
				return nl == nr
			elseif op == "-ne" then
				return nl ~= nr
			elseif op == "-lt" then
				return nl < nr
			elseif op == "-le" then
				return nl <= nr
			elseif op == "-gt" then
				return nl > nr
			else
				return nl >= nr
			end
		else
			return binary(l, op, r, true)
		end -- < > (string comparisons)
	end
	return false
end

-- Compiled-tier [[ ]] leaf primitives: the compiled backend renders the and/or/not
-- tree as native Lua (short-circuit) and calls these for the leaves, with operands
-- computed natively via emit_word — genuine compilation, not an AST re-walk.
function M.dbracket_arith(sh, s)
	local ok, ast = pcall(P.arith, s == "" and "0" or s)
	if not ok then -- not an arithmetic expression: a shell error (fails the command), never
		-- a raw Lua error out of compiled code
		io.stderr:write("curse: " .. s .. ": syntax error in expression\n")
		error({ __curse_exit = 1, __curse_matherr = true, __curse_experr = true })
	end
	return eval(sh, ast)
end -- -eq/-lt… operand
function M.dbracket_unary(sh, op, val)
	return unary(sh, op, val)
end -- file tests, -o, -v, -z/-n
function M.dbracket_bincmp(l, op, r)
	return binary(l, op, r, true)
end -- -nt/-ot/-ef
local function glob_escape(s)
	return (s:gsub("[%*%?%[%]\\]", "\\%0"))
end
function M.dbracket_eq(sh, l, r, rq) -- ==/= : quoted rhs is literal, else a glob
	local ic = sh.shopt.nocasematch and true or nil
	if rq and not ic then
		return l == r
	end
	return rt.glob_match(l, rq and glob_escape(r) or r, ic)
end

-- Run a loop body, catching break/continue (decrementing multi-level n and
-- re-raising when it targets an outer loop). Returns "break", "continue", or nil.
local function run_loop_body(sh, body, hook)
	local ok, err = pcall(exec_list, sh, body, hook, false)
	if ok then
		return nil
	end
	if type(err) == "table" then
		if err.__curse_break then
			if err.__curse_break > 1 then
				error({ __curse_break = err.__curse_break - 1 })
			end
			return "break"
		elseif err.__curse_continue then
			if err.__curse_continue > 1 then
				error({ __curse_continue = err.__curse_continue - 1 })
			end
			return "continue"
		end
	end
	error(err) -- exit/return/real error propagates
end

-- In a forked child (subshell/background/pipeline stage), translate an exit/return
-- thrown as a control table into $? so the child _exits with the right status.
-- (A non-table Lua error is left for the caller; forked children then _exit anyway.)
local child_status = rt.child_status -- (moved to runtime; shared with the compiled tier)

-- Snapshot the <()/>() counts before a command expands its words/redirs, so its
-- cleanup drains ONLY the procsubs it registered — not ones an enclosing group's
-- redirect (`{ …; } > >(tac)`) left pending, which drain after the whole group.
local function procsub_mark(sh)
	return (sh.procsub_pending and #sh.procsub_pending or 0), (sh.procsub_files and #sh.procsub_files or 0)
end
-- Process-substitution cleanup, run after the command a <()/>() was attached to: close
-- the shell's end of each pipe it created (a >(cmd) then sees EOF; an unread <(cmd)
-- writer gets EPIPE) and reap the child. Only entries added since the mark.
local function drain_procsub(sh, np, nf)
	nf = nf or 0
	local files = sh.procsub_files
	if not files or #files <= nf then
		return
	end
	io.flush()
	local stbuf = ffi.new("int[1]")
	for i = nf + 1, #files do
		C.close(files[i].fd)
	end
	sh.procsub_status = {} -- (the latest ones, for a later `wait $!`)
	for i = nf + 1, #files do
		rt.wait_child(files[i].pid, stbuf, 0)
		sh.procsub_status[files[i].pid] = rt.wexit(stbuf[0])
	end
	for i = #files, nf + 1, -1 do
		files[i] = nil
	end
	if #files == 0 then
		sh.procsub_files = nil
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
			args[#args + 1] = rt.cstr(expand_assign_word(sh, w, true)) -- name=value word: no glob, ~ after =/:
		else
			local fs = expand_to_fields(sh, w)
			for k = 1, #fs do
				args[#args + 1] = rt.cstr(fs[k])
			end -- argv entries are C strings: cut at NUL
		end
	end
end

-- Declaration builtins whose `name=value` arguments are assignment words.
local ASSIGN_CMD = { export = 1, declare = 1, typeset = 1, readonly = 1, ["local"] = 1 }
-- POSIX "special built-in utilities": under `set -o posix`, a prefix assignment
-- on one of these persists in the shell (see the prefix-assignment handling).
-- `exec` is special too but is intercepted earlier with its own env handling.
SPECIAL_BUILTIN = {
	[":"] = 1,
	["."] = 1,
	source = 1,
	eval = 1,
	exit = 1,
	export = 1,
	readonly = 1,
	["set"] = 1,
	shift = 1,
	times = 1,
	trap = 1,
	unset = 1,
	["break"] = 1,
	["continue"] = 1,
	["return"] = 1,
}
-- compound commands whose trailing redirs (`done < f`, `fi > f`) apply to the
-- whole construct; handled generically below (simple/group/subshell do their own).
local COMPOUND_REDIR = {
	whilec = true,
	forc = true,
	forin = true,
	["select"] = true,
	["if"] = true,
	case = true,
	arithcmd = true,
	dbracket = true,
	group = true,
}
-- DEBUG trap fires just before each of these "command" nodes (bash runs it before
-- every simple/pipeline/arith/[[/assignment); it preserves $? around the handler.
-- `case` also fires DEBUG before the compound itself (at the `case` line); `if`,
-- `while`, `{ }` groups etc. do NOT — only their inner condition/body commands do.
-- A `pipeline` is NOT here: bash fires DEBUG once per STAGE (in the parent, before
-- forking each), handled inline in the pipeline exec below.
local DEBUG_FIRE = { simple = true, arithcmd = true, dbracket = true, assign = true, assignlist = true, case = true }
local function run_debug(sh, line)
	local h = sh.traps and sh.traps.DEBUG
	if not h or h == "" or sh.in_debug or (sh.in_pipestage or 0) > 0 then
		return
	end
	-- DEBUG doesn't reach into a subshell/command substitution unless functrace extends it.
	-- (A function call hides it at entry instead — rt.debug_enter — so one the function
	-- sets itself still fires in its body.)
	if not sh.opt_functrace and (sh.in_subprogram or 0) > 0 then
		return
	end
	sh.in_debug = true
	local saved = sh.status
	if line then
		sh.cur_line = line
	end
	local exited = run_trap(sh, h)
	local trap_status = sh.status
	sh.status = saved
	sh.in_debug = false
	-- `exit` in a DEBUG trap exits the shell; a non-zero DEBUG return under errexit
	-- also exits (skipping the command), matching bash.
	if exited then
		error({ __curse_exit = trap_status })
	end
	if sh.opt_e and trap_status ~= 0 then
		error({ __curse_exit = trap_status })
	end
	-- shopt -s extdebug: a non-zero DEBUG status skips the command; 2 inside a function
	-- or sourced file acts as a `return` from it (bash)
	if trap_status ~= 0 and sh.shopt.extdebug then
		if trap_status == 2 and ((sh.calldepth or 0) > 0 or (sh.sourcedepth or 0) > 0) then
			error({ __curse_return = sh.status })
		end
		return true
	end
end
M.run_debug = run_debug -- compiled tier fires DEBUG before each native command

local tv_now = ffi.new("struct curse_timeval") -- reused buffer for `time`'s wall clock
local function wall_secs()
	C.gettimeofday(tv_now, nil)
	return tonumber(tv_now.tv_sec) + tonumber(tv_now.tv_usec) * 1e-6
end

local exec_stmt
exec_stmt = function(sh, st, hook)
	local t = st.t
	if t == "noop" then -- (a command that alias-expanded to a comment)
		return
	end
	-- `time [-p] pipeline` reserved word: run the pipeline (with its own type/negate
	-- preserved for errexit), then report elapsed real/user/sys to STDERR like bash.
	if st.timed then
		st.timed = false
		local r0, c0 = wall_secs(), os.clock()
		local ok, err = pcall(exec_stmt, sh, st, hook)
		local real, cpu = wall_secs() - r0, os.clock() - c0
		st.timed = true
		io.stderr:write(rt.time_text(sh, real, cpu, 0, st.timed_p))
		if not ok then
			error(err)
		end
		return
	end
	-- set -n (noexec): a non-interactive shell reads but does not execute. Once on,
	-- every later statement (including `set +n`) is skipped — matches bash.
	if sh.opt_n and not sh.opt_i then
		sh.status = 0
		return
	end
	-- DEBUG fires before each command, INCLUDING inside ERR/RETURN/signal/EXIT trap
	-- handlers (bash) — only the DEBUG handler itself suppresses it (run_debug's
	-- in_debug guard). Inside any trap the reported line is the frozen (trapped) one.
	if DEBUG_FIRE[t] then
		-- a command's own prefix assignment (run through here by its simple command) is
		-- part of that command: no DEBUG of its own, and $BASH_COMMAND stays the command
		local cc, own = sh.cur_cmd, false
		if t == "assign" and cc and cc.assigns then
			for _, a in ipairs(cc.assigns) do
				own = own or a == st
			end
		end
		if not own then
			if not (sh.in_trap and sh.in_trap > 0) then
				sh.cur_cmd = st -- $BASH_COMMAND (a trap's own commands don't replace it)
			end
			if run_debug(sh, (sh.in_trap and sh.in_trap > 0) and sh.cur_line or st.line) then
				return -- extdebug: the DEBUG trap said skip it
			end
		end
	end
	-- redirs trailing a compound command: apply around the whole thing, then run it
	-- with redirs temporarily detached (so this guard doesn't re-fire).
	if st.redirs and COMPOUND_REDIR[t] then
		local rd = st.redirs
		local pnp, pnf = procsub_mark(sh) -- a >() redirect target drains after the whole command
		local save, ok = apply_redirs(sh, rd)
		if not ok then
			sh.status = 1
			restore_redirs(save)
			-- a failed redirect on a compound fires the ERR trap (and, under errexit,
			-- exits) — bash; the body never ran, so nothing else fires it.
			if sh.noerr == 0 then
				fire_err(sh)
			end
			return
		end
		local savedout = sh.out
		if redirs_touch_stdout(rd) then
			sh.out = io.write
		end
		-- an async command inside keeps this stdin instead of /dev/null (bash's stdin_redir)
		local inr = rt.redirs_stdin(rd)
		if inr then
			sh.stdin_redir = (sh.stdin_redir or 0) + 1
		end
		st.redirs = nil
		local pok, err = pcall(exec_stmt, sh, st, hook)
		if inr then
			sh.stdin_redir = sh.stdin_redir - 1
		end
		st.redirs = rd
		io.flush()
		sh.out = savedout
		restore_redirs(save)
		drain_procsub(sh, pnp, pnf) -- a >() redirect target on a compound command runs after it
		if not pok then
			error(err)
		end
		return
	end
	if st.line and not (sh.in_trap and sh.in_trap > 0 and (sh.calldepth or 0) == sh.trap_calldepth) then
		sh.cur_line = st.line
		sh.cur_cline = st.cline or st.line -- (where its $(…) bodies number from)
	end -- $LINENO: frozen at the trapped line for the trap's own commands (not in a
	-- function the trap calls, whose lines count as usual — bash)
	if t == "assign" then
		if st.name == "SHELLOPTS" or st.name == "BASHOPTS" then -- readonly specials (bash)
			io.stderr:write("curse: " .. st.name .. ": readonly variable\n")
			sh.status = 1
			if sh.opt_c or sh.opt_posix then
				error({ __curse_exit = 1 })
			end
			return
		end
		if st.index == "" then -- `a[]=v`: empty subscript is a bad array subscript (bash: status 1, no assign)
			io.stderr:write("curse: `" .. st.name .. "[]': bad array subscript\n")
			sh.status = 1
			return
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
					sh.status = 1
					return
				end
				nref_base, nref_sub = nb.s:match("^([%a_][%w_]*)%[(.+)%]$")
			end
		end
		-- `ref[i]=` where ref is a nameref TO a subscripted element (`a[0]`) would be
		-- `a[0][i]` — not a valid identifier (bash: status 1, no assign).
		if st.index then
			local nb = sh.vars[st.name]
			if nb and nb.ref and nb.s and nb.s:match("^[%a_][%w_]*%[.+%]$") then
				io.stderr:write("curse: `" .. nb.s .. "': not a valid identifier\n")
				sh.status = 1
				return
			end
		end
		if rb and rb.ro then -- readonly: reject the assignment (status 1); fatal in `sh -c`
			io.stderr:write("curse: " .. st.name .. ": readonly variable\n") -- or posix mode.
			sh.status = 1
			if sh.opt_c or sh.opt_posix then
				error({ __curse_exit = 1 })
			end
			-- A readonly command PREFIX (`abc=def echo one`) is non-fatal: bash still runs
			-- the command. But a STANDALONE readonly assignment (`readonly x=1; x=2; echo
			-- hi`) aborts the REST of the line, then the next line runs.
			if sh.applying_prefix then
				return
			end
			error({ __curse_exit = 1, __curse_lineabort = true })
		else
			-- A bad substitution / invalid indirect in the RHS fails the assignment but is
			-- NON-fatal (bash: `x=${bad|y}` leaves x unset, status 1, script continues) —
			-- like a bad-subst in a command word. Catch it around the RHS expansion.
			local aok, aerr = pcall(function()
				if nref_base then
					sh:array_set(
						nref_base,
						array_key(sh, nref_base, nref_sub),
						expand_assign_word(sh, st.rhs),
						st.append
					)
				elseif st.index then
					if
						not sh:array_set(
							st.name,
							array_key(sh, st.name, st.index),
							expand_assign_word(sh, st.rhs),
							st.append
						)
					then
						error({ __curse_badsub = true })
					end
				elseif st.arith then
					sh:aset(st.name, eval(sh, st.arith))
				elseif st.append then
					local b = sh.vars[sh:deref(st.name)]
					if b and b.arr then -- `name+=value` on an array appends to element 0 (bash)
						sh:array_set(st.name, array_key(sh, st.name, "0"), expand_assign_word(sh, st.rhs), true)
					elseif b and b.int then -- integer var: += is arithmetic addition (the old value
						-- is itself evaluated: `b=4+1; typeset -i b; b+=37` is 42 — bash)
						sh:aset(st.name, rt.arith_str(sh, sh:get(st.name)) + eval(sh, P.arith(expand_word(sh, st.rhs))))
					elseif b and (b.lower or b.upper) then -- declare -l/-u: case-fold the appended result
						local v = sh:get(st.name) .. expand_assign_word(sh, st.rhs)
						sh:set_str(st.name, b.lower and v:lower() or v:upper())
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
					io.stderr:write("curse: " .. st.name .. ": bad array subscript\n")
					sh.status = 1
					sh.assign_err = true
					return
				elseif type(aerr) == "table" and aerr.__curse_experr then
					sh.status = 1
					sh.assign_err = true
					return -- bad-subst RHS: non-fatal
				else
					error(aerr)
				end -- a real error (exit, nounset, matherr) propagates
			end
		end
		-- set -x: trace the assignment with its expanded value (`+ x=5`, `+ a[1]=v`)
		if sh.opt_x and not st.append then
			local v
			if st.index then
				v = sh:get(st.name .. "[" .. st.index .. "]") or ""
			else
				v = sh:get(st.name) or ""
			end
			xtrace(sh, { (st.index and (st.name .. "[" .. st.index .. "]") or st.name) .. "=" .. (v == "" and "" or xtrace_quote(v)) }, true)
		end
		-- set -a (allexport): a plain scalar assignment auto-exports the variable
		if sh.opt_a and not st.index then
			local b = sh.vars[sh:deref(st.name)]
			if b and not b.arr then
				b.exported = true
				C.setenv(st.name, sh:get(st.name), 1)
			end
		end
		-- HISTSIZE shrinks the in-memory history; HISTFILESIZE truncates $HISTFILE —
		-- both to the last N entries, on assignment (bash).
		if not st.index and (st.name == "HISTSIZE" or st.name == "HISTFILESIZE") then
			local nsz = tonumber(sh:get(st.name))
			if nsz and nsz >= 0 then
				if st.name == "HISTSIZE" and sh.history then
					while #sh.history > nsz do
						table.remove(sh.history, 1)
					end
				elseif st.name == "HISTFILESIZE" then
					local hf = sh:get("HISTFILE")
					if hf and hf ~= "" then
						local lines, f = {}, io.open(hf, "r")
						if f then
							for l in f:lines() do
								lines[#lines + 1] = l
							end
							f:close()
						end
						if #lines > nsz then
							local o = io.open(hf, "w")
							if o then
								for k = #lines - nsz + 1, #lines do
									o:write(lines[k], "\n")
								end
								o:close()
							end
						end
					end
				end
			end
		end
		-- exit status of an assignment = the last command substitution's, else 0
		-- (skip when it was a rejected readonly assignment, which already set status 1)
		if not (rb and rb.ro) then
			local hascs = false
			if st.rhs then
				for _, p in ipairs(st.rhs.parts) do
					if p.cmdsub then
						hascs = true
						break
					end
				end
			end
			if not hascs then
				sh.status = 0
			end
		end
		sh:set_str("_", "") -- a bare assignment resets $_ to empty (bash)
	elseif t == "arrayassign" then
		local rb = sh.vars[sh:deref(st.name)]
		local nb = sh.vars[st.name]
		if nb and nb.ref and nb.s and nb.s:find("[", 1, true) then
			-- a nameref to an element/`a[@]`: an array literal can't be written through it
			io.stderr:write("curse: `" .. nb.s .. "': not a valid identifier\n")
			sh.status = 1
		elseif st.index then -- `a[0]=(1 2)`: can't assign a list to an array MEMBER (bash)
			io.stderr:write("curse: " .. st.name .. "[" .. st.index .. "]: cannot assign list to array member\n")
			sh.status = 1
		elseif rb and rb.ro then -- readonly array: reject the (re)assignment
			io.stderr:write("curse: " .. st.name .. ": readonly variable\n")
			sh.status = 1
		else
			-- a failglob no-match inside `a=(*.ZZ)` fails the assignment non-fatally (bash)
			local aok, aerr = pcall(do_arrayassign, sh, st)
			if aok then
				sh.status = 0
				sh:set_str("_", "")
			elseif type(aerr) == "table" and aerr.__curse_experr then
				sh.status = 1
				if sh.opt_e then
					error({ __curse_exit = 1 })
				end
			else
				error(aerr)
			end
		end
	elseif t == "funcdef" then
		-- a funcdef whose name is an expansion (`$foo-bar()`) is a NON-fatal runtime
		-- error (bash: status 1) — the name was captured raw by the parser. bash is
		-- otherwise lenient (a literal `=` in the name is fine: `func-name=ext`).
		if not st.name:match("^[%w_:%.+@/%%%^~,][%w_%.%-:+@/!#=%%%^~,]*$") then
			io.stderr:write("curse: `" .. st.name .. "': not a valid identifier\n")
			sh.status = 1
			return
		end
		if sh.fn_ro and sh.fn_ro[st.name] then -- `readonly -f`: can't be redefined
			io.stderr:write("curse: " .. st.name .. ": readonly function\n")
			sh.status = 1
			return
		end
		if sh.opt_posix and SPECIAL_BUILTIN[st.name] then -- posix: can't shadow a special builtin
			io.stderr:write("curse: `" .. st.name .. "': is a special builtin\n")
			sh.status = 2
			error({ __curse_exit = 2 }) -- fatal (bash aborts)
		end
		sh.functions[st.name] = st.body
		sh.func_redirs = sh.func_redirs or {}
		sh.func_redirs[st.name] = st.redirs -- `f(){ … } >&2`
		sh.func_src = sh.func_src or {}
		sh.func_src[st.name] = nil -- printed text: deparsed from the definition on demand
		sh.func_def = sh.func_def or {}
		sh.func_def[st.name] = st
		if sh.fexport and sh.fexport[st.name] then
			rt.fexport_sync(sh, st.name) -- a redefinition re-exports the new body
		end
		-- definition site for `declare -F` under extdebug (name line file)
		sh.func_line = sh.func_line or {}
		sh.func_line[st.name] = st.line
		sh.func_bline = sh.func_bline or {}
		sh.func_bline[st.name] = st.bline
		sh.func_file = sh.func_file or {}
		sh.func_file[st.name] = sh.cur_source or sh.argv0 or ""
		sh.status = 0
	elseif t == "assignlist" then
		-- a bad array subscript / bad-subst in one binding aborts the REST of the list
		-- (bash: `a=x b[0+]=y c=z` sets only a), keeping the error status.
		for _, a in ipairs(st.list) do
			sh.assign_err = nil
			exec_stmt(sh, a, hook)
			if sh.assign_err then
				return
			end
		end
		sh.status = 0
	elseif t == "simple" then
		if sh.coprocs and next(sh.coprocs) then
			rt.coproc_poll(sh) -- a coproc that finished is reaped now (bash: on SIGCHLD)
		end
		local pnp, pnf = procsub_mark(sh) -- drain only <()/>() this command registers
		-- Alias expansion is done in the PARSER (a source-deterministic in-context
		-- splice — see make_parser), so the tree reaching here is already expanded and
		-- exec just runs it; the interpreter and the compiler stay in agreement.
		-- `name=value` arguments to a declaration builtin (ASSIGN_CMD, module-level)
		-- are ASSIGNMENT words: the value isn't word-split or globbed.
		-- Assignment-word treatment applies only when the command name is a STATIC
		-- (literal, unquoted) declaration builtin — `typeset x=$x` splits, but
		-- `cmd=typeset; $cmd x=$x` does NOT (bash: the name must be recognized before
		-- expansion). Detected from the pre-expansion first word, not the expanded one.
		local cw1 = st.words[1]
		local cw1lit = cw1 and #cw1.parts == 1 and cw1.parts[1].lit ~= nil and not cw1.parts[1].q and cw1.parts[1].lit
			or nil
		local is_assign = cw1lit ~= nil and ASSIGN_CMD[cw1lit] ~= nil
		local args = {}
		-- A word-expansion error (bad substitution, invalid indirect name) aborts the
		-- WHOLE simple command with status 1 but is non-fatal: the script continues.
		local eok, eerr = pcall(expand_args, sh, st, args, is_assign)
		if not eok then
			if type(eerr) == "table" and eerr.__curse_experr then
				sh.status = 1
				if sh.opt_e then
					error({ __curse_exit = 1 })
				end
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
					-- NAME=(…) is a literal only as a command PREFIX; with no command left after
					-- expansion (`a=(1 2) 2>/dev/null`, `a=(x) $empty`) it's an array assignment
					exec_stmt(sh, a, hook)
				end
			else -- a bare $(...) / redirection: status is the last cmdsub's, else 0
				local hadcs = false
				for _, w in ipairs(st.words) do
					for _, p in ipairs(w.parts) do
						if p.cmdsub then
							hadcs = true
							break
						end
					end
				end
				sh.status = hadcs and (sh.last_cmdsub_status or 0) or 0
			end
			-- a redirection with no command still opens/truncates its target (`> file`)
			if st.redirs then
				local save, ok = apply_redirs(sh, st.redirs)
				if not ok then
					sh.status = 1
				end
				restore_redirs(save)
			end
			return
		end
		if st.arrayargs then -- `declare -A a=(...)` / `local -a b=(...)` array literals
			-- Only append the names now (so `declare -A a=(...)` isn't seen as a bare
			-- listing and so `local`/`declare` establishes the scope + attributes). The
			-- actual array assignment happens AFTER the builtin runs (below), so it lands
			-- in the freshly-declared/local variable.
			local wasro -- (a name ALREADY readonly: its literal isn't assigned, bash errors)
			for _, aa in ipairs(st.arrayargs) do
				args[#args + 1] = aa.name
				local b = sh.vars[sh:deref(aa.name)]
				if b and b.ro and args[1] ~= "local" then
					wasro = wasro or {}
					wasro[aa] = true
				end
			end
			sh.arrayargs_ro = wasro
		end
		-- `exec [redirs] [cmd…]`: redirections are permanent (not restored). With no
		-- command it just rewires the shell's own fds (e.g. `exec 3>file`); with a
		-- command it replaces the shell process with that command.
		while (args[1] == "command" or args[1] == "builtin") and args[2] == "exec" and not sh.functions[args[1]] do
			table.remove(args, 1) -- `command exec 2>f`: still exec, its redirections persist
		end
		if args[1] == "exec" then
			-- in an in-process subshell/$(…) the fds/process image are process-global: become
			-- a real child first (rt.need_process) unless a function shadows `exec`
			if not sh.functions.exec and sh.iso_ctx and sh.iso_ctx[1] then
				rt.need_process(sh)
			end
			io.flush()
			local ok = true
			if st.redirs then
				_, ok = apply_redirs(sh, st.redirs)
				if sh.coprocs then
					rt.coproc_fdcheck(sh) -- a coproc end it closed/moved reads as -1
				end
			end
			-- exec [-cl] [-a name] [--] [cmd…]: -c empty environment, -l login ($0 gets a
			-- leading -), -a NAME as $0. Another option is a usage error (status 2).
			local k, argv0, cflag, lflag = 2, nil, false, false
			while args[k] and args[k]:sub(1, 1) == "-" and args[k] ~= "-" do
				local a = args[k]
				k = k + 1
				if a == "--" then
					break
				end
				local j = 2
				while j <= #a do
					local f = a:sub(j, j)
					if f == "c" then
						cflag = true
					elseif f == "l" then
						lflag = true
					elseif f == "a" then
						if j < #a then
							argv0 = a:sub(j + 1)
						else
							argv0 = args[k]
							k = k + 1
						end
						break
					else
						io.stderr:write("curse: exec: -" .. f .. ": invalid option\n")
						io.stderr:write("exec: usage: exec [-cl] [-a name] [command [argument ...]] [redirection ...]\n")
						sh.status = 2
						return
					end
					j = j + 1
				end
			end
			if k <= #args and rt.restricted(sh, "exec: restricted") then
				return
			end
			if k <= #args then
				local rest = { unpack(args, k) }
				if lflag then
					argv0 = "-" .. (argv0 or rest[1]:match("[^/]*$"))
				end
				if argv0 then
					sh.exec_argv0 = argv0
				end -- exec -a NAME: override the child's argv[0]
				if cflag then
					C.clearenv()
					sh.exec_noenv = true -- (not even `_`)
				end
				if st.assigns then -- prefix bindings become the exec'd command's environment (bash)
					for _, a in ipairs(st.assigns) do
						if a.raw then
							sh:set_str(a.name, a.raw)
							C.setenv(a.name, a.raw, 1)
						else
							exec_stmt(sh, a, hook)
							if not a.index then
								C.setenv(a.name, sh:get(a.name), 1)
							end
						end
					end
				end
				exec_simple(sh, rest, hook)
				io.flush()
				-- the command REPLACES the shell: end with its status, no EXIT trap (bash). Not
				-- os.exit — in the daemon that would kill the worker before it replies.
				error({ __curse_exit = sh.status or 0, __curse_noexittrap = true })
			else
				sh.status = ok and 0 or 1
			end
			return
		end
		local tenv_base -- set while this command's prefix bindings sit on sh.tenv
		local function run_cmd()
			sh.write_err = nil -- a builtin sets this on an output write error (e.g. full disk)
			-- `set -x` trace: BEFORE the command's own redirects, so `cmd 2>file` doesn't
			-- capture the trace (bash writes it to the shell's stderr).
			if sh.opt_x and args[1] ~= nil then
				xtrace(sh, args)
			end
			if st.redirs then
				local save, ok
				if tenv_base and #sh.tenv > tenv_base then
					-- the redirections don't see the command's own prefix bindings (bash:
					-- `a=2 cmd >&$a` uses the outer a) — unshadow them while they expand
					local shadow = {}
					for k = #sh.tenv, tenv_base + 1, -1 do
						local te = sh.tenv[k]
						shadow[#shadow + 1] = { te.name, sh.vars[te.name] }
						sh.vars[te.name] = te.box or nil
					end
					local rok, a1, a2 = pcall(apply_redirs, sh, st.redirs)
					for i = #shadow, 1, -1 do
						sh.vars[shadow[i][1]] = shadow[i][2]
					end
					if not rok then
						error(a1)
					end
					save, ok = a1, a2
				else
					save, ok = apply_redirs(sh, st.redirs)
				end
				if not ok then
					sh.status = 1
					restore_redirs(save) -- open failed: skip the command
				else
					-- Only route builtin/captured output to the real fd 1 when a redirect
					-- actually targets stdout; a stdin-only redirect (heredoc, `<`) must not
					-- steal fd-1 output away from a $(...) capture buffer.
					local savedout = sh.out
					if redirs_touch_stdout(st.redirs) then
						sh.out = io.write
					end
					local pok, err = pcall(exec_simple, sh, args, hook)
					io.flush()
					sh.out = savedout
					restore_redirs(save)
					if pok and sh.write_err then
						sh.status = 1
					end -- builtin hit a write error
					if not pok then
						error(err)
					end
				end
			else
				exec_simple(sh, args, hook)
				if sh.write_err then
					sh.status = 1
				end -- builtin hit a write error (e.g. full disk)
			end
		end
		if st.assigns and sh.opt_posix and args[1] and SPECIAL_BUILTIN[args[1]] then
			-- POSIX (bash under `set -o posix`): a variable assignment prefixed to a
			-- SPECIAL builtin (`:`, `.`, eval, export, readonly, set, shift, trap,
			-- unset, …) PERSISTS in the shell — and, being a command prefix, stays
			-- EXPORTED (`foo=bar readonly …` then `printenv foo` -> bar; `x=tmp :`
			-- leaves x=tmp in the environment).
			-- EXCEPTION, per variable: if the builtin is `unset` and it removes a var we
			-- just assigned, that var REVERTS to its prior value rather than persisting
			-- (`a=A x=tmp unset x` → a=A, x=<prior>); other assigns still persist.
			local prior = {}
			for _, a in ipairs(st.assigns) do
				if prior[a.name] == nil then
					local b = sh.vars[a.name]
					prior[a.name] = b
							and {
								s = b.s,
								n = b.n,
								arr = b.arr,
								assoc = b.assoc,
								order = b.order,
								exported = b.exported,
								ro = b.ro,
								ref = b.ref,
							}
						or false
				end
			end
			for _, a in ipairs(st.assigns) do
				-- it propagates through any temporary binding of the name (`var=30 f` where
				-- f does `var=20 return`): that binding's end mustn't restore the old value
				for _, te in ipairs(sh.tenv) do
					if te.name == a.name then
						te.consumed = true
					end
				end
				if a.raw then
					sh:set_str(a.name, a.raw)
				else
					sh.applying_prefix = true
					exec_stmt(sh, a, hook)
					sh.applying_prefix = nil
				end
				if not a.index then -- a scalar command prefix stays exported (bash)
					local b = sh.vars[sh:deref(a.name)]
					if b then
						b.exported = true
					end
					C.setenv(a.name, sh:get(a.name), 1)
				end
			end
			run_cmd()
			for name, box in pairs(prior) do
				if sh.vars[name] == nil then
					sh.vars[name] = box or nil
				end -- unset → revert
			end
		elseif st.assigns then
			-- prefix assignments: apply as a temporary, EXPORTED env for this command
			-- only, then restore (both the shell var and the process env). Each binding
			-- is pushed onto sh.tenv (LIFO) so an `unset` inside the command reveals the
			-- shadowed value beneath instead of leaving the name unset (bash dynamic
			-- scope); a consumed entry is skipped on restore.
			local base = #sh.tenv
			for _, a in ipairs(st.assigns) do
				if a.index then
					-- An array-element assignment (`a[i]=v cmd`) is NOT a valid command-prefix
					-- binding: bash prints "not a valid identifier" and does NOT apply it (the
					-- command still runs, non-fatal). Skip it entirely — no tenv, no mutation.
					io.stderr:write("curse: `" .. a.name .. "[" .. tostring(a.index) .. "]': not a valid identifier\n")
				else
					local b = sh.vars[a.name] -- COPY the box: exec_stmt mutates it in place
					sh.vseq = sh.vseq + 1
					sh.tenv[#sh.tenv + 1] = {
						name = a.name,
						env = os.getenv(a.name),
						consumed = false,
						seq = sh.vseq,
						box = b and {
							s = b.s,
							n = b.n,
							arr = b.arr,
							assoc = b.assoc,
							order = b.order,
							exported = b.exported,
							ro = b.ro,
							ref = b.ref,
						} or false,
					}
					if a.raw then -- NAME=(…) as a command prefix is a literal string, not an array (bash)
						sh:set_str(a.name, a.raw)
						C.setenv(a.name, a.raw, 1)
					else
						sh.applying_prefix = true
						exec_stmt(sh, a, hook)
						sh.applying_prefix = nil
						C.setenv(a.name, sh:get(a.name), 1)
					end
				end
			end
			-- mark these entries so a DIRECT function call (not `eval`/a builtin) can tag
			-- them with its frame: `local x` absorbs only its OWN call's tempenv.
			sh.tenv_call_base = base
			tenv_base = base
			local ok, err = pcall(run_cmd)
			tenv_base = nil
			sh.tenv_call_base = nil
			local relocale = false
			for k = #sh.tenv, base + 1, -1 do
				local s = sh.tenv[k]
				sh.tenv[k] = nil
				if not s.consumed then -- an `unset` inside the command already revealed it
					sh.vars[s.name] = s.box or nil
					if s.env then
						C.setenv(s.name, s.env, 1)
					else
						C.unsetenv(s.name)
					end
					relocale = relocale or s.name == "LANG" or s.name:sub(1, 3) == "LC_"
				end
			end
			if relocale then -- (`LANG=C cmd`: the locale follows the variable back)
				rt.reset_locale(sh)
			end
			if not ok then
				error(err)
			end
		else
			run_cmd()
		end
		-- Array literals for a declaration builtin are assigned AFTER it runs, so a
		-- `local a=(…)` / `declare -A a=(…)` lands in the now-local/assoc variable.
		-- Skip when the builtin failed (e.g. a rejected -A/-a type change): the array
		-- must stay untouched, not be mangled by the literal.
		if st.arrayargs and sh.status == 0 then
			local wasro = sh.arrayargs_ro
			sh.arrayargs_ro = nil
			for _, aa in ipairs(st.arrayargs) do
				if wasro and wasro[aa] then
					io.stderr:write("curse: " .. aa.name .. ": readonly variable\n")
					sh.status = 1
				else
					do_arrayassign(sh, aa)
				end
			end
		end
		-- $_ : the last argument (after expansion) of the command just run.
		if #args > 0 then
			sh:set_str("_", args[#args])
		end
		-- PIPESTATUS for a simple command is a one-element array of its exit status.
		sh:array_assign("PIPESTATUS", { tostring(sh.status) }, false)
		drain_procsub(sh, pnp, pnf) -- feed >() temps, clean up <()/>() temp files
	elseif t == "forc" then
		-- DEBUG fires (at the `for` line) before the init, before EACH condition
		-- evaluation, and before EACH step — bash's `[6][6][7]…` per-iteration pattern.
		local function fdbg()
			run_debug(sh, (sh.in_trap and sh.in_trap > 0) and sh.cur_line or st.line)
		end
		-- A slot whose arith failed to parse (`i='3'`) was deferred: bash reports the
		-- error at RUNTIME and runs the loop zero (or partial) iterations, non-fatally.
		local function ev(node, slot)
			sh.cur_line = st.line -- $LINENO inside the for(( init/cond/step is the `for` line (bash),
			-- not whatever line the body last ran (the cond re-evals per iteration)
			if sh.opt_x and st.src then
				arith_trace(sh, (st.src[slot]:match("^%s*(.-)%s*$")))
			end
			if node.k == "arith_perr" then
				io.stderr:write("curse: " .. (node.raw:match("^%s*(.-)%s*$")) .. ": syntax error in expression\n")
				error({ __curse_exit = 1, __curse_experr = true })
			end
			return eval(sh, node)
		end
		local bodystatus = 0 -- a loop's status is its last body command's (0 if none)
		sh.loopdepth = (sh.loopdepth or 0) + 1
		local cok, cerr = pcall(function()
			if st.init then
				fdbg()
				ev(st.init, 1)
			end
			while true do
				hook("loop", st.id)
				if st.cond then
					fdbg()
					if not truth(ev(st.cond, 2)) then
						break
					end
				end
				local act = run_loop_body(sh, st.body, hook)
				bodystatus = sh.status
				if act == "break" then
					break
				end
				if st.step then
					fdbg()
					ev(st.step, 3)
				end -- continue still runs the step
			end
		end)
		sh.loopdepth = sh.loopdepth - 1
		if not cok then
			if type(cerr) == "table" and cerr.__curse_experr then
				sh.status = 1
				if sh.opt_e then
					error({ __curse_exit = 1 })
				end
			else
				error(cerr)
			end
		else
			sh.status = bodystatus
		end
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
				if type(cerr) == "table" and cerr.__curse_break then
					break
				elseif type(cerr) == "table" and cerr.__curse_continue then -- fallthrough to re-test
				else
					sh.loopdepth = sh.loopdepth - 1
					error(cerr)
				end
			end
			local go = (sh.status == 0)
			if st.negate then
				go = not go
			end -- until
			if not go then
				break
			end
			local act = run_loop_body(sh, st.body, hook)
			bodystatus = sh.status
			if act == "break" then
				break
			end
		end
		sh.loopdepth = sh.loopdepth - 1
		sh.status = bodystatus
	elseif t == "warn" then -- a parse-time warning (heredoc at EOF, …), shown before its line runs
		sh.cur_line = st.line
		io.stderr:write("curse: " .. st.msg .. "\n")
	elseif t == "parse_error" then
		for _, w in ipairs(st.warns or {}) do
			sh.cur_line = w.line
			io.stderr:write("curse: " .. w.msg .. "\n")
		end
		-- A RECOVERABLE parse error (an invalid `NAME=( … )` array-literal element) is
		-- reported but NON-fatal: the assignment is dropped and the script continues
		-- (bash). This matches run_lazy's handling, so the compiled path (which reaches
		-- a parse_error via delegation) behaves the same as the interpreter.
		if st.recoverable then
			io.stderr:write("curse: " .. (st.msg or "syntax error") .. "\n")
			sh.status = 1
		else
			-- Reached the unparseable tail (e.g. a makeself binary payload) — bash would
			-- syntax-error here too. If an earlier exit fired, we never get here.
			-- bash's form: `syntax error near unexpected token `X'` (or `syntax error:
			-- unexpected end of file`), then the offending line as `…'
			local msg = tostring(st.msg or "syntax error"):gsub("^.-:%d+: ", "")
			msg = msg:gsub("^syntax error near `", "syntax error near unexpected token `")
			if not msg:find("^syntax error") and not msg:find("^unexpected EOF") then
				msg = "syntax error: " .. msg
			end
			if st.line then
				sh.cur_line = st.line
			end
			io.stderr:write("curse: " .. msg .. "\n")
			if st.text and msg:find("near unexpected token", 1, true) then
				io.stderr:write("curse: `" .. st.text .. "'\n")
			end
			error({ __curse_exit = 2, __curse_parseerr = true })
		end
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
		if cap then
			pfd = ffi.new("int[2]")
			if rt.pipe_hi(pfd) ~= 0 then
				cap = false
			end
		end
		local pid = rt.fork()
		if pid == 0 then
			if cap then
				C.close(pfd[0])
				C.dup2(pfd[1], 1)
				C.close(pfd[1])
			end
			reset_child_sigtraps(sh) -- caught signal traps revert to default in a subshell
			sh.in_subprogram = (sh.in_subprogram or 0) + 1 -- ERR trap won't fire here (sans errtrace)
			sh.loopdepth = 0 -- a loop enclosing this subshell isn't ours to break/continue
			local ok, err = pcall(function()
				if st.redirs then
					apply_redirs(sh, st.redirs)
				end
				sh.out = io.write
				exec_list(sh, st.body, hook, false)
			end)
			-- Tiered handoff INSIDE the child: the compiled artifact is ready, so this
			-- child OSRs into its OWN bounded fragment (the subshell's compiled sub-CFG,
			-- which _exits at the boundary) instead of interpreting the rest. The child
			-- honors interp/bg-compile/OSR like any code — it just jumps to the right pc.
			if not ok and type(err) == "table" and err.__curse_switch then
				err.osr()
			end
			child_status(sh, ok, err)
			rt.child_exit(sh, sh.status or 0) -- its own EXIT trap, flush, _exit
		end
		if cap then -- parent: drain the child's stdout into the capture buffer, then reap
			C.close(pfd[1])
			local rbuf = ffi.new("char[8192]")
			while true do
				rt.co_block(pfd[0], 1)
				local nr = tonumber(C.read(pfd[0], rbuf, 8192))
				if not nr or nr <= 0 then
					break
				end
				sh.out(ffi.string(rbuf, nr))
			end
			C.close(pfd[0])
		end
		local stbuf = ffi.new("int[1]")
		rt.wait_child(pid, stbuf, 0)
		sh.status = rt.wexit(stbuf[0])
	elseif t == "background" then
		-- cmd & : fork, run in the child; parent records $! and continues (status 0).
		rt.need_process(sh) -- in an in-process subshell, the job must be the subshell's child
		io.flush()
		-- Block signals across the fork + the child's disposition reset so an immediate
		-- `kill -SIG $!` can't be delivered to the child before it clears its traps (bash).
		C.curse_sig_hold(1)
		local pid = rt.fork()
		if pid == 0 then
			-- Without job control, an async command's stdin is /dev/null (bash), so it
			-- can't steal the terminal — and it must not inherit a redirect it didn't ask for.
			-- (unless an enclosing command redirected stdin: then the job reads that — bash)
			local dn = (sh.stdin_redir or 0) == 0 and C.open("/dev/null", 0, 0) or -1
			if dn >= 0 then
				C.dup2(dn, 0)
				C.close(dn)
			end
			reset_child_sigtraps(sh) -- caught signal traps revert to default in the async subshell
			C.curse_sig_hold(0) -- dispositions set: safe to receive signals now
			sh.in_subprogram = (sh.in_subprogram or 0) + 1 -- async subprogram: ERR trap won't fire (sans errtrace)
			sh.loopdepth = 0
			local ok, err = pcall(function()
				sh.out = io.write
				exec_stmt(sh, st.cmd, hook)
			end)
			child_status(sh, ok, err)
			rt.child_exit(sh, sh.status or 0) -- its own EXIT trap, flush, _exit
		end
		C.curse_sig_hold(0) -- parent: unblock
		-- register the job (for `jobs`/`wait %spec`/`wait -n`); best-effort command text
		local c1 = st.cmd
		while c1 and (c1.t == "pipeline") and c1.cmds do
			c1 = c1.cmds[1]
		end
		local cmdstr = st.text or (c1 and c1.words and c1.words[1] and c1.words[1].parts[1] and c1.words[1].parts[1].lit) or "job"
		job_add(sh, pid, cmdstr)
		sh.bg_pids = sh.bg_pids or {}
		sh.bg_pids[#sh.bg_pids + 1] = pid
		sh.status = 0
	elseif t == "coproc" then
		-- coproc NAME cmd: run cmd asynchronously with its stdin/stdout on two pipes whose
		-- other ends the shell keeps as NAME=(read-fd write-fd); NAME_PID and $! = its pid.
		rt.need_process(sh)
		sh.coprocs = sh.coprocs or {}
		for opid, cp in pairs(sh.coprocs) do -- (bash: one at a time is supported; warn, go on)
			io.stderr:write(("curse: warning: execute_coproc: coproc [%d:%s] still exists\n"):format(opid, cp.name))
		end
		io.flush()
		local rp, wp = ffi.new("int[2]"), ffi.new("int[2]")
		C.pipe(rp)
		C.pipe(wp)
		local r0, r1 = rt.fd_below(rp[0], 64), rt.fd_below(rp[1], 64)
		local w0, w1 = rt.fd_below(wp[0], 64), rt.fd_below(wp[1], 64)
		C.curse_sig_hold(1)
		local pid = rt.fork()
		if pid == 0 then
			C.dup2(w0, 0)
			C.dup2(r1, 1)
			for _, fd in ipairs({ r0, r1, w0, w1 }) do
				C.close(fd)
			end
			for _, cp in pairs(sh.coprocs) do -- (an older coproc's ends aren't this one's)
				C.close(cp.r)
				C.close(cp.w)
			end
			sh.coprocs = nil
			reset_child_sigtraps(sh)
			C.curse_sig_hold(0)
			sh.in_subprogram = (sh.in_subprogram or 0) + 1
			sh.loopdepth = 0
			local ok, err = pcall(function()
				sh.out = io.write
				exec_stmt(sh, st.cmd, hook)
			end)
			child_status(sh, ok, err)
			rt.child_exit(sh, sh.status or 0)
		end
		C.curse_sig_hold(0)
		C.close(r1)
		C.close(w0)
		C.fcntl(r0, 2, 1) -- F_SETFD FD_CLOEXEC: nothing the shell runs inherits these
		C.fcntl(w1, 2, 1)
		sh:array_assign(st.name, { tostring(r0), tostring(w1) }, false)
		sh:set_str(st.name .. "_PID", tostring(pid))
		sh.coprocs[pid] = { name = st.name, r = r0, w = w1 }
		job_add(sh, pid, "coproc " .. st.name)
		sh.bg_pids = sh.bg_pids or {}
		sh.bg_pids[#sh.bg_pids + 1] = pid
		sh.status = 0
	elseif t == "arithcmd" then
		-- A `(( expr ))` command (standalone or as an if/while condition) is NOT fatal
		-- on a division-by-zero — it just yields status 1 and execution continues
		-- (unlike a `$(( ))` word expansion, which aborts the command list).
		if sh.opt_x and st.src then
			arith_trace(sh, st.src)
		end
		local ok, v = pcall(eval, sh, st.expr)
		if ok then
			sh.status = truth(v) and 0 or 1
		elseif type(v) == "table" and v.__curse_matherr then
			sh.status = 1
		else
			error(v)
		end
	elseif t == "dbracket" then
		if st.expr and st.expr.kind == "syntaxerr" then -- malformed [[ ]]: fatal syntax error (bash aborts)
			io.stderr:write("curse: syntax error in conditional expression\n")
			sh.status = 2
			if not sh.opt_i then
				error({ __curse_exit = 2 })
			end
			return
		end
		-- like `(( ))`, a `[[ ]]` test is not fatal on an arith error in an operand
		-- (e.g. `[[ a =~ $((1/0)) ]]`): it yields status 1 and execution continues.
		local ok, v = pcall(eval_dbracket, sh, st.expr)
		if ok then
			sh.status = v and 0 or 1
		elseif type(v) == "table" and v.__curse_regexerr then
			sh.status = 2
		elseif type(v) == "table" and v.__curse_matherr then
			sh.status = 1
		else
			error(v)
		end
	elseif t == "case" then
		if sh.opt_x and st.subject.src then
			xtrace_line(sh, "case " .. st.subject.src .. " in") -- (as written: bash)
		end
		local subj = expand_word(sh, st.subject)
		local fall = false -- carrying a `;&` fall-through into the next clause
		sh.status = 0
		for _, cl in ipairs(st.clauses) do
			local matched = fall
			if not matched then
				for _, pat in ipairs(cl.pats) do
					local g = expand_pattern(sh, P.parse_word(pat)) -- vars resolved; quoted metachars literal
					if rt.glob_match(subj, g, sh.shopt.nocasematch and true or nil) then
						matched = true
						break
					end
				end
			end
			if matched then
				exec_list(sh, cl.body, hook, false)
				if cl.term == "fall" then
					fall = true -- ;& : run the next clause's body too
				elseif cl.term == "test" then
					fall = false -- ;;& : keep testing later patterns
				else
					break
				end -- ;; : done
			end
		end
	elseif t == "andor" then
		-- run each pipeline, short-circuiting on the running exit status
		local ran_last = false
		for k, it in ipairs(st.items) do
			local go
			if it.op == nil then
				go = true
			elseif it.op == "&&" then
				go = (sh.status == 0)
			else
				go = (sh.status ~= 0)
			end -- "||"
			if go then
				exec_stmt(sh, it.cmd, hook)
			end
			if k == #st.items then
				ran_last = go
			end
		end
		-- ERR/errexit apply to an &&/|| list only via its FINAL operand (bash exempts
		-- the earlier ones): fire if that operand ran and failed, outside a condition.
		if ran_last and sh.noerr == 0 and sh.status ~= 0 then
			fire_err(sh)
		end
	elseif t == "pipeline" and st.negate then
		-- `! pipeline`: with errexit ON, everything it runs ignores errexit (bash adds
		-- CMD_IGNORE_RETURN, like a condition), e.g. `! eval false`. With it OFF there's no
		-- ignoring, so a `set -e` inside a called function takes effect (bash quirk). Run it
		-- un-negated (noerr restored however it unwinds), then invert the status.
		local ign = sh.opt_e and 1 or 0
		sh.noerr = sh.noerr + ign
		local ok, err = pcall(exec_stmt, sh, setmetatable({ negate = false }, { __index = st }), hook)
		sh.noerr = sh.noerr - ign
		if not ok then
			error(err, 0)
		end
		sh.status = (sh.status == 0) and 1 or 0
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
			local lp_raise = nil
			for k = 1, nst do
				-- DEBUG fires before each stage IN THE PARENT (bash: a forked stage's child
				-- does NOT fire it), but only for a stage that is itself a DEBUG-firing node
				-- — a `{ }`/compound stage fires nothing (`{ …; } | cat` fires once, for cat).
				-- The lastpipe in-process stage fires via its own exec_stmt instead.
				if DEBUG_FIRE[cmds[k].t] and not (k == nst and lastpipe) then
					if not (sh.in_trap and sh.in_trap > 0) then
						sh.cur_cmd = cmds[k] -- $BASH_COMMAND: this stage
					end
					run_debug(sh, (sh.in_trap and sh.in_trap > 0) and sh.cur_line or (cmds[k].line or st.line))
				end
				local rd, wr = -1, -1
				if k < nst then
					local p = ffi.new("int[2]")
					rt.pipe_hi(p)
					rd, wr = p[0], p[1]
				end
				if k == nst and lastpipe then
					local save0 = rt.save_fd(0)
					if prev_read >= 0 then
						C.dup2(prev_read, 0)
						C.close(prev_read)
						prev_read = -1
					end
					local savedout = sh.out
					sh.out = io.write
					local ok, err = pcall(exec_stmt, sh, cmds[k], hook)
					io.flush()
					sh.out = savedout
					C.dup2(save0, 0)
					C.close(save0)
					if not ok and type(err) == "table" then
						sh.status = err.__curse_exit or err.__curse_return or sh.status
						if err.__curse_exit or err.__curse_return then
							lp_raise = err -- this stage IS the shell: re-raise once the others are reaped
						end
					elseif not ok then
						error(err)
					end
					inline_status = sh.status or 0
					pids[k] = -1
				elseif k == nst and sh.capturing then
					-- inside $(...): the last stage's stdout must land in the capture buffer,
					-- not the shell's real fd 1. Wire it to a pipe the parent drains into sh.out.
					local cp = ffi.new("int[2]")
					rt.pipe_hi(cp)
					local pid = rt.fork()
					if pid == 0 then
						reset_child_sigtraps(sh) -- caught signal traps revert to default in a pipeline stage
						sh.in_pipestage = (sh.in_pipestage or 0) + 1 -- a forked stage re-runs neither DEBUG nor ERR
						local ok, err = pcall(function()
							if prev_read >= 0 then
								C.dup2(prev_read, 0)
								C.close(prev_read)
							end
							C.dup2(cp[1], 1)
							C.close(cp[1])
							C.close(cp[0])
							sh.out = io.write
							exec_stmt(sh, cmds[k], hook)
						end)
						child_status(sh, ok, err)
						rt.child_exit(sh, sh.status or 0) -- its own EXIT trap, flush, _exit
					end
					pids[k] = pid
					if prev_read >= 0 then
						C.close(prev_read)
						prev_read = -1
					end
					C.close(cp[1]) -- parent keeps only the read end; drain to EOF before waitpid
					local chunks, rbuf = {}, ffi.new("char[65536]")
					while true do
						rt.co_block(cp[0], 1)
						local n = tonumber(C.read(cp[0], rbuf, 65536))
						if n <= 0 then
							break
						end
						chunks[#chunks + 1] = ffi.string(rbuf, n)
					end
					C.close(cp[0])
					sh.out(table.concat(chunks))
				else
					local pid = rt.fork()
					if pid == 0 then
						reset_child_sigtraps(sh) -- caught signal traps revert to default in a pipeline stage
						sh.in_pipestage = (sh.in_pipestage or 0) + 1 -- a forked stage re-runs neither DEBUG nor ERR
						local ok, err = pcall(function()
							if prev_read >= 0 then
								C.dup2(prev_read, 0)
								C.close(prev_read)
							end
							if wr >= 0 then
								C.dup2(wr, 1)
								C.close(wr)
							end
							if rd >= 0 then
								C.close(rd)
							end
							sh.out = io.write -- this stage writes to its fd 1 (the pipe / terminal)
							exec_stmt(sh, cmds[k], hook)
						end)
						child_status(sh, ok, err)
						rt.child_exit(sh, sh.status or 0) -- its own EXIT trap, flush, _exit
					end
					pids[k] = pid
					if prev_read >= 0 then
						C.close(prev_read)
					end
					if wr >= 0 then
						C.close(wr)
					end
					prev_read = rd
				end
			end
			if prev_read >= 0 then
				C.close(prev_read)
			end
			local stbuf = ffi.new("int[1]")
			local last, pipe, pstat = 0, 0, {}
			for k = 1, nst do
				local est
				if pids[k] == -1 then
					est = inline_status or 0 -- ran inline (lastpipe)
				else
					rt.wait_child(pids[k], stbuf, 0)
					est = rt.wexit(stbuf[0])
				end
				pstat[k] = tostring(est)
				if k == nst then
					last = est
				end
				if est ~= 0 then
					pipe = est
				end -- rightmost non-zero (for pipefail)
			end
			sh:array_assign("PIPESTATUS", pstat, false) -- ${PIPESTATUS[@]}
			sh.status = sh.opt_pipefail and pipe or last
			-- bash quirk (execute_cmd.c:720): the LAST stage of a pipeline, when it is a
			-- subshell `(…)` that failed, runs the ERR trap for that subshell — on top of
			-- the pipeline's own ERR fire — so `(false)|(false)` triggers ERR twice. It
			-- keys on the subshell's OWN failure (not the pipeline's `!`, which applies to
			-- the pipeline), so `! (false)|(false)` still fires it once. A group/simple
			-- last stage does not (only the pipeline fires).
			if cmds[nst] and cmds[nst].t == "subshell" and last ~= 0 and sh.noerr == 0 then
				fire_err_trap(sh)
			end
			if lp_raise then -- the lastpipe stage exited/returned: so does the shell/function
				error(lp_raise, 0)
			end
		end
	elseif t == "forin" then
		-- an invalid loop-variable name (`for i.j`/`for -`) is a NON-fatal runtime
		-- error (bash: status 1, no iterations), not a parse error.
		if not st.name:match("^[%a_][%w_]*$") then
			io.stderr:write("curse: `" .. st.name .. "': not a valid identifier\n")
			sh.status = 1
			return
		end
		-- expand the word list ONCE (bash semantics) and stash it in sh.forstate so
		-- a mid-loop OSR resumes the same list + index.
		local list = {}
		-- a failglob no-match while expanding the word list fails the `for` non-fatally
		-- (status 1, no iterations), like bash — not an abort.
		local eok, eerr = pcall(function()
			for _, w in ipairs(st.words) do
				local fs = expand_to_fields(sh, w)
				for k = 1, #fs do
					list[#list + 1] = fs[k]
				end
			end
		end)
		if not eok then
			if type(eerr) == "table" and eerr.__curse_experr then
				sh.status = 1
				if sh.opt_e then
					error({ __curse_exit = 1 })
				end
				return
			end
			error(eerr)
		end
		if rt.for_var_ro(sh, st.name) then
			return
		end
		sh.forstate[st.id] = { list = list, idx = 0 }
		local bodystatus = 0
		sh.loopdepth = (sh.loopdepth or 0) + 1
		while true do
			hook("loop", st.id)
			local fs = sh.forstate[st.id]
			fs.idx = fs.idx + 1
			if fs.idx > #fs.list then
				break
			end
			run_debug(sh, st.line) -- DEBUG fires at the `for` header before each iteration
			if sh.opt_x then -- the header as written, each iteration (bash)
				local ws = {}
				for _, w in ipairs(st.words) do
					if w.src then
						ws[#ws + 1] = w.src
					end
				end
				xtrace_line(sh, "for " .. st.name .. " in " .. table.concat(ws, " "))
			end
			sh:set_str(st.name, fs.list[fs.idx])
			local act = run_loop_body(sh, st.body, hook)
			bodystatus = sh.status
			if act == "break" then
				break
			end
		end
		sh.loopdepth = sh.loopdepth - 1
		sh.status = bodystatus
	elseif t == "select" then
		-- select NAME [in WORDS]: print the numbered menu + $PS3 to stderr, read a line from
		-- stdin (EOF ends the loop); an empty line redisplays the menu; otherwise REPLY=line,
		-- NAME=the chosen item (or empty when it isn't a valid number), run the body.
		if not st.name:match("^[%a_][%w_]*$") then
			io.stderr:write("curse: `" .. st.name .. "': not a valid identifier\n")
			sh.status = 1
			return
		end
		local list = {}
		for _, w in ipairs(st.words) do
			local fs = expand_to_fields(sh, w)
			for k = 1, #fs do
				list[#list + 1] = fs[k]
			end
		end
		if #list == 0 then
			sh.status = 0
			return
		end
		local function menu()
			local width = #tostring(#list)
			for k, item in ipairs(list) do
				io.stderr:write(("%" .. width .. "d) %s\n"):format(k, item))
			end
		end
		local function readline()
			local buf = {}
			while true do
				local ch = fd_getc(0)
				if ch == nil then
					return #buf > 0 and table.concat(buf) or nil
				end
				if ch == "\n" then
					return table.concat(buf)
				end
				buf[#buf + 1] = ch
			end
		end
		local bodystatus = 0
		sh.loopdepth = (sh.loopdepth or 0) + 1
		if sh.opt_x then
			local ws = {}
			for _, w in ipairs(st.words) do
				if w.src then
					ws[#ws + 1] = w.src
				end
			end
			xtrace_line(sh, "select " .. st.name .. " in " .. table.concat(ws, " "))
		end
		menu()
		while true do
			hook("loop", st.id)
			io.flush()
			io.stderr:write(sh.vars["PS3"] and sh:get("PS3") or "#? ")
			local line = readline()
			if line == nil then -- EOF: end the loop (bash prints a newline — to STDOUT — status 1)
				sh.out("\n")
				bodystatus = 1
				break
			end
			if line == "" then
				menu()
			else
				sh:set_str("REPLY", line)
				local nsel = line:match("^%s*(%d+)%s*$")
				nsel = nsel and tonumber(nsel)
				sh:set_str(st.name, (nsel and list[nsel]) or "")
				local act = run_loop_body(sh, st.body, hook)
				bodystatus = sh.status
				if act == "break" then
					break
				end
			end
		end
		sh.loopdepth = sh.loopdepth - 1
		sh.status = bodystatus
	elseif t == "if" then
		local ran = false
		for _, cl in ipairs(st.clauses) do
			local take
			if cl.cond == nil then
				take = true
			else
				sh.noerr = sh.noerr + 1
				exec_list(sh, cl.cond, hook, false)
				sh.noerr = sh.noerr - 1
				take = (sh.status == 0)
			end
			if take then
				exec_list(sh, cl.body, hook, false)
				ran = true
				break
			end
		end
		if not ran then
			sh.status = 0
		end -- no branch taken (no else) -> status 0, like bash
	else
		error("interp: bad stmt " .. tostring(t))
	end
end

M.exec_simple = exec_simple -- the compiled CFG dispatches a natively-built argv (builtins/externals)
M.exec_stmt = exec_stmt -- exposed so the compiled CFG can delegate cold statements
M.xtrace = xtrace -- set -x trace, for rt.exec_dynamic (compiled dynamic command word)
do
	local dlog = os.getenv("CURSE_COUNT_DELEG") -- instrumentation: log compiled->interp delegations
	if dlog then
		local raw = exec_stmt
		M.exec_stmt = function(sh, st, hook)
			local f = io.open(dlog, "a")
			if f then
				local tag = type(st) == "table" and st.t or tostring(st)
				if type(st) == "table" and st.t == "simple" and st.words and st.words[1] then
					local p1 = st.words[1].parts and st.words[1].parts[1]
					tag = "simple:"
						.. (
							p1
								and (p1.lit or (p1.var and "$" .. p1.var) or (p1.pexp and "${}") or (p1.cmdsub and "$()") or "?")
							or "?"
						)
				end
				f:write(tag .. "\n")
				f:close()
			end
			return raw(sh, st, hook)
		end
	end
end

-- Run a trap handler string; preserves $LINENO (so an ERR/EXIT trap sees the
-- failing command's line, not the handler's). Returns true if it called exit.
run_trap = function(sh, code)
	local exited, savedline = false, sh.cur_line
	local saved_tcd = sh.trap_calldepth
	sh.trap_calldepth = sh.calldepth or 0
	sh.in_trap = (sh.in_trap or 0) + 1
	local ok, err = pcall(function()
		for _, st in ipairs(P.parse(code).stmts) do
			exec_stmt(sh, st, function() end)
			-- a failed eligible command INSIDE a handler fires the ERR trap (bash), but
			-- NOT the errexit-exit half; in_err_trap keeps the ERR handler from re-firing.
			if
				sh.noerr == 0
				and sh.status ~= 0
				and not st.negate
				and (
					st.t == "simple"
					or st.t == "pipeline"
					or st.t == "arithcmd"
					or st.t == "assign"
					or st.t == "assignlist"
					or st.t == "subshell"
					or st.t == "dbracket"
				)
			then
				fire_err_trap(sh)
			end
		end
	end)
	sh.in_trap = sh.in_trap - 1
	sh.trap_calldepth = saved_tcd
	sh.cur_line = savedline
	if not ok then
		if type(err) == "table" and err.__curse_parseerr then -- syntax error in the trap code: warned, non-fatal, doesn't exit or change status (bash)
		elseif type(err) == "table" and err.__curse_exit then
			sh.status = err.__curse_exit
			exited = true
		elseif type(err) == "table" and err.__curse_return then
			sh.status = err.__curse_return -- `return N` in a trap sets its status
		else
			error(err)
		end -- a real error propagates
	end
	return exited
end

-- A statement that just failed and is subject to ERR/errexit: a bare
-- simple/pipeline/(( ))/assignment outside a condition (`noerr`), a `!`-negated
-- pipeline being exempt like a condition. (&&/|| lists have their own final-
-- operand rule and call fire_err directly.)
local function errexit_stmt(sh, st)
	return sh.noerr == 0
		and sh.status ~= 0
		and not st.negate
		and (
			st.t == "simple"
			or st.t == "pipeline"
			or st.t == "arithcmd"
			or st.t == "assign"
			or st.t == "assignlist"
			or st.t == "subshell"
			or st.t == "dbracket"
		) -- a failing ( ) / [[ ]] also fires
end
-- Run the ERR trap (once, in scope: the main shell unless errtrace extends it to
-- functions/subprograms) preserving $?, then exit if errexit is on. Shared by
-- exec_list, run_lazy and the &&/|| handler (which previously drifted apart).
-- Run just the ERR trap (once, in scope), preserving $?; no errexit-exit. Used
-- both by fire_err and directly by run_trap (a failed command inside a handler).
fire_err_trap = function(sh)
	local h = sh.traps and sh.traps.ERR
	-- ERR is not re-run inside a forked pipeline stage (bash fires it ONCE for the
	-- whole pipeline, in the parent); errtrace still extends it to functions/subshells.
	local errscope = sh.opt_errtrace
		or ((sh.calldepth or 0) == 0 and (sh.in_subprogram or 0) == 0 and (sh.in_pipestage or 0) == 0)
	if h and h ~= "" and not sh.in_err_trap and errscope then
		sh.in_err_trap = true
		local saved = sh.status
		run_trap(sh, h)
		sh.status = saved
		sh.in_err_trap = false
	end
end
fire_err = function(sh)
	fire_err_trap(sh)
	if sh.opt_e then
		error({ __curse_exit = sh.status })
	end
end
M.fire_err_trap = fire_err_trap -- compiled tier fires ERR after a failing native command
-- A prompt string (PS1/PS2/… and ${x@P}): decode the backslash escapes, then (promptvars)
-- expand $var/$(…)/`…`. Only re-parse when there IS an expansion: re-parsing otherwise eats
-- decoded backslashes (a kept unknown escape `\x55`, a lone `\`), which bash keeps.
M.prompt_string = function(sh, s)
	local decoded = sh:prompt_escapes(s or "")
	if not decoded:find("[$`]") then
		return decoded
	end
	return expand_word(sh, P.parse_word(decoded))
end
M.run_trap_str = function(sh, code) -- a late-forked subshell child runs its own EXIT trap
	return run_trap(sh, code)
end

-- (`return N` status is now rt.return_status — a pure runtime primitive the compiled
-- tier calls directly.)

-- Run the trap for the signal `signum` that the async handler delivered via the VM
-- hook (lib_cursesig.c). No pending queue — the hook hands us exactly the signal
-- that fired. run_trap bumps sh.in_trap so a signal arriving DURING the handler is
-- serialized (the hook re-arms and runs it after this returns), never nested. A
-- signal trap doesn't change $? unless it exits/returns; `exit` in the handler
-- propagates to exit the shell (bash).
local function run_signal(sh, signum)
	if sh.in_trap and sh.in_trap > 0 then
		return
	end -- don't run a trap inside a trap
	local h = sh.traps and sh.traps["SIG" .. (NUMSIG[signum] or "")]
	if not h or h == "" then
		return
	end
	-- an asynchronously-delivered signal handler reports $LINENO = 1 (bash).
	local saved, sl = sh.status, sh.cur_line
	sh.cur_line = 1
	local exited = run_trap(sh, h)
	sh.cur_line = sl
	if exited then
		error({ __curse_exit = sh.status })
	end -- `exit` in the trap exits the shell
	sh.status = saved -- otherwise $? is preserved across the signal
end
M.run_signal = run_signal

exec_list = function(sh, stmts, hook, toplevel)
	for k = 1, #stmts do
		local st = stmts[k]
		if toplevel then
			hook("stmt", k)
		end
		exec_stmt(sh, st, hook)
		if errexit_stmt(sh, st) then
			fire_err(sh)
		end
		-- (signal traps are delivered by the async VM hook — no per-statement poll)
	end
end
M.exec_list = exec_list

-- Run a trap handler string; returns true if it called exit (which wins).
local function shallow_noexit(t)
	local c = {}
	for k, v in pairs(t) do
		if k ~= "EXIT" then
			c[k] = v
		end
	end
	return c
end
local function finish(sh, ok, err)
	if sh.subshell_child then -- a compiled subshell's forked child: end it here (rt.subshell_fork)
		child_status(sh, ok, err)
		rt.child_exit(sh, sh.status or 0)
	end
	if not ok then
		if type(err) == "table" and err.__curse_noexittrap then
			sh.traps = sh.traps and shallow_noexit(sh.traps) -- `exec cmd`: the process is gone
		end
		if type(err) == "table" and err.__curse_exit then
			sh.exit_requested = true -- (the REPL stops reading)
			sh.status = err.__curse_exit
		elseif type(err) == "table" and err.__curse_return then
			sh.status = err.__curse_return
		else
			error(err)
		end
	end
	-- EXIT trap: runs once with $? = the final status; its own status is ignored
	-- unless it calls exit (bash semantics). A REPL/stdin session runs many chunks
	-- through here and fires it once at the very end instead (defer_exit_trap).
	if sh.defer_exit_trap then
		return
	end
	M.run_exit_trap(sh)
end
M.run_exit_trap = function(sh)
	local h = sh.traps and sh.traps.EXIT
	if h and h ~= "" and not sh.in_exit_trap then
		sh.in_exit_trap = true
		local saved = sh.status
		sh.cur_line = 1 -- (bash: the EXIT trap's $LINENO counts from 1)
		if not run_trap(sh, h) then
			sh.status = saved
		end
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
function M.finish_run(sh, fn)
	finish(sh, pcall(fn))
end

-- Run LAZILY from source: parse one top-level statement, execute it, repeat.
-- Instant start on large scripts (no full parse up front), and it never
-- tokenizes past an `exit` — so a hybrid shell+binary installer just works with
-- no special-casing. `hook("stmt", k)` fires per top-level statement (same k as
-- the eager AST, so tier OSR-by-stmt still lines up).
function M.run_lazy(sh, src, hook)
	hook = hook or function() end
	local nextf = P.open(src, sh) -- sh: alias expansion uses the live alias table
	finish(
		sh,
		pcall(function()
			local k = 0
			while true do
				local lg = nextf()
				if lg == nil then
					break
				end
				-- bash parses a whole LOGICAL LINE (a `simple_list` up to a top-level newline)
				-- before executing any of it, so a syntax error ANYWHERE on the line means the
				-- line runs nothing (retroactive). Handle that first.
				if lg.perr then
					-- A RECOVERABLE parse error (invalid `NAME=( … )` array-literal element) is
					-- reported but NON-fatal: the assignment is dropped (var stays unset) and the
					-- script continues, like bash. Any other syntax error runs nothing + exits 2.
					if lg.perr.recoverable then
						io.stderr:write("curse: " .. (lg.perr.msg or "syntax error") .. "\n")
						sh.status = 1
					else
						exec_stmt(sh, lg.perr, hook)
					end -- raises __curse_exit=2 (bash exits)
				end
				for _, st in ipairs(lg.stmts) do
					k = k + 1
					hook("stmt", k)
					local ok, err = pcall(exec_stmt, sh, st, hook)
					if not ok then
						-- a fatal WORD-context expansion (div0 in $((…)), failglob no-match) aborts
						-- the REST of this line; under `set -e` it exits the shell like any failure
						if type(err) == "table" and err.__curse_lineabort then
							if sh.opt_e then
								error(err)
							end
							sh.status = 1
							break
						else
							error(err)
						end
					else
						if errexit_stmt(sh, st) then
							fire_err(sh)
						end
						-- (signal traps are delivered by the async VM hook — no per-statement poll)
					end
				end
			end
		end)
	)
end

-- Run $PROMPT_COMMAND before an interactive prompt (bash), in the current shell.
-- $? is restored afterward so the upcoming command sees the previous command's
-- status (PROMPT_COMMAND can READ it); side effects (vars, BASH_REMATCH) persist.
-- A parse error, runtime error, or div0/failglob is reported/absorbed and
-- non-fatal (the REPL keeps going); only a real `exit` propagates. No EXIT trap
-- (that's not run per-prompt), so this is NOT run_lazy/finish.
function M.run_prompt_command(sh, hook)
	local pc = sh.vars.PROMPT_COMMAND and sh:get("PROMPT_COMMAND")
	if not pc or pc == "" then
		return
	end
	hook = hook or function() end
	local saved = sh.status
	local ok, err = pcall(function()
		local nextf = P.open(pc, sh)
		while true do
			local lg = nextf()
			if lg == nil then
				break
			end
			if lg.perr then
				io.stderr:write("curse: PROMPT_COMMAND: line 1: syntax error\n")
				return
			end
			for _, st in ipairs(lg.stmts) do
				local sok, serr = pcall(exec_stmt, sh, st, hook)
				if not sok then
					if type(serr) == "table" and serr.__curse_exit and not serr.__curse_lineabort then
						error(serr)
					elseif type(serr) == "table" and serr.__curse_lineabort then
						sh.status = 1
						break
					else
						return
					end -- other runtime error: non-fatal, like bash
				end
			end
		end
	end)
	if not ok then
		error(err)
	end -- a real `exit` in PROMPT_COMMAND
	sh.status = saved
end

-- Does `buf` end with an obviously-unterminated construct (unbalanced quotes,
-- (/${/((, a trailing backslash, or an open block keyword)? The REPL uses it to
-- decide PS2-continue; source_file uses it to reject an incomplete rc file whole
-- (bash reads the file as a unit, so an unclosed `(` runs nothing). Heuristic.
function M.incomplete_input(buf)
	if buf:sub(-1) == "\\" then
		return true
	end
	local i, n = 1, #buf
	local sq, dq, paren, brace = false, false, 0, 0
	local words = {}
	while i <= n do
		local c = buf:sub(i, i)
		if sq then
			if c == "'" then
				sq = false
			end
			i = i + 1
		elseif dq then
			if c == "\\" then
				i = i + 2
			elseif c == '"' then
				dq = false
				i = i + 1
			else
				i = i + 1
			end
		elseif c == "'" then
			sq = true
			i = i + 1
		elseif c == '"' then
			dq = true
			i = i + 1
		elseif c == "\\" then
			i = i + 2
		elseif c == "#" then
			while i <= n and buf:sub(i, i) ~= "\n" do
				i = i + 1
			end
		elseif c == "$" and buf:sub(i + 1, i + 2) == "((" then
			paren = paren + 2
			i = i + 3
		elseif c == "$" and buf:sub(i + 1, i + 1) == "(" then
			paren = paren + 1
			i = i + 2
		elseif c == "$" and buf:sub(i + 1, i + 1) == "{" then
			brace = brace + 1
			i = i + 2
		elseif c == "(" then
			paren = paren + 1
			i = i + 1
		elseif c == ")" then
			paren = paren - 1
			i = i + 1
		elseif c == "}" then
			brace = brace - 1
			i = i + 1
		else
			local _, e, w = buf:find("^([%a_][%w_]*)", i)
			if w then
				words[#words + 1] = w
				i = e + 1
			else
				i = i + 1
			end
		end
	end
	if sq or dq or paren > 0 or brace > 0 then
		return true
	end
	local opens, closes = 0, 0
	for _, w in ipairs(words) do
		if w == "if" or w == "for" or w == "while" or w == "until" or w == "case" or w == "select" then
			opens = opens + 1
		elseif w == "fi" or w == "done" or w == "esac" then
			closes = closes + 1
		end
	end
	return opens > closes
end

-- Source an rc file (bash's --rcfile) before an interactive shell runs -c/REPL:
-- run it like the shell's own input; a syntax error is reported WITH the file
-- name (bash) and is non-fatal, but a real `exit` in the rc file propagates to
-- end the whole shell (before -c runs). Missing file: silently skipped.
function M.source_file(sh, path, hook)
	local f = io.open(path, "r")
	if not f then
		return
	end
	local src = f:read("*a")
	f:close()
	hook = hook or function() end
	-- bash parses the whole rc file; an unterminated construct is a syntax error
	-- that runs NOTHING (curse's parser is lazily lenient about unclosed (/{ , so
	-- detect it here). Non-fatal: the shell still runs -c/REPL afterward.
	if M.incomplete_input(src) then
		io.stderr:write("curse: " .. path .. ": syntax error: unexpected end of file\n")
		sh.status = 2
		return
	end
	local nextf = P.open(src, sh)
	while true do
		local lg = nextf()
		if lg == nil then
			break
		end
		if lg.perr then
			io.stderr:write(
				"curse: " .. path .. ": line " .. (lg.perr.line or 1) .. ": " .. (lg.perr.msg or "syntax error") .. "\n"
			)
			sh.status = 2
			return
		end
		for _, st in ipairs(lg.stmts) do
			local sok, serr = pcall(exec_stmt, sh, st, hook)
			if not sok then
				if type(serr) == "table" and serr.__curse_lineabort then
					if sh.opt_e then
						error(serr)
					end
					sh.status = 1
					break
				else
					error(serr)
				end -- a real `exit` (or return) propagates
			end
		end
	end
end

-- Internals exposed to lazily-loaded feature modules (see BUILTIN_LAZY /
-- build.lua lazy_mods). These are the interp locals the extracted builtins
-- reference; a feature module aliases them to the same names and copies its
-- branch bodies verbatim.
M._int = {
	SPECIAL_BUILTIN = SPECIAL_BUILTIN,
	exec_simple = exec_simple,
	expand_part_str = expand_part_str,
	tilde_word_initial = tilde_word_initial,
	file_test = file_test,
	sq = sq,
	BUILTINS = BUILTINS,
	KEYWORDS = KEYWORDS,
	SETOPTS = SETOPTS,
	SHOPT_ORDER = SHOPT_ORDER,
	parse_umask = parse_umask,
	umask_symbolic = umask_symbolic,
	job_reap = job_reap,
	block_sig = block_sig,
	canon_sig = canon_sig,
	sig_order = sig_order,
	find_all_in_path = find_all_in_path,
	name_type = name_type,
	SIGNUM = SIGNUM,
	NUMSIG = NUMSIG,
	array_key = array_key,
	arith_resolve = arith_resolve,
	arith_nounset = arith_nounset,
	sh_printf = sh_printf,
	fd_getc = fd_getc,
	fd_ready = fd_ready,
	read_split = read_split,
	do_arrayassign = do_arrayassign,
	eval = eval,
	fmt_decl = fmt_decl,
	fmt_set_var = fmt_set_var,
	logical_canon = logical_canon,
	opt_on = opt_on,
	set_opt = set_opt,
	SETFLAG = SETFLAG,
	SETOPT = SETOPT,
	func_body_text = func_body_text,
	func_export_text = func_export_text,
	exec_list = exec_list,
	statbuf = statbuf,
	statbuf2 = statbuf2,
	run_trap = run_trap,
	job_resolve = job_resolve,
	SIGDESC = SIGDESC,
	rl_capture = rl_capture,
	rl_lib = rl_lib,
	SHOPT_DEFAULT = SHOPT_DEFAULT,
	shopt_on = shopt_on,
	sherr = sherr,
	C = C,
	P = P,
	rt = rt,
}

rt.INTERP_FRAMES[exec_stmt] = true -- (error prefixes: sh.cur_line is current under it)
return M
