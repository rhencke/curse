-- Tree-walking interpreter over the AST, mutating the shared `sh`. It starts
-- instantly (no compile) and runs statement-by-statement like bash. At each
-- safepoint — a top-level statement boundary and every loop back-edge — it
-- calls `hook(kind, id)`; the tier driver's hook throws {switch=true, resume=…}
-- when the compiled Lua is ready, unwinding here so execution can jump into the
-- compiled code from exactly this point (state is already in `sh`).
local rt = require("runtime")
local PREEMPT = rt.preempt_flag -- (raised when a background job's CPU slice runs out: see rt.preempt)
local P = require("parser") -- parser has no load-time dep on interp, so this is cycle-safe
local i64 = rt.i64
local ffi = require("ffi")
local u64 = ffi.typeof("uint64_t") -- string.format formats int64_t/uint64_t cdata directly
local bit = require("bit")

local M = {}

-- `set -o NAME` / short-flag maps for the `set` builtin (and shopt -o). The option
-- machinery lives in runtime (option state is runtime data); interp and the set/shopt
-- builtins (via _int) use it under these names.
local SETOPTS, SETOPT, SETFLAG, opt_on = rt.SETOPTS, rt.SETOPT, rt.SETFLAG, rt.opt_on
local function set_opt(sh, field, on)
	local was = sh[field]
	sh[field] = on
	if field == "opt_m" and on then -- (set -m turns job control back on in a subshell: b_fg)
		sh.m_gen = (sh.m_gen or 0) + 1
	end
	-- `set -o history` in a script: bash's load_history (HISTSIZE/HISTFILESIZE defaults,
	-- then $HISTFILE) when nothing was recorded yet this session
	if field == "opt_history" and on and was ~= true and not sh.opt_i then
		require("hist").load(sh)
	end
	-- bash's set_ignoreeof: `set -o ignoreeof` binds IGNOREEOF=10, `set +o` unsets it;
	-- either way a lowercase `ignoreeof` variable goes
	if field == "opt_ignoreeof" then
		if sh.vars.ignoreeof then
			sh.vars.ignoreeof = nil
			ffi.C.unsetenv("ignoreeof")
		end
		if on then
			sh:set_str("IGNOREEOF", "10")
		else
			sh.vars.IGNOREEOF = nil
			ffi.C.unsetenv("IGNOREEOF")
		end
	-- bash's set_posix_mode: -o posix binds POSIXLY_CORRECT=y, +o posix unbinds it
	elseif field == "opt_posix" and (on and true or false) ~= (was and true or false) then
		if on then
			sh:set_str("POSIXLY_CORRECT", "y")
		else
			sh.vars.POSIXLY_CORRECT = nil
			ffi.C.unsetenv("POSIXLY_CORRECT")
		end
	end
	-- bash's posix_initialize (general.c): posix mode turns expand_aliases, inherit_errexit
	-- and shift_verbose on; leaving it (nothing saved) resets expand_aliases to
	-- interactive_shell and shift_verbose off (inherit_errexit stays)
	if field == "opt_posix" and not on ~= not was and sh.shopt then
		local so = sh.shopt
		if on then
			so.expand_aliases, so.inherit_errexit, so.shift_verbose = true, true, true
		else
			so.expand_aliases, so.shift_verbose = sh.opt_i and true or false, false
		end
	end
	-- emacs and vi are readline's editing mode (sh.opt_vi) over bash's no_line_editing
	-- (set_edit_mode): turning either on enables line editing; turning the CURRENT mode off
	-- disables it
	if field == "opt_emacs" or field == "opt_vi" then
		local vimode = field == "opt_vi" and was == true or field == "opt_emacs" and sh.opt_vi == true
		sh.opt_emacs = nil
		if on then
			sh.opt_vi, sh.line_editing = field == "opt_vi", true
		elseif (field == "opt_vi") == vimode then
			sh.opt_vi, sh.line_editing = vimode, false
		end
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
local COMPAT_OPT = { compat31 = 31, compat32 = 32, compat40 = 40, compat41 = 41, compat42 = 42,
	compat43 = 43, compat44 = 44 }
local function shopt_on(sh, name)
	if COMPAT_OPT[name] then -- (derived from the compatibility level, $BASH_COMPAT — bash)
		return rt.compat_level(sh) == COMPAT_OPT[name]
	end
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
-- the value.
local rs_pats = {} -- IFS -> { sep, non, tail } for the fast path (false: not whitespace-only)
local function read_split(ifs, line, nvars, nomark, saw, sh) -- (nomark: \1 is plain — read's
	-- skip_ctlesc; saw: then a CTLNUL was marked, \1\177)
	-- (a pending glibc mbtowc state, or a line that may leave one — rt.mbtowc_visit — takes
	-- the general path, whose scan models it)
	local st = sh and (sh.mbw ~= nil or (line:byte(-1) or 0) >= 0x80) and ifs ~= "" and rt.lc_mb_cur_max() > 1
		and rt.lc_utf8()
	-- the common case: an IFS of whitespace only, no escaped chars — fields are runs of
	-- non-IFS; the last var gets the rest with trailing IFS stripped (as below)
	local pairs_ = nomark and not ifs:find("\127", 1, true) and line:find("\1\127", 1, true)
	local pat = not st and rs_pats[ifs]
	if pat == nil then
		if ifs ~= "" and not ifs:find("[^ \t\n]") then
			pat = { "[" .. ifs .. "]", "[^" .. ifs .. "]", "^(.-)[" .. ifs .. "]*$" }
		elseif ifs ~= "" and not ifs:find("[ \t\n\v\f\r\128-\255%z]") then -- (no whitespace)
			pat = { "[" .. ifs:gsub("%W", "%%%0") .. "]", nows = true }
		else
			pat = false
		end
		rs_pats[ifs] = pat
	end
	-- (non-UTF-8 multibyte text walks by character: a trail byte may be an IFS byte — M.ifs_find)
	if pat and pat.nows and not (rt.mbx and line:find("[\128-\255]"))
		and ((nomark and not pairs_) or (not nomark and not line:find("\1", 1, true))) then
		-- an IFS of non-whitespace delimiters only: each one ends a field (empty fields
		-- kept); the last var gets the raw rest — minus a lone trailing delimiter when
		-- that rest is a single field (bash, as below)
		local sep, out, pos = pat[1], {}, 1
		for v = 1, nvars - 1 do
			local e = line:find(sep, pos)
			if not e then
				out[v] = line:sub(pos)
				pos = nil
				break
			end
			out[v] = line:sub(pos, e - 1)
			pos = e + 1
		end
		if pos then
			local rest = line:sub(pos)
			local e = rest:find(sep)
			out[nvars] = (e and e == #rest) and rest:sub(1, e - 1) or rest
		end
		return out
	end
	if pat and not pat.nows and ((nomark and not pairs_) or (not nomark and not line:find("\1", 1, true))) then
		if nvars == 1 then -- (one var: the line minus leading/trailing IFS whitespace)
			local b1, b2 = line:byte(1), line:byte(-1)
			if not b1 or not (ifs:find(string.char(b1), 1, true) or ifs:find(string.char(b2), 1, true)) then
				return { line }
			end
		end
		local sep, non = pat[1], pat[2]
		local out = {}
		local pos = line:find(non)
		for v = 1, nvars - 1 do
			if not pos then
				break
			end
			local e = line:find(sep, pos)
			if not e then
				out[v] = line:sub(pos)
				pos = nil
				break
			end
			out[v] = line:sub(pos, e - 1)
			pos = line:find(non, e)
		end
		if pos then
			out[nvars] = line:match(pat[3], pos)
		end
		return out
	end
	-- the general case, as bash's read.def over get_word_from_string (subst.c): the field
	-- engine's delimiter scan (rt.ifs_find: a field ends per character) on the raw line —
	-- CTLESC markers and all — so a field's markers are dropped only once it is cut out.
	-- Whitespace is two classes here: read.def's initial strip, the step past a delimiter
	-- (rt.ifs_rskip) and strip_trailing_ifs_whitespace take only space/tab/newline IFS
	-- bytes (spctabnl), each word's own leading skip and the "whitespace delimiter" test
	-- every isspace one (\v \f \r too) — so `IFS=$'\v' read x <<< $'\va\v\vb'` keeps x raw.
	-- Under nomark (IFS holds \1: skip_ctlesc) the only markers are a CTLNUL's (\1\177,
	-- kept whole by SX_NOESCCTLNUL); `saw` (bash's saw_escape) then dequotes every \1.
	local ic = rt.ifs_charset_of(ifs)
	local n, wsb, rwsb = #line, ic.wsb, ic.rwsb
	-- (under nomark only a \1\177 pair is special — SX_NOESCCTLNUL — unless IFS holds \177;
	-- a pair of raw input bytes counts too, left undequoted when nothing was marked)
	local esc = (nomark and pairs_ and 2) or (not nomark and line:find("\1", 1, true) and true)
	local skipws, find = rt.ifs_skipws, rt.ifs_find
	local i = skipws(rwsb, line, 1, n) -- read.def's leading strip
	local out = {}
	for v = 1, nvars do
		local s = skipws(wsb, line, i, n) -- (get_word_from_string's own leading skip)
		if s > n then
			out[v], i = "", n + 1
		else
			local e, l = find(ic, line, s, esc, nil, nil, st and sh)
			local nx = n + 1
			if e then
				nx = rt.ifs_rskip(ic, line, e + l, n, wsb[line:byte(e)] and 1 or 2)
			else
				e = n + 1
			end
			if v < nvars or nx > n then
				-- a field; for the LAST var only when nothing remains after it and its one
				-- delimiter (so `IFS=x; read a b <<< axbx` gives b="b", and `xx` gives b="")
				out[v] = line:sub(s, e - 1)
				i = nx
			else
				-- the last var otherwise gets the raw remainder (from before its word's
				-- leading skip) with only trailing IFS spctabnl stripped (interior/trailing
				-- other IFS kept). bash's strip_trailing_ifs_whitespace (subst.c) runs on it
				-- CTLESC (\1) markers and all: scan back while the byte is such whitespace,
				-- OR (saw_escape) it's a \1 whose FOLLOWING byte is space/tab/nl — never
				-- removing the first byte. That strips a \1's escaped space while orphaning
				-- the bare \1, so a lone \001 leaks into the value (read.def bug;
				-- builtin-read "read bash bug"). Mirror it byte-for-byte and dequote only
				-- afterward.
				local S = n
				while S > i do
					local b = line:byte(S)
					if not (rwsb[b] or (saw and b == 1 and line:sub(S + 1, S + 1):find("^[ \t\n]"))) then
						break
					end
					S = S - 1
				end
				out[v] = line:sub(i, S)
			end
			if saw then -- (dequote_string: \1 escapes the next byte; a trailing lone \1 stays)
				out[v] = out[v]:gsub("\1(.)", "%1")
			end
		end
	end
	return out
end
-- `set` (no args) one-line rendering of a variable box.
local function fmt_set_var(name, b)
	if rawget(b, "virt") then
		return name .. "=()" -- (BASH_ALIASES/BASH_CMDS: bash's `set` shows their unbuilt cell)
	end
	if b.assoc and b.arr then
		local keys = rt.assoc_keys(b) -- (bash's hash order, as declare -p)
		if #keys == 0 then
			return name .. "=()"
		end
		local parts = {}
		for _, k in ipairs(keys) do -- (quoted like declare -p's: $'…' for control characters)
			parts[#parts + 1] = ("[%s]=%s"):format(M.decl_key(tostring(k), true), M.decl_quote(tostring(b.arr[k])))
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
			parts[#parts + 1] = ("[%s]=%s"):format(rt.i64_to_str(rt.key_i64(i)), M.decl_quote(tostring(b.arr[i])))
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

-- libc (and curse's own lib_cursesig) entry points the interpreter and the builtins call
ffi.cdef([[
  int access(const char *path, int mode);
  int chdir(const char *path);
  int curse_stat(const char *path, void *buf) asm("stat");
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
  int sigemptyset(void *set);
  int sigprocmask(int how, const void *set, void *oldset);
  /* curse async signal handling (lib_cursesig.c): a real handler installed without
   * SA_RESTART (blocking syscalls EINTR) that schedules a VM hook to run the trap. */
  int curse_sig_catch(int signum);
  int curse_sig_default(int signum);
  int curse_sig_ignore(int signum);
  void curse_sig_clearpending(void);
  int kill(int pid, int sig);
  unsigned int geteuid(void);
  unsigned int getegid(void);
  int fcntl(int fd, int cmd, ...);
  struct curse_rlimit { uint64_t rlim_cur; uint64_t rlim_max; };
  int getrlimit(int resource, struct curse_rlimit *rlim);
  int setrlimit(int resource, const struct curse_rlimit *rlim);
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
	local tfd, tmp = rt.mktmpfd() -- (mode 0600 whatever the umask; see rt.mktmpfd)
	if tfd < 0 then
		return nil
	end
	C.close(tfd)
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
	rt.rd_gen = rt.rd_gen + 1 -- (a read `read` didn't peek: see rt.pipe_cache)
	local n = C.read(fd, rd1, 1)
	while n < 0 and ffi.errno() == 4 do -- EINTR: the trap runs (zread's retry)
		rt.eintr()
		n = C.read(fd, rd1, 1)
	end
	if n == 1 then
		return string.char(rd1[0] % 256)
	end
	if n < 0 then -- (an error, not EOF: its errno — `read < /` is EISDIR)
		return nil, ffi.errno()
	end
	return nil -- EOF
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
-- the real-time signals, named as bash (glibc) lists them: RTMIN, RTMIN+1…+15,
-- RTMAX-14…-1, RTMAX (34…64 on Linux)
SIGNUM.RTMIN, SIGNUM.RTMAX = 34, 64
for k = 1, 15 do
	SIGNUM["RTMIN+" .. k] = 34 + k
end
for k = 1, 14 do
	SIGNUM["RTMAX-" .. k] = 64 - k
end
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
	[10] = "User defined signal 1",
	[12] = "User defined signal 2",
	[16] = "Stack fault",
	[24] = "CPU time limit exceeded",
	[25] = "File size limit exceeded",
	[26] = "Virtual timer expired",
	[27] = "Profiling timer expired",
	[29] = "I/O possible",
	[30] = "Power failure",
	[31] = "Bad system call",
	[11] = "Segmentation fault",
	[13] = "Broken pipe",
	[14] = "Alarm clock",
	[15] = "Terminated",
	[19] = "Stopped (signal)", -- (the stop signals: `jobs -l` of a stopped job)
	[20] = "Stopped",
	[21] = "Stopped (tty input)",
	[22] = "Stopped (tty output)",
}
-- A trap's signal spec (bash's decode_signal with DSIG_NOCASE|DSIG_SIGPREFIX, trap.c): a
-- legal_number 0..64 (blanks/sign/leading zeros ok; 0 = EXIT), [SIG]RTMIN+N for N 0..30,
-- or a name with or without SIG (EXIT/DEBUG/ERR/RETURN only bare). Returns the canonical
-- key: EXIT/DEBUG/ERR/RETURN, SIG<name>, or the plain number for one with no name (32, 33).
local function canon_sig(s)
	local n = rt.legal_number(s)
	if n then
		if n < 0 or n > 64 then
			return nil
		end
		if n == 0 then
			return "EXIT"
		end
		local nm = NUMSIG[n]
		return nm and ("SIG" .. nm) or tostring(n)
	end
	s = s:upper()
	if s == "EXIT" or s == "ERR" or s == "DEBUG" or s == "RETURN" then
		return s
	end
	local rtn = s:match("^SIGRTMIN%+(.*)$") or s:match("^RTMIN%+(.*)$")
	if rtn then
		n = rt.legal_number(rtn)
		return n and n >= 0 and n <= 30 and ("SIG" .. NUMSIG[SIGNUM.RTMIN + n]) or nil
	end
	s = s:gsub("^SIG", "")
	return SIGNUM[s] and ("SIG" .. s) or nil
end
-- for printing: EXIT=0, then by signal number, then DEBUG, ERR, RETURN (bash's trap_list
-- slots NSIG, NSIG+1, NSIG+2 — trap.h DEBUG_TRAP/ERROR_TRAP/RETURN_TRAP)
local PSEUDO_ORDER = { EXIT = 0, DEBUG = 65, ERR = 66, RETURN = 67 }
local function sig_order(canon)
	local o = PSEUDO_ORDER[canon]
	if o then
		return o
	end
	local nm = canon:gsub("^SIG", "")
	return SIGNUM[nm] or tonumber(nm) or 99
end
-- The hook for an isolated context (subshell, $(…), pipeline stage, background job):
-- no switch of the whole program (it mustn't unwind past the context's checkpoint), but
-- a hot loop may still run compiled on its own — tier installs M.frag_hook when loaded.
local function SUBHOOK(kind, id, st, sh)
	local f = M.frag_hook
	if f then
		return f(kind, id, st, sh)
	end
end

-- file predicates live in runtime (pure stat FFI; shared with the compiled tier and
-- the builtins). statbuf2 is the second stat buffer `pwd` compares against statbuf.
local file_test = rt.file_test
local statbuf2 = ffi.new("uint8_t[144]")
-- `test -v NAME` / `[[ -v NAME ]]`: is the variable (or array element) set?
local array_key -- forward (defined below)
-- The test/[ engine + var_is_set moved to runtime (its operand primitives are all
-- runtime funcs). Import the pieces interp's [[ ]] eval and the test/[ builtin call.
local var_is_set, unary, binary, do_test = rt.var_is_set, rt.test_unary, rt.test_binary, rt.do_test

local tilde_prefix -- forward (word-initial ~ expansion; defined below, used in paramexp)
local expand_word -- forward (used by eval's $-deferred arith and expand_part_str)
local expand_assign_word -- forward (assignment-RHS expander; ${-default} tilde ctx)
local notilde -- forward (a word copy that expands with no tilde expansion: 5.2.21 assoc subscripts)
local expand_pattern -- forward (quote-aware glob-pattern expansion for ${v/…} etc.)
local expand_repl -- forward (${v/pat/REPL} replacement expansion)
local is_multi, multi_elems, multi_hda -- forward (defined with the field expander)
local indirect_part -- forward (${!ref} target resolution, re-parsed to a part)
local eval -- arithmetic evaluator (forward decl)
local noeval_pow -- a short-circuited operand's exponent check (forward decl)
local arith_pre -- a syntax error's already-evaluated prefix (forward decl)
local arith_resolve -- var-value-as-arith-expression resolver (forward decl)
local arith_key -- array subscript in arith: string key for assoc, number for indexed
local xpand_subdepth -- 1 while arith_key evaluates an xpand subscript (see arith_key)
local in_expanded_text -- evaluating arith_textual_eval's expanded text (see there)
local run_trap -- trap-handler runner (forward decl; defined near the bottom)
local fire_err -- ERR-trap + errexit enforcement (forward decl; defined near exec_list)
local fire_err_trap -- the ERR-trap half of fire_err WITHOUT errexit-exit (used inside handlers)
local sherr = rt.Shell.errmsg -- error-message writer, capture-aware for `2>&1` in $()
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
	-- (the VALUE is not word-expanded: bash's expr_streval evaluates it as-is, so a `$`,
	-- backquote or quote in it is a syntax error — "let" mode; only a subscript expands)
	local ok, ast = pcall(P.arith, s, "let")
	if not ok then -- the value is not a valid arith expression (e.g. "12 34", "1+"): an
		-- arith error — the command fails and (bash) the rest of the line is discarded
		arith_pre(sh, ast)
		io.stderr:write("curse: " .. P.arith_errmsg(s, ast) .. "\n")
		error({ __curse_exit = 1, __curse_matherr = true, __curse_experr = true, __curse_lineabort = true })
	end
	-- a value naming itself (x=x, or a=b b=a): bash's expression recursion limit
	local depth = (sh.arith_depth or 0) + 1
	if depth > 1024 then
		io.stderr:write("curse: " .. P.arith_errmsg(s, { msg = "expression recursion level exceeded", tok = s }) .. "\n")
		error({ __curse_exit = 1, __curse_matherr = true, __curse_experr = true, __curse_lineabort = true })
	end
	-- A nested bad value (rare: `s=t; t='1 2'`) stays swallowed as 0, matching the
	-- previous behavior; but a genuine arith error during eval (syntax/math, e.g. a
	-- bad subscript) propagates so the command fails like bash instead of yielding 0.
	local sv = in_expanded_text
	in_expanded_text = true -- (a value is expansion output: its subscripts expand unquoted)
	sh.arith_depth = depth
	local ok2, v = pcall(eval, sh, ast)
	sh.arith_depth = depth - 1
	in_expanded_text = sv
	if not ok2 then
		if type(v) == "table" and (v.__curse_experr or v.__curse_matherr or v.__curse_unbound) then
			error(v)
		end
		return i64(0)
	end
	return v ~= nil and v or i64(0)
end

-- Division/modulo by zero is a fatal arithmetic error (bash aborts the current
-- command with status 1 and a diagnostic). Tagged __curse_matherr so a caller
-- that runs code in a protected context (compgen -F) can recover from it.
local function arith_div0(e, msg)
	-- bash's evalerror text: the expression and the lookahead token (parser: etxt/etok)
	msg = msg or "division by 0"
	io.stderr:write("curse: " .. (e and e.etxt and P.arith_errmsg(e.etxt, { msg = msg, tok = e.etok }) or msg) .. "\n")
	error({ __curse_exit = 1, __curse_matherr = true, __curse_lineabort = true })
end

-- Reading an unset variable in arithmetic under `set -u` is a fatal unbound-
-- variable error (bash), just like `$var`. Applies to plain reads and to the
-- read side of `+=`/`++`/`--`, but NOT to a pure `=` assignment (which defines).
-- (bash's expr_streval: a variable that doesn't exist or is INVISIBLE — declared, never
-- assigned: `declare x`, `declare -A h` — even for an element read `h[k]`)
local function arith_nounset(sh, name)
	if sh.opt_u then
		local b = sh.vars[sh:deref(name)]
		if (b == nil or (b.arr == nil and b.s == nil and b.n == nil) or (b.empty_decl and b.arr and next(b.arr) == nil))
			and sh:special_get(name) == "" then
			io.stderr:write("curse: " .. name .. ": unbound variable\n")
			error({ __curse_exit = sh.opt_c and 127 or 1, __curse_lineabort = sh.opt_i or nil, __curse_unbound = true })
		end
	end
end

-- bash's textual path for arithmetic with expansions: expand the raw text, then parse
-- the RESULT as plain arithmetic (a `$` left in it is an error). Shared by both tiers.
-- bash's expand_arith_string: the text is expanded as if double-quoted, but quote
-- characters and backslashes stay as they are (a `\` still stops the `$` after it from
-- expanding: `(( '\$(cmd)' ))` runs nothing); `"` drops. Each $…/`…` expansion is
-- substituted as literal text.
local function arith_expand_text(sh, raw, depth0) -- depth0: 1 = the text IS a subscript
	local out, k, n, depth = {}, 1, #raw, depth0 or 0
	while k <= n do
		local c = raw:sub(k, k)
		if c == "\\" then
			-- (the text is expanded as in double quotes: at top level `\$` is a `$`, …)
			local nx = raw:sub(k + 1, k + 1)
			out[#out + 1] = (depth == 0 and nx:match('^[$`\\"]$')) and nx or raw:sub(k, k + 1)
			k = k + 2
		elseif c == '"' then
			k = k + 1
		elseif c == "[" or c == "]" then -- (subscript depth, for the quoting below)
			depth = math.max(0, depth + (c == "[" and 1 or -1))
			out[#out + 1] = c
			k = k + 1
		elseif c == "$" or c == "`" then
			local nx = raw:sub(k + 1, k + 1)
			-- (to the end of the $name / $special / $( … ) / ${ … } / $(( … )) / $[ … ] / `…`)
			local e = c == "$" and (select(2, raw:find("^[%a_][%w_]*", k + 1)) or (nx:match("^[%d@*#?$!%-]$") and k + 1))
			if not e then
				local ok, x = pcall(P.expansion_end, raw, k, false, true)
				e = math.min(ok and x or n + 1, n + 1) - 1
			end
			local chunk = raw:sub(k, e)
			local v = e > k and expand_word(sh, P.parse_word('"' .. chunk .. '"')) or chunk
			-- inside a SUBSCRIPT an expansion's value is backslash-quoted against
			-- re-evaluation, as bash does for ] [ $ ` \ " ' ~ (`(( a[$k]++ ))` keys the
			-- literal text of $k); at top level `(( $expr ))` re-reads it as arithmetic
			if depth > 0 and e > k then
				v = v:gsub("[%]%[%$`\\\"'~]", "\\%0")
			end
			out[#out + 1] = v
			k = e + 1
		else
			local e = (raw:find('[\\"$`%[%]]', k) or (n + 1)) - 1
			out[#out + 1] = raw:sub(k, e)
			k = e + 1
		end
	end
	return table.concat(out)
end
function M.arith_textual_eval(sh, raw, depth0)
	local text = arith_expand_text(sh, raw, depth0)
	local pok, ast = pcall(P.arith, text, "strict")
	if not pok then -- the EXPANDED text isn't valid arithmetic: an arith error (bash), not a crash
		arith_pre(sh, ast)
		io.stderr:write("curse: " .. P.arith_errmsg(text, ast, depth0 ~= nil) .. "\n")
		error({ __curse_exit = 1, __curse_matherr = true, __curse_lineabort = true })
	end
	-- (this text is expansion OUTPUT: a `$key` subscript in it expands at evaluation, as
	-- bash's evalexp does — unquoted, unlike one written in the source; see arith_key)
	local sv = in_expanded_text
	in_expanded_text = true
	local ok, v = pcall(eval, sh, ast)
	in_expanded_text = sv
	if not ok then
		error(v, 0)
	end
	return v
end
-- The current value an `op=` / `++` / `--` reads: like a `var` node, a value that is an
-- expression is evaluated recursively (`x="1+2"; (( x *= 2 ))` is 6 — expr.c expr_streval)
local function arith_cur(sh, name, iv)
	if iv then
		return arith_resolve(sh, sh:array_get(name, iv))
	end
	local dn = sh:deref(name)
	if dn ~= name then -- (through a nameref: a circular one warns; one to an element
		rt.arith_ref_circ(sh, name, 1) -- reads that element)
		local ev = M.arith_ref_elem(sh, name)
		if ev then
			return ev
		end
	end
	local b = sh.vars[dn]
	if b and b.n ~= nil and b.s == nil and not b.arr then
		return b.n
	end
	return arith_resolve(sh, sh:get(name))
end
-- A short-circuited operand (`0 && …`, a ternary's untaken branch) is still PARSED — and
-- evaluated with noeval — as bash evaluates while parsing: noeval makes a variable 0 and
-- skips assignments and division by 0, but exppower has no noeval guard, so a negative
-- exponent is still an error (`$(( 0 && 2 ** -1 ))`). Only a subtree holding a `**` (the
-- parser's rpow mark) is walked; this returns its noeval value.
noeval_pow = function(e)
	local k = e.k
	if k == "num" then
		return rt.arith_num(e.v)
	elseif k == "asgn" then
		return noeval_pow(e.e)
	elseif k == "comma" then
		noeval_pow(e.l)
		return noeval_pow(e.r)
	elseif k == "un" then
		local v = noeval_pow(e.e)
		return e.op == "-" and -v or e.op == "!" and b2i(not truth(v)) or bit.bnot(v)
	elseif k == "tern" then
		local c = truth(noeval_pow(e.c))
		local a, b = noeval_pow(e.a), noeval_pow(e.b)
		return c and a or b
	elseif k == "bin" then
		local l, r, op = noeval_pow(e.l), noeval_pow(e.r), e.op
		if op == "**" then
			if r < 0 then
				arith_div0(e, "exponent less than 0")
			end
			return rt.ipow_raw(l, r)
		elseif op == "/" or op == "%" then
			if r == 0 then
				r = i64(1)
			end
			return op == "/" and l / r or l % r
		elseif op == "+" then
			return l + r
		elseif op == "-" then
			return l - r
		elseif op == "*" then
			return l * r
		elseif op == "&&" then
			return b2i(truth(l) and truth(r))
		elseif op == "||" then
			return b2i(truth(l) or truth(r))
		elseif op == "==" then
			return b2i(l == r)
		elseif op == "!=" then
			return b2i(l ~= r)
		elseif op == "<" then
			return b2i(l < r)
		elseif op == "<=" then
			return b2i(l <= r)
		elseif op == ">" then
			return b2i(l > r)
		elseif op == ">=" then
			return b2i(l >= r)
		elseif op == "&" then
			return bit.band(l, r)
		elseif op == "|" then
			return bit.bor(l, r)
		elseif op == "^" then
			return bit.bxor(l, r)
		elseif op == "<<" then
			return bit.lshift(l, tonumber(r) % 64)
		end
		return bit.arshift(l, tonumber(r) % 64) -- >>
	end
	return i64(0) -- var / ++ / -- / expansions: noeval reads nothing
end
-- bash evaluates arithmetic WHILE parsing it, so what came before a syntax error has run:
-- `let 'b=a++ +'` increments a. The parser hands the completed part as err.pre; evaluate
-- it before the error is reported (its own error — `1/0 + )` — wins, as in bash).
arith_pre = function(sh, err)
	if type(err) == "table" and err.pre then
		eval(sh, err.pre)
	end
end
eval = function(sh, e)
	local k = e.k
	if k == "matherr" then -- a deferred arith parse error (bad lvalue): non-fatal in (( ))
		arith_pre(sh, e.err)
		io.stderr:write("curse: " .. P.arith_errmsg(e.raw or "", e.err) .. "\n")
		error({ __curse_exit = 1, __curse_matherr = true })
	end
	if k == "num" then
		return rt.arith_num(e.v)
	end
	if k == "var" then
		if e.idxraw then
			arith_nounset(sh, e.name)
			if rt.arith_badraw(sh, e.name, e.idxraw, "r") then -- (non-fatal: 0)
				return i64(0)
			end
			local iv = arith_key(sh, e.name, e.idx, e.idxraw)
			if rt.arith_badkey(sh, e.name, iv, "r") then
				return i64(0)
			end
			return arith_resolve(sh, sh:array_get(e.name, iv))
		end
		arith_nounset(sh, e.name)
		-- Numeric-authoritative fast path: a scalar set via aset holds its i64 in b.n
		-- with b.s cleared. Reading it back through sh:get would stringify (i64_to_str)
		-- then arith_resolve would re-parse (arith_num) — a full round-trip per read in
		-- an arithmetic loop. Return b.n directly. Safe: b.n is only ever a non-integer
		-- (aget caching arith_num of a recursive expression) while b.s is still set, so
		-- the b.s==nil guard excludes that case and falls through to arith_resolve.
		local dn = sh:deref(e.name)
		if dn ~= e.name then -- (through a nameref: a circular one warns; one to an element
			rt.arith_ref_circ(sh, e.name, 1) -- reads that element)
			local ev = M.arith_ref_elem(sh, e.name)
			if ev then
				return ev
			end
		end
		local b = sh.vars[dn]
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
			-- ($name is expanded BEFORE evaluation in bash: if the expression also assigns,
			-- an in-order native read could see the new value — take the textual path)
			local assigns = rt.xpand_self_assign(e.raw)
			e.fast = not (
				assigns
				or e.raw:find("\\", 1, true)
				or e.raw:find("%$%(")
				or e.raw:find("`")
				or e.raw:find("%$[^%w_{]")
				or e.raw:find("[%w_]%$")
				or e.raw:find("}[%w_#]")
			)
		end
		if e.fast and e.native == nil then
			local nok, nat = pcall(P.arith, e.raw, true)
			e.native = nok and nat or false -- (unparseable raw: the textual path reports it)
		end
		if e.fast and e.native then
			local ok, r = pcall(eval, sh, e.native)
			if ok then
				return r
			end
			if not (type(r) == "table" and r.__arith_textual) then
				error(r)
			end
		end
		local sd = xpand_subdepth
		xpand_subdepth = nil -- (only this node is the subscript; nested ones say so themselves)
		return M.arith_textual_eval(sh, e.raw, sd)
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
			local v = eval(sh, e.a)
			if e.rpow then
				noeval_pow(e.b)
			end
			return v
		end
		if e.rpow then
			noeval_pow(e.a)
		end
		return eval(sh, e.b)
	end
	if k == "bin" then
		local op = e.op
		if op == "&&" then
			if not truth(eval(sh, e.l)) then
				if e.rpow then
					noeval_pow(e.r)
				end
				return i64(0)
			end
			return b2i(truth(eval(sh, e.r)))
		end
		if op == "||" then
			if truth(eval(sh, e.l)) then
				if e.rpow then
					noeval_pow(e.r)
				end
				return i64(1)
			end
			return b2i(truth(eval(sh, e.r)))
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
				arith_div0(e)
			end
			return l / r
		end
		if op == "%" then
			if r == i64(0) then
				arith_div0(e)
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
			if r < 0 then -- bash disallows a negative exponent (fatal arith error)
				arith_div0(e, "exponent less than 0")
			end
			return rt.ipow_raw(l, r)
		end
	end
	if k == "asgn" then
		local v = eval(sh, e.e) -- (bash evaluates the value BEFORE the lvalue's subscript)
		local iv, bad
		if e.idxraw then -- (a bad element reads 0 and stores nothing: rt.arith_badraw)
			local how = e.op == "=" and "w" or "rw"
			if e.op ~= "=" then
				arith_nounset(sh, e.name)
			end
			bad = rt.arith_badraw(sh, e.name, e.idxraw, how)
			if not bad then
				iv = arith_key(sh, e.name, e.idx, e.idxraw)
				bad = rt.arith_badkey(sh, e.name, iv, how)
			end
		end
		if e.op ~= "=" then
			arith_nounset(sh, e.name) -- `x += …` reads x first
			local cur = bad and i64(0) or arith_cur(sh, e.name, iv)
			local o = e.op:sub(1, #e.op - 1) -- strip the trailing '=' (`<<=` -> `<<`)
			if o == "+" then
				v = cur + v
			elseif o == "-" then
				v = cur - v
			elseif o == "*" then
				v = cur * v
			elseif o == "/" then
				if v == i64(0) then
					arith_div0(e)
				end
				v = cur / v
			elseif o == "%" then
				if v == i64(0) then
					arith_div0(e)
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
		if bad then
			return v
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
			local iv = not rt.arith_badraw(sh, e.name, e.idxraw, "rw") and arith_key(sh, e.name, e.idx, e.idxraw)
			if not iv or rt.arith_badkey(sh, e.name, iv, "rw") then -- (a bad element: 0, nothing stored)
				return i64(0)
			end
			local cur = arith_cur(sh, e.name, iv)
			sh:array_set(e.name, iv, rt.i64_to_str(cur + i64(e.d)))
			return cur
		end
		local cur = arith_cur(sh, e.name)
		sh:aset(e.name, cur + i64(e.d))
		return cur
	end
	if k == "pre" then
		arith_nounset(sh, e.name) -- ++x / --x read x first
		if e.idxraw then
			local iv = not rt.arith_badraw(sh, e.name, e.idxraw, "rw") and arith_key(sh, e.name, e.idx, e.idxraw)
			if not iv or rt.arith_badkey(sh, e.name, iv, "rw") then -- (a bad element: 0, nothing stored)
				return i64(e.d)
			end
			local v = arith_cur(sh, e.name, iv) + i64(e.d)
			sh:array_set(e.name, iv, rt.i64_to_str(v))
			return v
		end
		local v = arith_cur(sh, e.name) + i64(e.d)
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
		if sh.in_arithcmd and not v.__curse_subscript then -- (a subscript's error aborts)
			sh.arithfault = true
			return i64(0)
		end
		error({ __curse_exit = 1, __curse_lineabort = true, __curse_noee = true }) -- (DISCARD)
	end
	error(v)
end

-- Arithmetic through a nameref to an ELEMENT (`declare -n v='a[2]'`): bash's lookup
-- lands on that element, for the read and the store alike; `a[@]`/`a[*]` there is a
-- bad subscript (reported; the read is 0, the store dropped). store: the value to write.
-- Returns nil for a reference without a subscript (the caller's own path).
function M.arith_ref_elem(sh, name, store)
	local et = sh:deref_elem(name)
	local base, sub = (et or ""):match("^([%a_][%w_]*)%[(.*)%]$")
	if not base then
		return nil
	end
	if sub == "@" or sub == "*" then
		io.stderr:write("curse: " .. et .. ": bad array subscript\n")
		rt.report_exit(sh) -- (err_badarraysub: report_error)
		return store or i64(0)
	end
	local k = array_key(sh, base, sub)
	if store then
		sh:array_set(base, k, rt.i64_to_str(store))
		return store
	end
	return arith_resolve(sh, sh:array_get(base, k))
end

-- Compiled-tier fallback for `$name` arithmetic on a non-numeric value: expand the raw
-- arithmetic and re-parse it, exactly as bash substitutes the value's TEXT
-- (`x='1 + 2'; $(( $x*3 ))` -> 1 + 2 * 3).
function M.arith_textual(sh, raw)
	return M.arith_textual_eval(sh, raw)
end

-- An array subscript used in arithmetic: an associative array takes the
-- evaluated-then-stringified value as its key ("5"), an indexed array a number.
arith_key = function(sh, name, idxexpr, idxraw)
	-- An associative-array subscript in (( )) is a LITERAL string key (parameter-
	-- expanded and quote-removed), NOT an arith expression: `A[K]` -> key "K",
	-- `A[$k]` -> the value of k, `A['x']` -> "x". Reuse the normal key resolver.
	if sh:is_assoc(name) then
		if sh.arith_expanded then -- (already-expanded text, e.g. a [[ -eq ]] operand: the key
			return idxraw or "" -- is taken literally — bash's EXP_EXPANDED)
		end
		if sh.arith_let and sh.shopt.assoc_expand_once and not (idxraw or ""):find("[$`]") then
			return idxraw or "" -- (let's argument was expanded once already: `a[80's]` is literal)
		end
		return array_key(sh, name, idxraw or "")
	end
	-- (bash evaluates a subscript with this_command_name cleared: no `((: ` in its errors)
	local sv = P.arith_cmd
	P.arith_cmd = nil
	if idxexpr == nil then -- a non-arith subscript (e.g. quoted) on a NON-assoc array
		io.stderr:write("curse: " .. P.arith_errmsg(idxraw or "", select(2, pcall(P.arith, idxraw or ""))) .. "\n")
		P.arith_cmd = sv
		-- (array_expand_index: DISCARD, out of every eval/function level — see rt.int_value)
		error({ __curse_exit = 1, __curse_matherr = true, __curse_experr = true, __curse_lineabort = true,
			__curse_subscript = true, __curse_discard = true })
	end
	-- (an expansion in the subscript that needs bash's textual substitution is quoted as
	-- within a subscript: an error shows `0\],b\[1` — the xpand node reads this)
	local sd = xpand_subdepth
	xpand_subdepth = idxexpr.k == "xpand" and not in_expanded_text and 1 or nil
	local ok, v = pcall(eval, sh, idxexpr)
	xpand_subdepth = sd
	P.arith_cmd = sv
	if not ok then
		if type(v) == "table" and v.__curse_matherr and not v.__curse_subscript then
			-- a subscript's error abandons the whole line, even from (( )) or [[ ]] (bash)
			-- (arrayfunc.c array_expand_index: top_level_cleanup + DISCARD — see rt.int_value)
			v = { __curse_exit = 1, __curse_matherr = true, __curse_lineabort = true, __curse_subscript = true,
				__curse_discard = true }
		end
		error(v, 0)
	end
	return rt.to_arr_key(v)
end

-- Resolve an array subscript to a key: a string (word-expanded) for an
-- associative array, else an integer (arith-evaluated) for an indexed one.
array_key = function(sh, name, index_raw)
	if sh:is_assoc(name) then
		return expand_word(sh, notilde(P.parse_word(index_raw))) -- (5.2.21: no tilde; see notilde)
	end
	-- indexed: arith-evaluate the subscript. Parse the RAW subscript with arith (its
	-- defer/xpand handles $()/$vars) rather than word-expanding it first, so bash's
	-- arith quote rules apply — a double-quote PAIR strips to its content (`a["3"]`),
	-- a SINGLE quote is a syntax error (`a['3']` -> status 1, assignment skipped).
	if index_raw:match("^%s*$") or index_raw:match('^%s*"%s*"%s*$') then
		return 0 -- (a blank subscript, double-quoted or not, is 0)
	end
	if index_raw == "@" or index_raw == "*" then -- (`ia[@]=x`: no such element of an indexed array)
		io.stderr:write("curse: " .. name .. "[" .. index_raw .. "]: bad array subscript\n")
		rt.report_exit(sh) -- (err_badarraysub: report_error)
		error({ __curse_exit = 1, __curse_lineabort = true })
	end
	local sv = P.arith_cmd
	P.arith_cmd = nil -- (a subscript's errors carry no command name: bash)
	local ok, v = pcall(function()
		return rt.to_arr_key(eval(sh, P.arith(index_raw)))
	end)
	if not ok then
		P.arith_cmd = sv
		if type(v) == "table" and v.__curse_unbound then
			error(v, 0) -- (set -u: said already, and fatal as it is — no syntax error on top)
		end
		if type(v) == "table" and v.pre and not v.__curse_matherr then
			-- (a syntax error: what bash evaluated before it ran first — `[x+]` with x holding
			-- a bad expression reports x's error, not the `+`)
			local pok, pe = pcall(arith_pre, sh, v)
			if not pok then
				if type(pe) == "table" and pe.__curse_unbound then
					error(pe, 0)
				end
				v = pe
			end
		end
		if not (type(v) == "table" and v.__curse_matherr) then -- (an eval error already said so)
			io.stderr:write("curse: " .. P.arith_errmsg(index_raw, v) .. "\n")
		end
		-- an expansion error discards the rest of the top-level line (bash jump_to_top_level
		-- after top_level_cleanup: out of every function/eval/source level — rt.int_value)
		error({ __curse_exit = 1, __curse_lineabort = true, __curse_discard = true })
	end
	P.arith_cmd = sv
	return v
end

-- Does `$(( TEXT ))` hold a shell comment — an unquoted `#` after a blank,
-- running to the end (extract_command_subst's SX_COMMAND comment rule)?
local function arith_comment(t)
	local k, n, q = 1, #t, nil
	while k <= n do
		local c = t:sub(k, k)
		if q then
			if c == q then
				q = nil
			elseif c == "\\" and q == '"' then
				k = k + 1
			end
		elseif c == "'" or c == '"' then
			q = c
		elseif c == "\\" then
			k = k + 1
		elseif c == "#" and t:sub(k - 1, k - 1):match("^[ \t\n]$") then
			return not t:find("\n", k, true)
		end
		k = k + 1
	end
	return false
end

-- Expand ONE part to its string value (a multi-element @/* part is joined here;
-- expand_to_fields treats those specially for word-splitting).
-- (the branches that make closures live in their own functions: a closure capturing
-- `sh` would make every return of expand_part_str close an upvalue — NYI for the JIT,
-- so the plain $var / literal paths could never compile)
local expand_part_str -- (forward: the ${…} branch recurses into it)
local function expand_procsub(sh, p)
	-- <(cmd) / >(cmd): run cmd asynchronously on a pipe and substitute /dev/fd/N for
	-- the shell's end of it (bash: 63, then 62, …) — a real pipe, so the data is read
	-- once and a reader can start before the writer ends. The end stays open (and is
	-- inherited) until the command it was expanded for finishes (drain_procsub).
	-- (in-process: a background task — Shell:bg_launch — whose stdout/stdin is the
	-- pipe's other end)
	local pfd = ffi.new("int[2]")
	if rt.pipe_hi(pfd) ~= 0 then -- (high: the job must not start with a copy of our end)
		return "/dev/null"
	end
	local mine, theirs = pfd[p.dir == "<" and 0 or 1], pfd[p.dir == "<" and 1 or 0]
	local body = p.procsub
	-- (its body numbers its lines from the command's, as a $(…)'s does: bash parses it in
	-- place — compiled code's line is found on the stack here, not in the job)
	local _, l0 = rt.err_where(sh)
	local job = sh:bg_launch(function(ssh)
		ssh.cur_line = l0 > 0 and l0 or ssh.cur_line
		local stmts = P.parse(body, nil, nil, nil, nil, l0 > 0 and l0 or nil).stmts
		local s1 = #stmts == 1 and stmts[1]
		if s1 and s1.t == "simple" and #(s1.words or {}) == 0 and s1.redirs and #s1.redirs == 1
			and s1.redirs[1].op == "in" and not s1.assigns then
			-- <(< file): the file's contents, like $(< file) (bash 5.2)
			local path = M.expand_assign_word(ssh, P.parse_word(s1.redirs[1].target or ""))
			local f, _, en = io.open(path, "rb")
			if f then
				ssh.out(f:read("*a") or "")
				f:close()
				ssh.status = 0
			else
				rt.read_fail(path, en)
				ssh.status = 1
			end
			return
		end
		M.exec_list(ssh, stmts, SUBHOOK, false)
	end, "procsub", false, false, nil, nil,
		{ fds = { [p.dir == "<" and 1 or 0] = theirs }, keepstdin = true, nojob = true })
	C.close(theirs)
	local fd = rt.fd_below(mine, 64)
	rt.fd_register(fd, sh) -- (only this shell's own spawns inherit it — and its later clones')
	sh.procsub_files = sh.procsub_files or {}
	sh.procsub_files[#sh.procsub_files + 1] = { fd = fd, pid = job and job.pid or 0, g = job and job.g }
	return "/dev/fd/" .. fd
end
local function expand_pexp(sh, p, assign)
	local pe = p.pexp
	if pe.op == "badsubst" then -- ${x|html} and other unrecognized ${…} forms
		if pe.fatal then
			sherr(sh, "curse: " .. (sh.bs_word and sh.bs_depth == sh.subdepth and sh.bs_word or pe.wraw or ("${" .. (pe.raw or pe.name or "") .. "}")) .. ": bad substitution\n")
			error({ __curse_exit = sh.opt_c and 127 or 1, __curse_lineabort = sh.opt_i or nil })
		end
		if pe.xform then -- ${x@Z}: nothing to transform on an unset x; else FATAL (bash)
			local set
			if pe.index then
				local k, b = array_key(sh, pe.name, pe.index), sh.vars[sh:deref(pe.name)]
				set = b and b.arr and b.arr[k] ~= nil or (not (b and b.arr) and k == 0 and rt.var_has_value(sh, pe.name))
			else
				set = rt.var_has_value(sh, pe.name)
			end
			if not set then
				return ""
			end
			sherr(sh, "curse: " .. (sh.bs_word and sh.bs_depth == sh.subdepth and sh.bs_word or pe.wraw or ("${" .. (pe.raw or pe.name or "") .. "}")) .. ": bad substitution\n")
			error({ __curse_exit = sh.opt_c and 127 or 1, __curse_lineabort = sh.opt_i or nil })
		end
		sherr(sh, "curse: " .. (sh.bs_word and sh.bs_depth == sh.subdepth and sh.bs_word or pe.wraw or ("${" .. (pe.raw or pe.name or "") .. "}")) .. ": bad substitution\n")
		error({ __curse_exit = 1, __curse_lineabort = true }) -- discards the rest of the line (bash)
	end
	if pe.op == "@" and pe.arg == "P" then -- ${x@P}: decode prompt escapes, then expand
		return M.prompt_string(sh, sh:get_u(pe.name)) -- get_u: honor set -u
	end
	-- ${ref OP…} through a nameref to an ELEMENT (`declare -n f='a[1]'`) operates on
	-- that element, not the base's [0]: retarget the expansion at it
	local rb = not pe.index and pe.op ~= "indirect" and type(pe.name) == "string" and sh.vars[pe.name]
	local et = rb and rb.ref and sh:deref_elem(pe.name)
	if et and pe.op == "len" then
		return "0" -- (bash's ${#ref} to an element-target nameref: its length shortcut sees no value)
	end
	if et then
		local eb, esub = et:match("^([%a_][%w_]*)%[(.+)%]$")
		if eb then
			pe = setmetatable({ name = eb, index = esub }, { __index = pe })
		end
	end
	if pe.op == "indirect" then -- ${!ref} / ${!ref OP}: resolve the name, then expand it
		local ip = indirect_part(sh, pe)
		if not ip then
			return ""
		end
		ip.q = p.q
		return expand_part_str(sh, ip)
	end
	local op = pe.op
	if (op == "prefix" or op == "indices") and not pe.hdoc then
		-- ${!pfx*} / ${!a[*]} in a scalar context (assignment, case word, [[ ]]) join with
		-- IFS[0] like "$*"; ${!pfx@} too in an assignment (bash); ${!a[@]} with a space.
		-- (a here-document's are space-joined: the Shell:expand_param default below)
		if (op == "prefix" and (pe.star or assign)) or (op == "indices" and pe.index == "*") then
			return table.concat((multi_elems(sh, p)), rt.ifs_sep(sh))
		end
	elseif op == "sub" and (pe.index == "@" or pe.name == "@") then
		-- ${@:n} / ${a[@]:n:m} in a scalar context is the ELEMENT slice, joined with a
		-- space — IFS[0] for a quoted one in an assignment (`y="${@:2}"`), as bash does
		return table.concat((multi_elems(sh, p)), (assign and p.q) and rt.ifs_sep(sh) or " ")
	elseif assign and (pe.index == "@" or pe.name == "@") and op
		and (" # ## % %% / // ^ ^^ , ,, ~ ~~ @ "):find(" " .. op .. " ", 1, true) then
		-- an assignment's ${@#pat} / ${a[@]@Q} / ${@/p/r} / ${a[@]^^} work per element,
		-- joined with IFS[0] — a strip or transform even unquoted, else a space (bash)
		local sep = (p.q or op == "@" or op:find("^[#%%]")) and rt.ifs_sep(sh) or " "
		return table.concat((multi_elems(sh, p)), sep)
	end
	if (pe.index == "*" or pe.name == "*") and op ~= "prefix" and op ~= "indices" and op ~= "len" then
		-- ${a[*]OP} / ${*OP} in a scalar context (assignment RHS, case word) joins its
		-- (per-element transformed) values with IFS[0], like "$*" (bash) — a here-doc's
		-- positional ${*…} with a space
		local els = multi_elems(sh, p)
		return table.concat(els, (pe.hdoc and pe.name == "*") and " " or rt.ifs_sep(sh))
	end
	local subkey
	if pe.index and pe.index ~= "@" and pe.index ~= "*" then
		subkey = array_key(sh, pe.name, pe.index)
		if pe.op ~= "len" then
			rt.elem_read_check(sh, pe.name, subkey)
		end
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
		or pe.op == ",,"
		or pe.op == "~"
		or pe.op == "~~" -- case-fold pattern
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
		arg = pe.arg and pe.arg ~= "" and function() -- (no word: nil, for ${x?}'s own message)
			if assign then
				return expand_assign_word(sh, pw(pe.arg))
			end
			return expand_word(sh, pw(pe.arg), true)
		end or nil
	elseif pe.op ~= "sub" then -- (a substring's offset is expanded below — not when the var is unset)
		arg = pe.arg and (patmode and expand_pattern or expand_word)(sh, P.parse_word(pe.arg), true) or nil
	end
	local arg2 = pe.arg2 and pe.op ~= "sub" and expand_repl(sh, P.parse_word(pe.arg2)) or nil
	if pe.op == "sub" and not pe.index and rt.sub_unset(sh, pe.name) then
		return ""
	elseif pe.op == "sub" then -- ${v:off:len}: offset/length are arithmetic expressions,
		-- expanded the arithmetic way (bash: `${s:A[$k]}` quotes $k inside the subscript)
		arg = pe.arg and tostring(rt.substr_arith(sh, rt.pe_label(pe), arith_expand_text(sh, pe.arg)) or 0) or nil
		arg2 = pe.arg2 and tostring(rt.substr_arith(sh, rt.pe_label(pe), arith_expand_text(sh, pe.arg2)) or 0) or nil
	elseif not TESTOP[pe.op] then
		-- a word-initial ~ in a pattern / replacement expands (${p//~/z}, ${p#~/x}) — a
		-- pattern's own (unquoted-only) tilde is expand_pattern's: a quoted `\~`/"~" is literal
		if type(arg) == "string" and not patmode then
			arg = tilde_prefix(sh, arg)
		end
	end
	return sh:expand_param(pe, arg, arg2, subkey)
end
expand_part_str = function(sh, p, assign)
	if p.lit ~= nil then
		return p.lit
	elseif p.bterr or p.nulcut then -- (a brace range's unclosed backquote: bq_word in the
		-- parser; a word cut at a $'…' NUL: parser.dq_nulcut)
		sherr(sh, p.bterr and ('curse: bad substitution: no closing "`" in ' .. p.bterr .. "\n")
			or ("curse: bad substitution: no closing `}' in " .. p.nulcut .. "\n"))
		-- (a plain line abort, as ${x!}: bash's report_error + expand_word_error DISCARD,
		-- which an eval/source's parse_and_execute contains — the rest of ITS line only)
		error({ __curse_exit = 1, __curse_lineabort = true })
	elseif p.var then
		-- a nameref whose target has a subscript (`typeset -n ref='a[2]'`) reads as
		-- ${a[2]} — deref only yields the base name, so expand the target here.
		local rb = sh.vars[p.var]
		local et = rb and rb.ref and sh:deref_elem(p.var)
		if et then -- (at the end of a ref chain too: one -> qux -> 'bar[3]')
			return expand_word(sh, P.parse_word("${" .. et .. "}"))
		end
		local dn = sh:deref(p.var)
		if (dn == "" and not rt.ref_too_deep(sh, p.var)) or (rb and rb.outer) then -- a circular ref chain reads as nothing, with bash's
			io.stderr:write("curse: warning: " .. p.var .. ": circular name reference\n") -- warning
		end -- (a function's self-named ref warns too, then reads the shadowed var)
		local b = sh.vars[dn]
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
			io.stderr:write("curse: " .. (p.uname or p.var) .. ": unbound variable\n")
			error({ __curse_exit = sh.opt_c and 127 or 1, __curse_lineabort = sh.opt_i or nil })
		end
		return sh:get(p.var)
	elseif p.param then
		if sh.opt_u and p.param > sh.nparams then
			io.stderr:write("curse: " .. (p.braced and "" or "$") .. p.param .. ": unbound variable\n")
			error({ __curse_exit = sh.opt_c and 127 or 1, __curse_lineabort = sh.opt_i or nil })
		end
		return sh:param(p.param)
	elseif p.special then
		local v
		if p.special == "#" then
			v = tostring(sh.nparams)
		elseif p.special == "*" then -- $* joins on the first IFS char; $@ always on a space
			v = sh:paramsJoin(p.hdoc and " " or rt.ifs_sep(sh)) -- (a here-doc's: a space)
		elseif p.special == "@" then
			v = sh:paramsJoin(" ")
		elseif p.special == "?" then
			v = tostring(sh.status)
		elseif p.special == "$" then
			v = tostring(sh:pid())
		elseif p.special == "!" then
			v = p.lenof and (sh.last_bg_pid or "") or rt.last_bg_u(sh, p.braced)
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
				if not p.bracket and arith_comment(p.arith) then
					-- (bash extracts `$((…))` as a command substitution at expansion time, where
					-- a blank-preceded `#` starts a comment that hides the closing parens)
					io.stderr:write("curse: bad substitution: no closing `)' in $((" .. p.arith .. "))\n")
					error({ __curse_exit = 1, __curse_experr = true, __curse_lineabort = true })
				end
				arith_pre(sh, ast) -- (after what was evaluated before it)
				io.stderr:write("curse: " .. P.arith_errmsg(p.arith, ast) .. "\n")
				-- (an expansion error: bash discards the rest of the line)
				error({ __curse_exit = 1, __curse_matherr = true, __curse_experr = true, __curse_lineabort = true })
			end
			p.arith_ast = ast
		end
		return rt.i64_to_str(eval(sh, p.arith_ast))
	elseif p.procsub then
		return expand_procsub(sh, p)
	elseif p.cmdsub then
		return sh:capture_src(p.cmdsub, p.backtick, p.noalias)
	elseif p.pexp then
		return expand_pexp(sh, p, assign)
	end
	return ""
end

-- Expand a word to a single string (assignment RHS, case subject, arith index —
-- contexts that do NOT word-split).
-- Tilde expansion lives in runtime.lua (pure runtime: HOME/PWD/OLDPWD + passwd db).
-- interp aliases it locally; both tiers share the runtime version.
tilde_prefix = rt.tilde_prefix

-- Assignment-RHS and word-initial tilde expansion also live in runtime.lua; interp
-- aliases them locally for its expansion paths.
local tilde_assign = rt.tilde_assign
local tilde_word_initial = rt.tilde_word_initial


-- `noassign`: a ${…} operand — only a word-initial ~ expands there, never the `NAME=…:~`
-- assignment form (bash: `${x:=P=~/b}` keeps its tildes)
expand_word = function(sh, w, noassign)
	local buf = {}
	for k, p in ipairs(w.parts) do
		local s = expand_part_str(sh, p)
		if k == 1 and p.lit ~= nil and not p.q and not w.notilde then
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
		local s = expand_part_str(sh, p, not w.notilde) -- assignment context: ${-default} tilde after ':'
		if p.lit ~= nil and not p.q and not w.notilde then
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
-- bash 5.2.21's expand_subscript_string (W_NOTILDE): an ASSOCIATIVE array's subscripts —
-- `a[~]=v`, `${a[~]}`, `unset 'a[~]'`, a compound `([~]=v)` — and its compound-assignment
-- VALUES (`([k]=~)`, a key/value list `(k ~)`) are expanded with NO tilde expansion.
-- (bash 5.2 patch 24 turned tildes back on there; curse is 5.2.21, bug for bug.) A word
-- marked `notilde` (a copy — parse results are shared) expands like that everywhere:
-- expand_word, expand_assign_word, the compiled tier's emit_word and EF.tilde_value.
notilde = function(w)
	if w.notilde then
		return w
	end
	local c = {}
	for k, v in pairs(w) do
		c[k] = v
	end
	c.notilde = true
	return c
end
M.notilde = notilde

-- Expand a word, backslash-escaping the metacharacters in `charclass` for any
-- QUOTED part (so they match literally) while leaving unquoted parts — including
-- unquoted $var expansions — active. Matches bash's rule that quoting, not the
-- value, decides literalness. Shared by glob-pattern and =~-regex expansion.
-- `xt` (a table; set -x of a [[ ]] pattern): xt[1] gets the text bash traces, EVERY quoted
-- character backslashed (quote_string_for_globbing), from the same single expansion.
local PAT_META = "[%*%?%[%]\\%(%)%|%+%@%!%-%^]"
local function expand_escaped(sh, w, charclass, xt)
	local buf, xb = {}, xt and {}
	for _, p in ipairs(w.parts) do
		local s = expand_part_str(sh, p)
		if p.q then
			if xb then
				xb[#xb + 1] = rt.xglob_quote(s)
			end
			s = charclass == PAT_META and rt.glob_quote(s) or s:gsub(charclass, "\\%0")
		elseif xb then
			xb[#xb + 1] = s
		end
		buf[#buf + 1] = s
	end
	if xb then
		xt[1] = table.concat(xb)
	end
	return table.concat(buf)
end
-- ${v/pat/REPL} replacement: a word-initial UNQUOTED `~` tilde-expands (even inside "…",
-- bash); with shopt patsub_replacement a QUOTED `&`/`\` — and the tilde's directory — is
-- backslash-marked so apply_str_op's `&` substitution leaves it literal (bash's
-- quote_string_for_repl).
local REPL_META = "[&\\]"
expand_repl = function(sh, w)
	local amp = sh.shopt.patsub_replacement ~= false -- (on by default)
	local buf = {}
	for i, p in ipairs(w.parts) do
		local s = expand_part_str(sh, p)
		if p.q then
			s = amp and s:gsub(REPL_META, "\\%0") or s
		elseif i == 1 and p.lit and s:sub(1, 1) == "~" then
			local t = tilde_prefix(sh, s)
			if amp and t ~= s then
				local tail = s:match("^~[^/]*(.*)$") or ""
				t = t:sub(1, #t - #tail):gsub(REPL_META, "\\%0") .. tail
			end
			s = t
		end
		buf[#buf + 1] = s
	end
	return table.concat(buf)
end
-- glob PATTERN context (${v/pat/repl}, case, [[ == ]]): glob metacharacters.
expand_pattern = function(sh, w, xt)
	if xt == true then
		xt = nil -- (a caller sharing expand_word's signature passes its `true` flag)
	end
	-- a word-initial `~` tilde-expands (bash: `case ~ in ~)`), and the directory it
	-- yields matches literally
	local p1 = w.parts[1]
	if p1 and p1.lit and not p1.q and p1.lit:sub(1, 1) == "~" then
		local s = expand_part_str(sh, p1)
		local t = tilde_word_initial(sh, s, #w.parts > 1, true)
		if t ~= s then
			local rest = expand_escaped(sh, { parts = { unpack(w.parts, 2) } }, PAT_META, xt)
			local tail = s:match("^~[^/]*(.*)$") or ""
			local dir = rt.glob_quote(t:sub(1, #t - #tail))
			if xt then -- (the expanded directory reads as quoted)
				xt[1] = rt.xglob_quote(t:sub(1, #t - #tail)) .. tail .. xt[1]
			end
			return dir .. tail .. rest
		end
	end
	return expand_escaped(sh, w, PAT_META, xt)
end
-- A case-clause pattern: bash expands it as ONE word (execute_case_command:
-- expand_word_leave_quoted, then es->word->word), so a quoted "$@"/"${a[@]}" contributes
-- only its first element and ends the pattern there when more follow (`x"$@"y` with
-- `a b` is `xa`) — except under IFS="", where the elements join with a space.
local function case_pattern(sh, w)
	local at = false
	for _, p in ipairs(w.parts) do
		if p.q and (p.special == "@" or (p.pexp and (p.pexp.name == "@" or p.pexp.index == "@"))) then
			at = true
			break
		end
	end
	if not at or rt.ifs(sh) == "" then
		return expand_pattern(sh, w)
	end
	local buf = {}
	for _, p in ipairs(w.parts) do
		if p.q and is_multi(sh, p) then
			local els, star = multi_elems(sh, p)
			if star then
				buf[#buf + 1] = rt.glob_quote(table.concat(els, rt.ifs_sep(sh)))
			elseif #els > 0 then
				buf[#buf + 1] = rt.glob_quote(els[1])
				if #els > 1 then
					break
				end
			end
		else
			local s = expand_part_str(sh, p)
			buf[#buf + 1] = p.q and rt.glob_quote(s) or s
		end
	end
	return table.concat(buf)
end
-- A case-clause pattern word's glob form, for rt.case_glob (the compiled tier's case codegen
-- matches through it: vars in a pattern expand; quoted metachars stay literal).
M.case_pattern = case_pattern
-- `=~` regex context: ERE metacharacters.
-- Quoted text is escaped to match literally — except INSIDE a bracket expression, where
-- bash inserts it raw (`["."]` is `[.]`, `[\.]` too; `[']']` is `[]]`), so the builder
-- tracks bracket state through the unquoted text.
local REGEX_META = "[%.%^%$%*%+%?%(%)%[%]%{%}%|\\]"
local function expand_regex(sh, w)
	local buf, inbr, brstart = {}, false, false
	for _, p in ipairs(w.parts) do
		local s = expand_part_str(sh, p)
		if p.q then
			if inbr then
				if s ~= "" then
					brstart = false
				end
			else
				s = s:gsub(REGEX_META, "\\%0")
			end
			buf[#buf + 1] = s
		else
			local k, n = 1, #s
			while k <= n do
				local ch = s:sub(k, k)
				if not inbr then
					if ch == "\\" then
						k = k + 1 -- (an escaped char is literal, outside brackets)
					elseif ch == "[" then
						inbr, brstart = true, true
					end
				elseif brstart and ch == "^" then
					-- (still at the start: a following `]` is literal)
				elseif brstart and ch == "]" then
					brstart = false
				elseif ch == "[" and s:sub(k + 1, k + 1):match("^[:.=]$") then
					local close = s:find(s:sub(k + 1, k + 1) .. "]", k + 2, true)
					k = close and close + 1 or k
					brstart = false
				elseif ch == "]" then
					inbr = false
				else
					brstart = false
				end
				k = k + 1
			end
			buf[#buf + 1] = s
		end
	end
	return table.concat(buf)
end

-- A part that expands to multiple elements: $@ / $* / ${a[@]} / ${a[*]} /
-- ${!a[@]} (keys). ${#a[@]} (op="len") is a single count, NOT multi.
-- ${!ref}: the name/expression `ref` indirects to (its value, or a nameref's
-- target), with any trailing operator (iop) appended. Re-parsed into a part so
-- the target can itself be an array (arr[@]), $@, a subscript, etc.
-- ${!ref OP} whose ref has no value (an unset positional, `declare v`, `a=()`): OP still
-- applies, to an unset parameter (`${!v:-z}` is z, `${!v:?e}` says `!v: e`). Built as a
-- positional past $#, which is unset; nil (empty) when there is no operator.
local function valueless_part(sh, pe)
	if not pe.iop then
		return nil
	end
	local ok, part = pcall(P.parse_paramexp, tostring(sh.nparams + 1) .. pe.iop)
	if not ok or not part then
		return nil
	end
	local uname = "!" .. rt.pe_label(pe)
	part.uname = uname
	if part.pexp then
		part.pexp.uname = uname
	end
	return part
end
-- (`quiet`: only probing the shape — is_multi — so a bad subscript isn't reported twice)
indirect_part = function(sh, pe, quiet)
	local tname
	if pe.index == "@" or pe.index == "*" then
		-- ${!name[@]OP}: the reference name is ${name[@]} space-joined (a single
		-- element derefs cleanly; several join to a name with spaces = invalid).
		tname = table.concat(sh:array_values(pe.name), " ")
	elseif pe.index then
		local key = array_key(sh, pe.name, pe.index)
		if not quiet then
			rt.elem_read_check(sh, pe.name, key) -- (`${!b[-9]}`: b: bad array subscript)
		end
		tname = sh:array_get(pe.name, key)
		if tname == "" and not sh:is_elem_set(pe.name, key) then
			tname = nil -- (an unset element: no value, unlike a set empty one)
		end
	else
		local b = sh.vars[pe.name]
		-- ${!ref} on a NAMEREF is inverted: it yields the target NAME, not its value.
		if b and b.ref and b.s and not pe.iop then
			return { lit = b.s }
		end
		if pe.name:match("^%d+$") then
			tname = sh:param(tonumber(pe.name)) -- ${!1}: positional
		elseif pe.name == "#" then
			tname = tostring(sh.nparams) -- ${!#}: the last positional (or $0)
		elseif pe.name == "@" or pe.name == "*" then
			tname = sh:paramsJoin(" ") -- ${!@}: the params joined name the target
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
		if pe.name and (pe.name:match("^%d+$") or pe.name == "@" or pe.name == "*") then
			return valueless_part(sh, pe)
		end
		local bb = pe.name and sh.vars[sh:deref(pe.name)] -- (through a nameref: its target)
		if bb and not bb.ref then
			-- a ref whose VALUE is set but empty (`x=; ${!x}`, `a=(''); ${!a}`, an empty
			-- element or ${!a[@]OP} over ('')) names no variable; one with no value at all
			-- (`declare v`, `declare -A A`, `a=()`, an unset element) expands to empty
			local setempty
			if tname == nil then
				setempty = false
			elseif pe.index then
				setempty = pe.index ~= "@" and pe.index ~= "*" or (bb.arr ~= nil and next(bb.arr) ~= nil)
			elseif bb.arr then
				setempty = (bb.assoc and bb.arr["0"] or bb.arr[0]) ~= nil
			else
				setempty = bb.s ~= nil or bb.n ~= nil
			end
			if setempty then
				io.stderr:write("curse: : invalid variable name\n")
				error({ __curse_exit = 1, __curse_lineabort = true })
			end
			return valueless_part(sh, pe)
		end
		io.stderr:write("curse: " .. (pe.name and rt.pe_label(pe) or "") .. ": invalid indirect expansion\n")
		if sh.opt_u then
			error({ __curse_exit = sh.opt_c and 127 or 1, __curse_lineabort = sh.opt_i or nil })
		end
		error({ __curse_exit = 1, __curse_lineabort = true })
	end
	-- ${!ref} to a special parameter: $?, $$, $!, $#, $-, $N, $@, $*
	local numeric = tname:match("^%d+$")
	local special = #tname == 1 and tname:match("[%?%$!#%-@%*]")
	if not pe.iop then
		if numeric then
			return { param = tonumber(tname) }
		end
		if special then
			return { special = tname }
		end
	end
	-- The resolved target must be a valid variable reference: an identifier,
	-- optionally with ONE [subscript] ending the name (valid_array_reference).
	-- Anything else (spaces, `/`, `a[`, `a[1]x`, `a[]`) is invalid.
	local base = not numeric and not special and tname:match("^[%a_][%w_]*")
	if not (numeric or special) then
		local bad = not base
		if not bad and #tname > #base then
			if tname:sub(#base + 1, #base + 1) ~= "[" or tname:sub(-1) ~= "]" or #tname == #base + 2 then
				bad = true
			else -- the `[` must close exactly at the end
				local depth = 0
				for k = #base + 1, #tname do
					local c = tname:byte(k)
					if c == 91 then
						depth = depth + 1
					elseif c == 93 then
						depth = depth - 1
						if depth == 0 and k < #tname then
							bad = true
							break
						end
					end
				end
			end
		end
		if bad then
			io.stderr:write("curse: " .. tname .. ": invalid variable name\n")
			error({ __curse_exit = 1, __curse_lineabort = true })
		end
	end
	local ok, part = pcall(P.parse_paramexp, tname .. (pe.iop or ""))
	-- Mark the reconstructed part as coming through indirection: bash's `:-`/`:+`
	-- null test on an array reached via `${!ref:-…}` keys on the element COUNT
	-- (zero = null), unlike the DIRECT `${a[@]:-…}` which treats one empty element
	-- as null. (The `-`/`:+`-less `-` variant is already count-based for both.)
	if ok and part and part.pexp then
		part.pexp.via_indirect = true
	end
	-- set -u names the REFERENCE, as written: `!bar: unbound variable`
	local uname = "!" .. rt.pe_label(pe)
	if ok and part then
		part.uname = uname
		if part.pexp then
			part.pexp.uname = uname
		end
	end
	return ok and part or nil
end
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
		local ip = indirect_part(sh, p.pexp, true)
		return ip ~= nil and is_multi(sh, ip)
	end
	-- $@/$* live in pexp.name (e.g. ${@:1}); array [@]/[*] live in pexp.index
	return p.pexp.index == "@" or p.pexp.index == "*" or p.pexp.name == "@" or p.pexp.name == "*"
end
-- Does this multi part make bash split its word as has_dollar_at (list_string on the
-- whole word with quoted=1: leading IFS whitespace is then a delimiter of its own, so
-- `IFS=': '; x=' :a'; set -- $x"$@"` has no empty first field)? param_expand /
-- parameter_brace_expand / chk_atstar set contains_dollar_at for every @ form, quoted or
-- not, for an unquoted $* and ${a[*]} (with any operator) — but not for ${*…}, ${!a[*]},
-- ${!pfx*} or a quoted * form; ${!ref} as its target.
local DEFAULT_OPS = { [":-"] = true, ["-"] = true, [":+"] = true, ["+"] = true }
-- ...and inside a ${x:-word} word bash expands (parameter_brace_expand_rhs): any @ form —
-- a quoted one only when it has elements — never a * form.
local function word_hda(sh, w, q)
	for _, sp in ipairs(w.parts) do
		if is_multi(sh, sp) then
			local sq = sp.q or q
			local pe = sp.pexp
			local star = sp.special == "*" or (pe and (pe.name == "*" or pe.index == "*" or pe.star))
			if not star then
				if not sq then
					return true
				end
				local c = { special = sp.special, pexp = pe, q = true }
				if #(multi_elems(sh, c)) > 0 then
					return true
				end
			end
		end
	end
	return false
end
-- does a (non-multi) ${x:-word}-style part's taken branch have the word — and does that
-- word make the whole word has_dollar_at (multi_hda)?
local function default_hda(sh, p)
	local pe = p.pexp
	if not (pe and DEFAULT_OPS[pe.op] and pe.arg and pe.arg:find("@", 1, true)) or pe.index then
		return false
	end
	local pn = tonumber(pe.name)
	local val, set
	if pn then
		set, val = pn == 0 or pn <= sh.nparams, sh:param(pn)
	else
		local b = sh.vars[sh:deref(pe.name)]
		if b and b.arr then
			set = b.arr[0] ~= nil or b.arr["0"] ~= nil
		else
			set = b ~= nil and (b.s ~= nil or b.n ~= nil)
		end
		val = sh:get(pe.name)
		set = set or sh:special_get(pe.name) ~= ""
	end
	local use
	if pe.op == ":-" then
		use = val == ""
	elseif pe.op == "-" then
		use = not set
	elseif pe.op == ":+" then
		use = val ~= ""
	else
		use = set
	end
	if not use then
		return false
	end
	if p.q then
		return word_hda(sh, P.parse_default_quoted(pe.arg, pe.hd), true)
	end
	return word_hda(sh, P.parse_word(pe.arg), false)
end
multi_hda = function(sh, p)
	local pe = p.pexp
	if not pe then
		return p.braced and p.special == "@" or not p.braced and (p.special == "@" or not p.q)
	end
	if DEFAULT_OPS[pe.op] and (pe.name == "@" or pe.index == "@") then
		-- ${a[@]:-w}: the value branch is an @ expansion; the word branch, its word's
		local els = pe.name == "@" and sh:paramList() or sh:array_values(sh:deref(pe.name))
		local set = #els > 0
		local ne = #els > 1 or (set and els[1] ~= "")
		local val -- (the value itself is returned)
		if pe.op == ":-" then
			val = ne
		elseif pe.op == "-" then
			val = set
		elseif pe.op == ":+" then
			val = not ne
		else
			val = not set
		end
		if val then
			return true
		end
		if not pe.arg then
			return false
		end
		if p.q then
			return word_hda(sh, P.parse_default_quoted(pe.arg, pe.hd), true)
		end
		return word_hda(sh, P.parse_word(pe.arg), false)
	end
	if pe.op == "indirect" then
		local ip = indirect_part(sh, pe, true)
		if not ip then
			return false
		end
		ip.q = p.q
		return is_multi(sh, ip) and multi_hda(sh, ip)
	end
	if pe.op == "prefix" then
		return not pe.star
	end
	if pe.op == "indices" then
		return pe.index == "@"
	end
	if pe.name == "@" or pe.index == "@" then
		return true
	end
	return pe.index == "*" and not p.q
end
multi_elems = function(sh, p) -- returns element list, star?
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
			sherr(sh, "curse: " .. (pe.wraw or "${" .. (pe.raw or pe.name or "") .. "}") .. ": bad substitution\n")
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
			local off = rt.substr_arith(sh, rt.pe_label(pe), pe.arg and arith_expand_text(sh, pe.arg) or nil) or 0
			-- a PRESENT length (even empty, `${a[@]:0:}`) is a count; empty means 0.
			local len = pe.arg2 and (rt.substr_arith(sh, rt.pe_label(pe), arith_expand_text(sh, pe.arg2)) or 0) or nil
			els = rt.array_slice_values(sh, pe.name, els, off, len, pe.arg2)
		elseif (pe.op == "?" or pe.op == ":?") and (#els == 0 or (pe.op == ":?" and #els == 1 and els[1] == "")) then
			-- ${@?} ${a[@]:?msg}: no elements (or, for :?, a lone empty one) is the error
			local msg = pe.arg and pe.arg ~= "" and expand_word(sh, P.parse_word(pe.arg))
				or (pe.op == "?" and "parameter not set" or "parameter null or not set")
			io.stderr:write("curse: " .. rt.pe_label(pe) .. ": " .. msg .. "\n")
			error({ __curse_exit = sh.opt_c and 127 or 1, __curse_lineabort = sh.opt_i or nil })
		elseif (pe.op == "=" or pe.op == ":=") and #els == 0 then
			-- ${@=x} / ${a[@]=x}: nothing to assign to — bash aborts the line. An ASSOC
			-- takes `@`/`*` as a literal key (bash: ${A[@]:=foo} sets A[@])
			if pe.index and sh:is_assoc(pe.name) then
				local v = pe.arg and expand_word(sh, P.parse_word(pe.arg), true) or ""
				sh:array_set(pe.name, pe.index, v)
				return { sh:array_get(pe.name, pe.index) or "" }, star
			end
			if pe.name == "@" or pe.name == "*" then
				io.stderr:write("curse: $" .. pe.name .. ": cannot assign in this way\n")
				error({ __curse_exit = 1, __curse_lineabort = true })
			end
			rt.assign_default_fail(sh, rt.pe_label(pe), "bad array subscript")
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
				ne = table.concat(els, rt.ifs_sep(sh)) ~= ""
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
			if sh:declared_unset(pe.name) and sh:attr_string(pe.name) == "" then
				d = nil -- (`declare v` alone: nothing to recreate)
			end
			return d and { d } or {}, star
		elseif pe.op == "@" and pe.arg == "A" then
			-- ${@@A}: the `set -- 'p1' 'p2' …` words that recreate the positional params
			local out = {}
			if #els > 0 then
				out[1], out[2] = "set", "--"
				for i = 1, #els do
					out[i + 2] = sh:apply_str_op("@", els[i], "Q")
				end
			end
			els = out
		elseif (pe.op == "@" and (pe.arg == "K" or pe.arg == "k")) and pe.name ~= "@" and pe.name ~= "*" then
			if pe.arg == "k" then -- ${a[@]@k}: key and value as separate words, alternating
				local out, idx = {}, sh:array_indices(pe.name)
				for i = 1, #idx do
					out[#out + 1] = tostring(idx[i])
					out[#out + 1] = els[i]
				end
				return out, star
			end
			-- ${a[@]@K}: ONE word of `key "value"` pairs (assoc's has a trailing blank, bash)
			if #els == 0 then
				return {}, star
			end
			local parts = M._int.decl_elems(sh, pe.name, '%s %s')
			return { table.concat(parts, " ") .. (sh:is_assoc(pe.name) and " " or "") }, star
		elseif pe.op == "@" and pe.arg == "a" then -- ${a[@]@a}: the variable's attribute string, per element
			local attr = sh:attr_string(pe.name)
			local out = {}
			for i = 1, #els do
				out[i] = attr
			end
			-- a declared-but-valueless var (`declare -r v`) still reports its attributes once
			if #els == 0 and attr ~= "" and sh:declared_unset(pe.name) then
				out[1] = attr
			end
			els = out
		elseif pe.op and pe.op ~= ":-" and pe.op ~= "-" and pe.op ~= ":+" and pe.op ~= "+" then
			-- strip/subst/case per element: the PATTERN is quote-aware (a quoted `'*'` is a literal
			-- `*`, not a glob) — expand_pattern, like the scalar path (getpattern in bash). Only the
			-- replacement (arg2) expands via expand_repl (tilde + patsub_replacement marking).
			local arg = pe.arg and expand_pattern(sh, P.parse_word(pe.arg)) or ""
			local arg2 = pe.arg2 and expand_repl(sh, P.parse_word(pe.arg2)) or nil
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
local str_glob_active = rt.field_glob_active -- (glob_pattern_p on an all-unquoted string)

local expand_fields_full -- (the general path, below: the fast paths stay in a function
-- with no closures, so the JIT can compile them — a closure over `sh` would make every
-- return close an upvalue, NYI)
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
		elseif p.cmdsub and not p.q then
			-- ...a lone unquoted $(…) (`for x in $(seq N)`): split on the default IFS at C
			-- speed; if a field would glob, the general path takes the value (it ran once)
			local v = expand_part_str(sh, p)
			local ifs = rt.ifs(sh)
			if ifs == nil or ifs == " \t\n" then
				local out, n = {}, 0
				for f in v:gmatch("[^ \t\n]+") do
					if not sh.opt_f and str_glob_active(f) then
						return expand_fields_full(sh, w, v)
					end
					n = n + 1
					out[n] = f
				end
				return out
			end
			return expand_fields_full(sh, w, v)
		elseif p.var and not p.q then
			-- ...and a lone unquoted `$name` of a plain set scalar (`[ $i -lt $n ]`): no
			-- default-IFS whitespace and no active glob -> one field, as is. (Anything else
			-- takes the full path; re-reading a plain variable there has no side effects.)
			local b = sh.vars[p.var]
			if b and not b.ref and not b.arr and not b.outer and (b.s ~= nil or b.n ~= nil) then
				local s = sh:get(p.var)
				if s == "" then
					return {}
				end
				local ifs = rt.ifs(sh)
				if (ifs == nil or ifs == " \t\n") and not s:find("[ \t\n]")
					and (sh.opt_f or not str_glob_active(s)) then
					return { s }
				end
			end
		end
	end
	return expand_fields_full(sh, w)
end
expand_fields_full = function(sh, w, pre1) -- pre1: part 1 already expanded (a $(…) ran)
	-- The word's parts drive the runtime's field builder (rt.fb_new: IFS splitting + glob):
	-- literal/quoted text is added as is, unquoted expansions split on $IFS; the part-level
	-- semantics (field-wise ${x:-word}, tilde, "$@" in "…", bug #627) stay here.
	local fb = rt.fb_new(sh)
	if fb.ic.mixed then -- (a has_dollar_at word splits its start unstripped: see multi_hda)
		for _, p in ipairs(w.parts) do
			if is_multi(sh, p) then
				if multi_hda(sh, p) then
					fb.dl = 0
					break
				end
			elseif default_hda(sh, p) then
				fb.dl = 0
				break
			end
		end
	end
	local dq_null, dq_at -- (a "…" segment tagged dqat: an empty part seen / a "$@" gave no words)
	for pi, p in ipairs(w.parts) do
		if is_multi(sh, p) then
			local els, star, qforced = multi_elems(sh, p) -- qforced: a quoted multi alternate
			if p.q or qforced then
				if p.dqat and #els == 0 then
					if star then
						dq_null = true
					else
						dq_at, fb.xs = true, true
					end
				else
					-- (lone: the word is exactly "$@" — bash's expand_word_internal shortcut;
					-- not in an array literal, whose words carry other flags)
					fb:multi(els, true, star, #w.parts == 1 and p.special == "@" and not p.braced and not w.aelem,
						not p.dqat)
				end
			else
				local pe = p.pexp
				if star and pe and (pe.op == "prefix" or pe.op == "indices") then
					-- The INDIRECT `${!pfx*}` / `${!a[*]}` `*` forms join into ONE string
					-- BEFORE word-splitting even under IFS='' (unlike `$*`/`${a[*]}`, which
					-- stay per-element there). Join with IFS[0]; when IFS is empty the prefix
					-- form concatenates but the KEYS form falls back to a space (bug #627).
					local sep = rt.ifs_sep(sh)
					if sep == "" and pe.op == "indices" then
						sep = " "
					end
					fb:split(table.concat(els, sep))
				else
					fb:multi(els, false, star)
				end
			end
		elseif
			p.pexp
			and (p.pexp.op == ":-" or p.pexp.op == "-" or p.pexp.op == ":+" or p.pexp.op == "+")
			and not p.pexp.index
			and p.pexp.name ~= "@"
			and p.pexp.name ~= "*"
			and (not p.q or (p.pexp.arg and p.pexp.arg:find("@", 1, true)))
		then
			-- unquoted ${x:-word}/-/:+/+: when the WORD branch is taken, the word's OWN quoting
			-- governs splitting (bash), so expand it field-wise rather than as a flat string —
			-- and a quoted "$@"/"${a[@]}" in it keeps its separate words (${1+"$@"})
			local pe = p.pexp
			if not p.q then
				fb.xs = true -- (an unquoted $-expansion: bash word-splits the word)
			end
			local b = sh.vars[sh:deref(pe.name)]
			local hasval -- (an array is "set" by its [0], as expand_param decides)
			if b and b.arr then
				hasval = b.arr[0] ~= nil or b.arr["0"] ~= nil
			else
				hasval = b ~= nil and (b.s ~= nil or b.n ~= nil)
			end
			hasval = hasval or sh:special_get(pe.name) ~= ""
			local pn = tonumber(pe.name) -- a positional parameter is set when within $#
			if pn then
				hasval = pn == 0 or pn <= sh.nparams
			end
			local pval = pn and sh:param(pn) or sh:get(pe.name) -- ($1 is not a variable)
			local nonnull = pval ~= ""
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
			if p.q then
				-- "${x:-$@}" / "a${x:+"$@"}b": a $@ (or ${a[@]}) in a used word of a QUOTED
				-- ${…} still makes one field per element, as "$@" does; the rest of the word
				-- is quoted text. Never zero fields (bash: "${x:-$@}" with no params is "").
				fb:add("", false)
				if useword then
					for _, sp in ipairs(P.parse_default_quoted(pe.arg, pe.hd).parts) do
						if is_multi(sh, sp) then
							sp.q = true
							local els, star = multi_elems(sh, sp)
							fb:multi(els, true, star, nil, true)
						else
							fb:add(expand_part_str(sh, sp), false)
						end
					end
				else
					fb:add(expand_part_str(sh, p), false)
				end
			elseif useword and pe.arg then
				-- expand the default's parts: a QUOTED part is one atomic (sub)field, an
				-- unquoted part word-splits — so 'a b' stays one field but a b splits.
				for k, sp in ipairs(P.parse_word(pe.arg).parts) do
					if is_multi(sh, sp) then -- $@/$*: as at the top level of a word
						local els, star = multi_elems(sh, sp)
						fb:multi(els, sp.q, star, nil, not sp.dqat)
					else
						local s = expand_part_str(sh, sp)
						if k == 1 and sp.lit ~= nil and not sp.q then
							s = tilde_prefix(sh, s)
						end -- word-initial ~
						if sp.q then
							fb:add(s, false)
						else
							fb:split(s)
						end
					end
				end
			elseif pe.op == ":-" or pe.op == "-" then
				fb:split(pval)
			end
		else
			local s
			if pi == 1 and pre1 ~= nil then
				s = pre1
			else
				s = expand_part_str(sh, p)
			end
			if pi == 1 and p.lit ~= nil and not p.q then
				-- (posix: `NAME=` args tilde-expand only for declaration builtins — parser
				-- marks the other commands' args `plainarg`)
				local s0 = s
				s = tilde_word_initial(sh, s, #w.parts > 1, w.noassign or (sh.opt_posix and w.plainarg))
				if s ~= s0 and s0:byte(1) == 126 then -- `~…`: the expansion is quoted text — never globbed
					local tl = #s0 - (s0:find("[/:]") or #s0 + 1) + 1 -- (the text after the tilde-prefix)
					fb:add(s:sub(1, #s - tl), false)
					s = s:sub(#s - tl + 1)
				end
			elseif pi > 1 and p.lit ~= nil and not p.q and not w.notilde and not w.noassign
				and s:find(":~", 1, true) and rt.assignish(w) then
				s = rt.tilde_argcont(sh, s, pi < #w.parts, sh.opt_posix and w.plainarg)
			end -- word-initial / NAME= ~
			if p.dqat and s == "" then
				dq_null = true
			elseif p.q or p.lit ~= nil then
				fb:add(s, not p.q)
			else
				fb:split(s)
			end
		end
		if p.dqend then -- end of a "…$@…" segment: its empty parts make a null word unless "$@" was empty
			if dq_null and not dq_at then
				fb:add("", false)
			end
			fb:dqend()
			dq_null, dq_at = nil, nil
		end
	end
	-- (xnoglob: just this word's pathname expansion is off — compgen -W's, whose $(…)
	-- bodies still glob)
	return fb:finish(sh.xnoglob == w)
end
-- The one-word field expander, for the runtime's fallbacks on word shapes the compiled tier
-- can't render (rt.word_fields/xw_fields/aa_fields, `$(< f)`'s target) and compgen -W.
M.expand_to_fields = expand_to_fields

local exec_list -- forward

-- ---- redirections ----
-- Apply redirections, backing up each touched fd (any fd, not just 0/1/2) so it
-- can be restored. Returns (save, ok); ok is false when an open() failed (bash
-- then skips the command and reports failure).
-- Lowest free fd >= 10 (bash allocates named-fd redirs here); F_GETFD=1 on a
-- closed fd returns -1 (EBADF).
local nofile_rl = ffi.new("struct curse_rlimit[1]")
local function alloc_fd()
	for fd = 10, 250 do
		if C.fcntl(fd, 1) == -1 then
			-- (bash's fcntl(F_DUPFD, 10) fails EINVAL past RLIMIT_NOFILE: `ulimit -n 6`)
			if C.getrlimit(7, nofile_rl) == 0 and nofile_rl[0].rlim_cur <= fd then
				return -1
			end
			return fd
		end
	end
	return -1
end
local FDVAR_NOASSIGN = { GROUPS = 1, FUNCNAME = 1, BASH_ARGC = 1, BASH_ARGV = 1, BASH_SOURCE = 1, BASH_LINENO = 1 }
local function apply_redirs(sh, redirs, cname, ctx, args) -- cname: the command (names {v} errors;
	-- ctx: only names them — compiled code's rt.redir_apply_one); args: its argv (rt.redir_forks)
	io.flush() -- flush pending stdout BEFORE moving fds, else buffered output from a
	-- prior command would be redirected into (and lost to) the new target
	local save, ok = {}, true
	local fd1file = false -- has fd 1 gone to a real file? (then `2>&1` isn't captured)
	-- Named-fd (`{var}>`) targets are NOT restored after the command: bash leaves
	-- them open (so a later `{var}>` gets the next fd), unlike a numeric redirect.
	local persist = {}
	-- A fatal expansion error in a redirection word (set -u, ${v?}, failglob): bash expands
	-- an external command's redirections in the forked child, where it only fails that
	-- command (status 1); anywhere else it is raised as usual (redir.c runs in the shell).
	local ext = cname and rt.redir_forks(sh, cname, args)
	local function xerr(e)
		if not ext and type(e) == "table" and e.__curse_exit then
			error(e, 0)
		end
	end
	local function backup(fd)
		if not persist[fd] then
			local e = { fd = fd, saved = rt.save_fd(fd) }
			save[#save + 1] = e
			if sh.iso_ctx and sh.iso_ctx[1] then
				rt.iso_note_save(sh, e)
			end
		end
	end
	-- redirect targets are word-expanded at runtime (e.g. `> $TMP/f`, `>& $myfd`).
	local function tgt(r)
		return expand_word(sh, P.parse_word(r.target or ""))
	end
	-- A FILE redirect target is glob-expanded and word-split like any word; bash
	-- requires it to resolve to EXACTLY ONE word, else "ambiguous redirect".
	local function ftgt(r)
		-- (the word as written: r.target has its outer quotes stripped, `"$f"` -> `$f`)
		local raw = r.src or r.target or ""
		-- bash brace-expands the target too; more than one word -> ambiguous redirect.
		if P.brace_count(raw) > 1 then -- (a `{v}>…`'s error names v: redirection_error)
			io.stderr:write("curse: " .. (r.fdvar or raw) .. ": ambiguous redirect\n")
			return nil
		end
		-- expansion can also fail non-fatally (e.g. failglob no-match): the redirect
		-- then fails (status 1) rather than aborting the script.
		local eok, fs
		if sh.opt_posix and not sh.opt_i then
			-- posix: no word splitting (redir.c: W_NOSPLIT) nor globbing — one string, $@
			-- joined; only an unquoted word expanding to nothing is ambiguous
			eok, fs = pcall(expand_word, sh, P.parse_word(raw))
			if eok then
				fs = (fs ~= "" or raw:find("[\"']")) and { fs } or {}
			end
		else
			eok, fs = rt.redir_noglob(sh, expand_to_fields, sh, P.parse_word(raw))
		end
		if not eok then
			xerr(fs)
			return nil
		end
		if #fs ~= 1 then
			io.stderr:write("curse: " .. (r.fdvar or raw) .. ": ambiguous redirect\n")
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
		local function fdvar_set(v) -- false: the variable refused it (a bad nameref target)
			if fvn then
				sh:array_set(fvn, array_key(sh, fvn, fvs), v, false)
				return true
			end
			rt.assign_ctx = cname or ctx
			local set = sh:set_str(r.fdvar, v)
			rt.assign_ctx = nil
			return set ~= false
		end
		local fdb = r.fdvar and sh.vars[sh:deref(fvn or r.fdvar)]
		-- bash's noassign dynamic arrays (GROUPS, BASH_ARGV, …) refuse the fd too: redir_varassign
		local noasg = r.fdvar and FDVAR_NOASSIGN[fvn or r.fdvar] and not (sh.unset_specials and sh.unset_specials[fvn or r.fdvar])
		local rflags = r.fdvar and rt.REDIR_FLAGS[r.op]
		if rflags and rflags ~= 0 and sh.opt_r then
			-- a restricted shell refuses a writing redirect before it opens or assigns
			-- anything, naming the {var} (redir.c: WRITE_REDIRECT, then redirection_error)
			io.stderr:write("curse: " .. r.fdvar .. ": restricted: cannot redirect output\n")
			ok = false
			break
		end
		local fdnew -- (a `{v}>…` fd: v is assigned only once its redirection succeeded)
		if r.fdvar then
			if (r.op == "dup" or r.op == "dupin") and r.target == "-" then
				local cur = fdvar_get()
				if cur == nil or cur == "" then -- (`{v}>&-` with v unset/empty: bash)
					io.stderr:write("curse: " .. r.fdvar .. ": ambiguous redirect\n")
					ok = false
					break
				end
				r = setmetatable({ fd = tonumber(cur) or -1 }, { __index = r })
			else
				-- (redir.c: the target is opened/duplicated first — an open failure is the only
				-- error — then moved to a free fd >= 10, and only then assigned: a readonly v
				-- or a noassign array is reported after a successful open, the fd closed)
				local nf = alloc_fd()
				if nf < 0 then
					io.stderr:write((rt.err_prefix(sh):gsub("line %d+: $", "")) .. "redirection error: cannot duplicate fd: Invalid argument\n")
					io.stderr:write("curse: " .. (r.target or "") .. ": Invalid argument\n")
					ok = false
					break
				end
				-- (shopt varredir_close: closed after the command like a numeric redirect —
				-- bash's varassign_redir_autoclose undo; `exec`'s discard still keeps it)
				if sh.shopt.varredir_close then
					backup(nf)
				else
					persist[nf] = true
					rt.iso_keep_fd(sh, nf, -1) -- (a subshell's: closed when it ends)
				end
				fdnew = nf
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
		if rt.REDIR_FLAGS[r.op] then -- a file: rt.redir_open (flags, noclobber, &>, restricted)
			local t = ftgt(r)
			if not (t and rt.redir_open(sh, r.op, r.fd, t, not persist[r.fd] and save or nil, r.fdvar)) then
				ok = false
			end
		elseif r.op == "heredoc" then
			local body = r.body or ""
			local hok = true
			if r.expand then
				-- an unterminated $( in the body fails the redirection (bash: status 1)
				local pok, pw = pcall(P.parse_heredoc, body, true)
				if pok then
					-- (a bad substitution names the whole body: bash expands it as one word)
					sh.bs_word, sh.bs_depth = body, sh.subdepth
					pok, pw = pcall(expand_word, sh, pw)
					sh.bs_word = nil
					if pok then
						body = pw
					else
						xerr(pw)
						hok, ok = false, false
					end
				elseif tostring(pw):find("matching `}'", 1, true) then -- an unterminated `${`:
					sherr(sh, "curse: " .. body .. ": bad substitution\n") -- (names the body, as above)
					hok, ok = false, false
				else
					-- (bash names it `NAME: command substitution: line N:`, N the line the
					-- here-document ended on)
					local sl = sh.cur_line
					sh.in_perr, sh.perr_label = true, "command substitution"
					sh.cur_line = (sl or 1) + select(2, body:gsub("\n", "")) + 1
					io.stderr:write("curse: unexpected EOF while looking for matching `)'\n")
					sh.in_perr, sh.perr_label, sh.cur_line = nil, nil, sl
					hok, ok = false, false
				end
			end
			if hok and not rt.redir_open(sh, "heredoc", r.fd or 0, body, not persist[r.fd or 0] and save or nil) then
				ok = false
			end
		elseif r.op == "herestring" then
			local eok, body = pcall(expand_word, sh, P.parse_word(r.word or ""))
			if eok then
				ok = rt.redir_open(sh, "herestring", r.fd or 0, body .. "\n", not persist[r.fd or 0] and save or nil)
			else
				xerr(body)
				ok = false
			end
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
				-- only an all-digit word is a fd (redir.c: all_digits); one past INT_MAX is
				-- fd -1 (EBADF), never a wrapped number — anything else (`0x2`, `1.0`) is a file
				local m = movesrc or (tv:find("^%d+$") and tv)
				if m then
					m = rt.fd_number(m)
				end
				if m == r.fd then -- `N>&N` / `N<&N-`: nothing to do (redir.c: redir_fd == redirector)
				elseif m then
					-- Validate the source fd is open BEFORE backing up the destination: a
					-- dup-based backup would otherwise reuse a just-closed source fd number,
					-- making a stale `>&N` spuriously succeed (fd N reopened as the backup).
					if C.fcntl(m, 1) == -1 then -- F_GETFD on a closed fd returns -1 (EBADF)
						-- (bash names the target as written: `$v: Bad file descriptor`)
						local nm = r.target or tv
						if fdnew then -- (redir.c: its fcntl(F_DUPFD) fails first — sys_error, no line)
							io.stderr:write((rt.err_prefix(sh):gsub("line %d+: $", "")) .. "redirection error: cannot duplicate fd: Bad file descriptor\n")
						end
						io.stderr:write("curse: " .. (nm:match("^(%d+)%-$") or nm) .. ": Bad file descriptor\n")
						ok = false
					else
						-- the move's close of the source is undone after the command too (redir.c:
						-- r_move_* add an undo for redir_fd) — only when the destination was open
						-- (bash tests fcntl(redirector)); `exec` keeps it closed
						local undo = movesrc and C.fcntl(r.fd, 1) ~= -1
						backup(r.fd)
						C.dup2(m, r.fd)
						if undo then
							backup(m)
						end
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
				elseif tv == "" then -- (bash names the target as written — or, off the default
					-- fd, the fd itself)
					local dfl = r.fd == (r.op == "dupin" and 0 or 1)
					io.stderr:write("curse: " .. (dfl and (r.src or r.target) or tostring(r.fd)) .. ": Bad file descriptor\n")
					ok = false
				elseif r.op == "dupin" or r.fd ~= 1 then -- (only `>&file` means `&>file`)
					io.stderr:write("curse: " .. tv .. ": ambiguous redirect\n")
					ok = false
				else -- `>&word` (non-number, r.fd 1): the file gets stdout AND stderr — `&>word`
					ok = rt.redir_open(sh, "outboth", 1, tv, save)
				end
			end
		end
		if fdnew and ok then
			if noasg or (fdb and fdb.ro) then
				if not noasg then
					io.stderr:write("curse: " .. r.fdvar .. ": readonly variable\n")
					rt.report_exit(sh) -- (err_readonly: report_error)
				end
				io.stderr:write("curse: " .. r.fdvar .. ": cannot assign fd to variable\n")
				C.close(fdnew)
				ok = false
			elseif not fdvar_set(tostring(fdnew)) then
				io.stderr:write("curse: " .. r.fdvar .. ": cannot assign fd to variable\n")
				C.close(fdnew)
				ok = false
			end
		end
		if not ok then -- (do_redirections stops at the first failure)
			break
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
				or r.fd == 1 -- (any op: `1<&-` / `1<f` move fd 1 as surely as `>`)
			)
		then
			return true
		end
	end
	return false
end
local restore_redirs = rt.redir_undo

-- name classification for `type` / `command -v`
-- Builtins whose implementation is extracted into a lazily-loaded feature module
-- (name -> module). exec_simple routes these through require() instead of its
-- inline dispatch, so a cold script that never uses them never loads their code.
local BUILTIN_LAZY = rt.BUILTIN_LAZY -- one source of truth (runtime); shared with the compiled tier
local ISO_BUILTIN = rt.ISO_BUILTIN
local BUILTINS = rt.BUILTINS -- (runtime owns the builtin table: rt.builtin_enabled)
M.BUILTINS = BUILTINS
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
	if rt.builtin_enabled(sh, name) then
		return "builtin"
	end
	-- a remembered location (`hash`, `hash -p`, or an earlier run) wins, and counts a hit
	-- (bash: `type` reports it "hashed"); the table empties when $PATH changes
	local hp = not name:find("/", 1, true) and sh.hashpath == sh:get("PATH") and rt.phash_search(sh, name)
	if hp then
		return "file", hp, true
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
-- A compound literal's expanded elements ({key?, op, val}). A declaration builtin's
-- `NAME=(…)` is expanded BEFORE the builtin runs (bash: `local -a arr=("${arr[@]}")`
-- copies the OUTER arr), so exec_stmt pre-computes them into sh.arrayargs_pre[st].
-- ntilde (default: isassoc): expand the assoc forms with no tilde (5.2.21: see notilde). A
-- declaration builtin passes whether IT said -A: without -A its compound argument was
-- expanded as an ordinary (indexed-style) assignment word first, tildes included, even
-- into an existing associative array (`declare -A d; declare d=([k]=~)` stores $HOME).
local function arrayassign_items(sh, st, isassoc, ntilde)
	if ntilde == nil then
		ntilde = isassoc
	end
	local nt = ntilde and notilde or function(w)
		return w
	end
	local items, elems = {}, st.elems
	local e1 = elems[1]
	-- bash's kvpair_assignment_p: an associative literal whose FIRST word is not a
	-- `[k]=v` is a key/value list — every word (even a later `[k]=v`) is one plain word
	-- (a declaration builtin has requoted a bare `[k]` word, so only a real `[k]=v` counts)
	if isassoc and e1 and e1.key == nil and (sh.arrayargs_pending or not e1.word.src:find("^%[")) then
		for _, e in ipairs(elems) do
			local w = e.word
			if e.key ~= nil then
				w = P.parse_word("[" .. e.key .. "]" .. e.op .. w.src)
			end
			items[#items + 1] = { key = nil, op = "=", val = expand_assign_word(sh, nt(w)), src = w.src }
		end
		items.kv = true
		return items
	end
	for _, e in ipairs(elems) do
		if e.key ~= nil and not (e.brace_bare and not isassoc) then
			-- keyed: an associative array (always keyed), or an indexed key with no brace.
			-- Each word expands in order, its subscript then its value (arrayfunc.c): an
			-- assoc key is the expanded text; an indexed subscript's expansions run now,
			-- its arithmetic later (against the array being built — the item's xkey).
			local xkey
			if isassoc then
				xkey = expand_word(sh, notilde(P.parse_word(e.key))) -- (a subscript: never a tilde)
			elseif e.key:find("[%$`]") then
				xkey = expand_word(sh, P.parse_word(e.key))
			end
			items[#items + 1] = { key = e.key, xkey = xkey, op = e.op, val = expand_assign_word(sh, nt(e.word)), src = e.word.src }
		elseif isassoc then
			-- a bare word in a keyed assoc literal: an error, reported as written and never
			-- expanded (bash's assign_compound_array_list)
			items[#items + 1] = { key = nil, op = "=", src = e.word.src }
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
	return items
end
-- An array literal's `[SUB]=`: quote removal of '…' and $'…' (translated, bash's CTLESC
-- bytes dropped) before the arithmetic; "…" and \x are left to it.
local function literal_sub(k)
	if not k:find("'", 1, true) then
		return (k:gsub("\1", ""))
	end
	local out, i, n, dq = {}, 1, #k, false
	while i <= n do
		local c = k:sub(i, i)
		if c == "\\" then
			out[#out + 1] = k:sub(i, i + 1)
			i = i + 2
		elseif c == '"' then
			dq = not dq
			out[#out + 1] = c
			i = i + 1
		elseif not dq and c == "'" then
			local e = k:find("'", i + 1, true) or n + 1
			out[#out + 1] = k:sub(i + 1, e - 1)
			i = e + 1
		elseif not dq and c == "$" and k:sub(i + 1, i + 1) == "'" then
			local j, buf = i + 2, {}
			while j <= n and k:sub(j, j) ~= "'" do
				local l = k:sub(j, j) == "\\" and 2 or 1
				buf[#buf + 1] = k:sub(j, j + l - 1)
				j = j + l
			end
			out[#out + 1] = (rt.ansi_unescape(table.concat(buf), true):gsub("\1", ""))
			i = j + 1
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	return table.concat(out)
end
-- A declaration builtin's NAME=(…) literal, stored after the builtin ran (rt.arrayassign_body)
local function do_arrayassign(sh, st)
	return rt.arrayassign_body(sh, st.name, nil, st.append, st, true)
end
M.do_arrayassign = do_arrayassign
-- Quote a value the way `declare -p` does: double-quoted with \ " $ ` escaped.
local function decl_quote(s)
	-- a control char or high byte forces $'…' (bash: `declare -- x=$'a\nb'`);
	-- otherwise the usual double-quoted form.
	-- (a printable multibyte character stays double-quoted: bash's ansic_shouldquote)
	if s:find("[%z\1-\31\127-\255]") and rt.ansic_shouldquote(s) then
		return rt.shell_quote(s)
	end
	s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("%$", "\\$"):gsub("`", "\\`")
	return '"' .. s .. '"'
end
-- An array's elements as declare-p `fmt` (key, quoted value) strings: `[k]="v"` for
-- declare -p, `k "v"` for ${a[@]@K}.
local function decl_elems(sh, name, fmt)
	local assoc, parts = sh:is_assoc(name), {}
	for _, k in ipairs(sh:array_indices(name)) do
		parts[#parts + 1] = fmt:format(M.decl_key(tostring(k), assoc), decl_quote(sh:array_get(name, k)))
	end
	return parts
end
-- an assoc key with shell metacharacters (or a non-printable char) is quoted like a
-- value (and a key that is just `@` or `*`: bash's ALL_ELEMENT_SUB check) — assoc.c
function M.decl_key(ks, assoc)
	if assoc and (ks == "" or ks == "@" or ks == "*" or (ks:find("[^%w_%%+,./:@=%-]")
		and (rt.shell_metas(ks) or rt.ansic_shouldquote(ks)))) then
		return decl_quote(ks)
	end
	return ks
end
M.decl_quote = decl_quote
-- A recoverable parse error (a bad `NAME=( … )` element): bash's syntax-error report — the
-- token, then the line — but the script goes on (status 1)
M.report_recoverable = rt.report_recoverable
-- the dynamic arrays bash lists among its variables (curse computes them on demand)
local DYN_ARRAYS = { BASH_ARGC = 1, BASH_ARGV = 1, BASH_LINENO = 1, BASH_SOURCE = 1, DIRSTACK = 1, FUNCNAME = 1, GROUPS = 1 }
M.DYN_ARRAYS = DYN_ARRAYS
-- bash's dynamic scalars (computed on read, no var box here) and their attributes
local DYN_SCALARS = { BASHPID = "i", HISTCMD = "i", RANDOM = "i", SRANDOM = "i", SECONDS = "i", LINENO = "-",
	EPOCHSECONDS = "-", EPOCHREALTIME = "-", BASH_SUBSHELL = "-", BASH_COMMAND = "-", BASH_ARGV0 = "-",
	OSTYPE = "-", MACHTYPE = "-", HOSTTYPE = "-" }
-- Format one variable as a `declare -p` line, or nil if it is unset.
local function fmt_decl(sh, name)
	-- SHELLOPTS/BASHOPTS are readonly, exported, derived specials with no var box.
	if (name == "SHELLOPTS" or name == "BASHOPTS") and sh.shellopts then
		local x = name == "SHELLOPTS" and sh.shellopts_exported and "x" or ""
		return "declare -r" .. x .. " " .. name .. "=" .. decl_quote(sh:special_get(name))
	end
	local b = sh.vars[name]
	if b == nil and DYN_ARRAYS[name] and not (sh.unset_specials and sh.unset_specials[name]) then -- (bash's dynamic arrays: FUNCNAME, BASH_SOURCE, …)
		local vals, parts = sh:array_values(name), {}
		if name == "DIRSTACK" and not (sh.dirstack and #sh.dirstack > 0) then
			vals = {} -- (bash shows an unused stack as `()`, though ${DIRSTACK[0]} is the cwd)
		end
		for i, v in ipairs(vals) do
			parts[i] = "[" .. (i - 1) .. "]=" .. decl_quote(v)
		end
		if #parts == 0 then -- (an empty FUNCNAME — outside any function — has no value at all)
			return name == "FUNCNAME" and "declare -a FUNCNAME" or ("declare -a " .. name .. "=()")
		end
		return "declare -a " .. name .. "=(" .. table.concat(parts, " ") .. ")"
	end
	if (b == nil or (b.dyn and b.s == nil and b.n == nil)) and DYN_SCALARS[name]
		and not (sh.unset_specials and sh.unset_specials[name]) then
		local v = sh:get(name) or "" -- (read first: get_seconds gives SECONDS its -i)
		local fl = b and sh:attr_string(name) or DYN_SCALARS[name]
		return "declare -" .. (fl == "" and "-" or fl) .. " " .. name .. "=" .. decl_quote(v)
	end
	if b == nil then
		return nil
	end
	if b.ref then -- bash shows the export letter on a nameref as `declare -nx`
		-- (bash's order around the n: `-inl`, `-nrx`, `-ntu`)
		local pre = "declare -" .. (b.int and "i" or "") .. "n" .. (b.ro and "r" or "") .. (b.trace and "t" or "")
			.. ((os.getenv(name) ~= nil or b.exported) and "x" or "") .. (b.lower and "l" or "")
			.. (b.upper and "u" or "") .. (b.cap and "c" or "") .. " " .. name
		return b.s == nil and pre or (pre .. "=" .. decl_quote(b.s)) -- (no target yet: no =)
	end
	if b.assoc or b.arr then
		-- array/assoc flag letters in bash order (a/A i r x l u); export shows from the
		-- ATTRIBUTE (an array is never in the process env, unlike a scalar).
		local fl = sh:attr_string(name)
		local parts = decl_elems(sh, name, "[%s]=%s")
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
			.. (b.trace and "t" or "")
			.. (b.exported and "x" or "") -- (the attribute: an unexported local may shadow an env value)
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
-- current mask, as bash's umask.def: returns the new mask, or nil and bash's message.
local UMASK_WHO = { u = 448, g = 56, o = 7, a = 511 }
local UMASK_PERM = { r = 292, w = 146, x = 73 }
local function parse_umask(s, cur)
	if s:match("^%d") then
		local v = s:match("^[0-7]+$") and tonumber(s, 8)
		if not v or v > 4095 then -- (bash's read_octal: up to 07777, then masked)
			return nil, s .. ": octal number out of range"
		end
		return v % 512
	end
	local bits = bit.band(bit.bnot(cur), 511) -- symbolic works on the allowed perms
	local i = 1
	while true do
		local who, perm = 0, 0
		while UMASK_WHO[s:sub(i, i)] do
			who = bit.bor(who, UMASK_WHO[s:sub(i, i)])
			i = i + 1
		end
		local op = s:sub(i, i)
		i = i + 1
		if op ~= "+" and op ~= "-" and op ~= "=" then
			return nil, "`" .. (op == "" and "\0" or op) .. "': invalid symbolic mode operator"
		end
		while UMASK_PERM[s:sub(i, i)] do
			perm = bit.bor(perm, UMASK_PERM[s:sub(i, i)])
			i = i + 1
		end
		local c = s:sub(i, i)
		if c ~= "" and c ~= "," then
			return nil, "`" .. c .. "': invalid symbolic mode character"
		end
		if who ~= 0 then
			perm = bit.band(perm, who)
		end
		if op == "+" then
			bits = bit.bor(bits, perm)
		elseif op == "-" then
			bits = bit.band(bits, bit.bnot(perm))
		else
			bits = bit.bor(bit.band(bits, bit.bnot(who == 0 and 511 or who)), perm)
		end
		if c == "" then
			break
		end
		i = i + 1
	end
	return bit.band(bit.bnot(bits), 511)
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
	local h = rt.pf_sh
	if h and rt.lc_mb_cur_max() > 1 and rt.lc_utf8() and (h.mbw or s:byte(1) >= 0x80) then
		-- (printf.def's asciicode calls mbtowc, whose static state a word split may have
		-- left pending — rt.mbtowc_visit: `'é` is then invalid (its first byte), `'\xa9`
		-- completes it)
		local r, c = rt.mbtowc_visit(h, s, 1, #s)
		if r > 0 and c then
			return rt.mb_chars(c)[1].wc
		end
		return s:byte(1)
	end
	local ch = rt.mb_chars(s)[1]
	return (ch and ch.wc) or s:byte(1)
end
-- snprintf of a long double parsed from `num` (lib_cursesig.c's curse_ldfmt), or nil when
-- the text isn't wholly a number (a `'c` char value, junk: the double path handles those)
ffi.cdef("int curse_ldfmt(char *out, int n, const char *fmt, const char *num, int *end_ok);")
local ldbuf, ldn, ldok = ffi.new("char[512]"), 512, ffi.new("int[1]")
local function ld_format(fmt, num) -- -> text, whole (strtold took all of it) | nil
	local w = C.curse_ldfmt(ldbuf, ldn, fmt, num, ldok)
	if ldok[0] < 0 or w < 0 then
		return nil
	end
	if w >= ldn then -- (a wide/precise conversion: grow and redo)
		ldn = w + 1
		ldbuf = ffi.new("char[?]", ldn)
		C.curse_ldfmt(ldbuf, ldn, fmt, num, ldok)
	end
	return ffi.string(ldbuf, w), ldok[0] == 1
end
local pf_range -- (an out-of-range printf number, for sh_printf's warning)
local function printf_int(s, uns)
	if s == nil or s == "" then
		return 0, true
	end
	if s:byte(1) ~= 48 and rt.short_digits(s) then -- (a plain decimal; a leading 0 is octal)
		local d = tonumber(s)
		return uns and u64(d) or i64(d), true
	end
	local c = s:sub(1, 1)
	if c == "'" or c == '"' then
		return char_value(s:sub(2)), true
	end
	-- strtoll semantics (NOT shell arithmetic): skip leading blanks, read a single
	-- [sign] hex/binary/octal/decimal integer, and any leftover (trailing chars OR
	-- blanks, and no base#N) makes it invalid — bash still prints the parsed value,
	-- status 1. (glibc's C23 strtoimax, which bash is built against, takes 0b binary.)
	local rest = s:gsub("^[ \t\n]+", "")
	local tok, base = rest:match("^[%+%-]?0[xX]%x+"), 0 -- 0x hex
	if not tok then
		local sg, bin = rest:match("^([%+%-]?)0[bB]([01]+)") -- 0b binary
		if bin then
			tok, base = sg .. bin, 2
		else
			tok = rest:match("^[%+%-]?0[0-7]*") -- 0 / 0NNN octal
				or rest:match("^[%+%-]?%d+") -- decimal
		end
	end
	if not tok then
		return 0, false
	end -- no digits at all ("xyz") -> 0, invalid
	-- libc strtoll/strtoull clamp out-of-range values to the type limits (and
	-- strtoull wraps a negative modulo 2^64), exactly matching bash's printf. Cast
	-- to the int64_t/uint64_t typedefs so string.format formats them directly.
	ffi.errno(0)
	local v = uns and u64(C.strtoull(tok, nil, base)) or i64(C.strtoll(tok, nil, base))
	if ffi.errno() == 34 then -- ERANGE: bash warns (the clamped value prints, status 0)
		pf_range = s -- (sh_printf reports it, in order with the output)
	end
	local used = base == 2 and #tok + 2 or #tok -- (the 0b isn't in the token)
	return v, (rest:sub(used + 1) == "") -- fully consumed?
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
	-- (strtold reads the LC_NUMERIC radix: under de_DE `0,1' is 0.1 and `0.1' stops at
	-- the `.' — 0, not fully consumed)
	local dp = s:find("[.,]") and rt.decimal_point() or "."
	if dp ~= "." then
		local q = s:gsub("%.", "\0"):gsub(dp:gsub("%p", "%%%0"), ".", 1)
		local v = tonumber(q)
		if v then
			return v, true
		end
		return tonumber(q:match("^%s*[+-]?%d*%.?%d*")) or 0, false
	end
	local v = tonumber(s)
	if v then
		return v, true
	end
	return 0, false
end
-- printf %q: quote so the result re-reads as the same word (bash: ansic_quote's $'…'
-- when a control/non-printable char is present, else sh_backslash_quote)
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
					if rt.ANSIC_ESC[b] then -- (bash's ansic_quote: \E \a \v \b \f \n \r \t)
						out[#out + 1] = rt.ANSIC_ESC[b]
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
	-- sh_backslash_quote (lib/sh/shquote.c, flags 3): bstab's bytes anywhere, a leading
	-- `#`, and a `~` that leads or follows `:`/`=`; multibyte bytes are kept raw
	if not s:find("[\t\n !\"#$&'()*,;<>?%[\\%]^`{|}~]") then
		return s
	end -- nothing to quote: bare
	local r = s:gsub("[\t\n !\"$&'()*,;<>?%[\\%]^`{|}]", "\\%0")
	if r:find("~", 1, true) then
		r = r:gsub("([:=])~", "%1\\~")
	end
	local b = r:byte(1)
	if b == 35 or b == 126 then -- (# and ~ at the start)
		r = "\\" .. r
	end
	return r
end
-- The full printf engine. `argv[start..]` are the data args; the format is reused
-- until they're exhausted. Returns (output, status).
-- printf format parse, MEMOIZED by format string (pure function of `fmt`). Backslash
-- escapes are static, so they fold into literal-string tokens; each %-conversion becomes a
-- {conv/strftime, spec, width|dynw, prec|dynp} token, and a diagnostic the format itself
-- causes (`\x` with no digits) a {diag} token, so it's reported on every run, in order.
-- The executor (sh_printf) then walks the cached token list instead of re-scanning the
-- format every call — the common `printf FMT …` in a loop re-uses the same FMT. Bounded by
-- a flush so a long-lived daemon can't grow it.
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
					flush()
					toks[#toks + 1] = { diag = "missing hex digit for \\x" }
					lit[#lit + 1] = "\\"
					i = i + 1
				end
			elseif d == "u" or d == "U" then
				local h = fmt:match(d == "u" and "^%x%x?%x?%x?" or "^%x%x?%x?%x?%x?%x?%x?%x?", i + 2)
				if h then
					lit[#lit + 1] = rt.utf8_char(tonumber(h, 16))
					i = i + 2 + #h
				else -- (tescape)
					flush()
					toks[#toks + 1] = { diag = "missing unicode digit for \\" .. d }
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
				local spec, grp = "%", false
				while fmt:sub(j, j):match("[-+ #0']") do -- (bash's SKIP1)
					local fl = fmt:sub(j, j)
					if fl == "'" then -- (thousands grouping: only the C library's floats take it)
						grp = true
					elseif not spec:find(fl, 2, true) then -- (each flag once: `%000…0d` is `%0d`)
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
				local lmod = false -- (an `L` modifier: floats stay long double in posix mode)
				while fmt:sub(j, j):match("[lhLjzt]") do
					lmod = lmod or fmt:sub(j, j) == "L"
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
					else -- not a %(…)T: bash warns, prints the `%`, and rescans from after it
						-- (no `)`, or nothing after it: the char is the format's NUL terminator)
						local sc = close and fmt:sub(close + 1, close + 1) or ""
						toks[#toks + 1] = { diag = "warning: `" .. (sc ~= "" and sc or "\0") .. "': invalid time format specification" }
						lit[#lit + 1] = "%"
						i = i + 1
					end
				else
					local conv = fmt:sub(j, j)
					local tk = { conv = conv, spec = spec, width = width, dynw = dynw, prec = prec, dynp = dynp, lmod = lmod, grp = grp }
					-- (the conversion spec string.format takes: literal width/precision of
					-- at most two digits; anything else is built per call)
					if not (dynw or dynp) and #width <= 2 and #(prec or "") <= 2 then
						tk.full = spec .. width .. (prec and ("." .. prec) or "")
					end
					if conv == "" then -- the format ended inside a conversion: bash names it all
						tk.miss = fmt:sub(i)
					elseif conv == "n" then
						toks.hasn = true
					end
					toks[#toks + 1] = tk
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
-- the next printf argument ("" past the end): a module-level function, not a closure per
-- call (closure creation keeps sh_printf out of the JIT)
local function pf_next(ps)
	local v = ps.argv[ps.ai]
	if v ~= nil then
		ps.ai = ps.ai + 1
	end
	return v or ""
end
-- The printf helpers below live in one table (interp.lua's main chunk is near LuaJIT's
-- local-variable limit); all but pf.str are off the common path.
local pf = {}
-- printstr: %s/%b/%q/%c/%(…)T text with a width (space-padded, `-` left-justifies) and a
-- precision in bytes (`%.s`: a null digit string is zero)
function pf.str(spec, width, prec, s)
	if prec then
		local p = tonumber(prec) or 0
		if p < #s then
			s = s:sub(1, p)
		end
	end
	local w = tonumber(width)
	if w and w > #s then
		if spec:find("-", 1, true) then
			return s .. (" "):rep(w - #s)
		end
		return (" "):rep(w - #s) .. s
	end
	return s
end
-- bash's stdout is line-buffered (shell.c: sh_setlinebuf): at a diagnostic, output
-- through the last newline has been written, a partial line has not
function pf.flush_lines(ps)
	local out = ps.out
	if not ps.fsh or not out[1] then
		return
	end
	local s = table.concat(out)
	for k = #out, 1, -1 do
		out[k] = nil
	end
	local nl = nil
	for k = #s, 1, -1 do
		if s:byte(k) == 10 then
			nl = k
			break
		end
	end
	if nl then
		ps.fsh.out(s:sub(1, nl))
		ps.flushed = ps.flushed + nl
		s = s:sub(nl + 1)
	end
	if s ~= "" then
		out[1] = s
	end
end
function pf.diag(ps, msg)
	pf.flush_lines(ps)
	io.stderr:write("curse: printf: " .. msg .. "\n")
end
-- sh_invalidnum (builtins/common.c)
function pf.badnum(ps, s)
	local msg = "invalid number"
	if s:match("^0%d") then
		msg = "invalid octal number"
	elseif s:sub(1, 2) == "0x" then
		msg = "invalid hex number"
	end
	pf.diag(ps, s .. ": " .. msg)
	ps.st = 1
end
-- getintmax/getuintmax: the argument's value; bad text is reported (its numeric prefix
-- still counts), an out-of-range one warned about (clamped)
function pf.intarg(ps, a, uns)
	local v, ok = printf_int(a, uns)
	if not ok then
		pf.badnum(ps, a)
	elseif pf_range then
		pf.diag(ps, "warning: " .. pf_range .. ": Numerical result out of range")
	end
	pf_range = nil
	return v
end
-- getint, for a `*` width/precision: getintmax clamped to an int — a warning that names
-- the word AFTER it (bash has already stepped past the number), or, for the last
-- argument, the value truncated to 32 bits
function pf.getint(ps)
	local a = ps.argv[ps.ai]
	if a == nil then
		return 0
	end
	ps.ai = ps.ai + 1
	local v = pf.intarg(ps, a)
	local nxt = ps.argv[ps.ai]
	if nxt == nil then
		return tonumber(ffi.cast("int32_t", v))
	end
	if v > 2147483647 or v < -2147483648 then
		pf.diag(ps, "warning: " .. nxt .. ": Numerical result out of range")
		return v > 0 and 2147483647 or -2147483648
	end
	return tonumber(v)
end
-- an integer conversion whose width/precision string.format can't take (> 2 digits):
-- format the bare number, then zero-extend to the precision and pad to the width
function pf.bigint(spec, width, prec, conv, v)
	local p = tonumber(prec)
	local fl = spec:gsub("[-0]", "")
	local s
	if p and p <= 99 then
		s = string.format(fl .. "." .. p .. conv, v)
	else
		s = string.format(fl .. conv, v)
		if p then
			local pre = s:match("^[+%- ]?") .. ((conv == "x" or conv == "X") and s:match("^[+%- ]?(0[xX])") or "")
			local digits = s:sub(#pre + 1)
			if #digits < p then
				s = pre .. ("0"):rep(p - #digits) .. digits
			end
		end
	end
	local w = tonumber(width) or 0
	if #s < w then
		if spec:find("-", 1, true) then
			s = s .. (" "):rep(w - #s)
		elseif spec:find("0", 1, true) and not p then
			local pre, rest = s:match("^([+%- ]?0?[xX]?)(.*)$")
			if pre:match("0$") and not (conv == "x" or conv == "X") then -- (octal's `#` 0 is a digit)
				pre, rest = pre:sub(1, -2), "0" .. rest
			end
			s = pre .. ("0"):rep(w - #s) .. rest
		else
			s = (" "):rep(w - #s) .. s
		end
	end
	return s
end
-- %'d / %'u: printf(3)'s `'` flag — the digits grouped by LC_NUMERIC's thousands separator
-- (en_US 1,234,567; de_DE 1.234.567; none in C), then padded to the width
function pf.grouped(spec, width, prec, conv, v)
	local s = pf.bigint(spec:gsub("[-0]", ""), "", nil, conv, v)
	local sep, grouping = rt.thousands_grouping()
	local pre, digits = s:match("^([+%- ]?)(%d+)$")
	local zeros = digits and prec and (tonumber(prec) or 0) - #digits or 0
	if digits and sep ~= "" then
		local parts, i, gi, g = {}, #digits, 1, grouping:byte(1)
		while g and g > 0 and g < 127 and i > g do
			table.insert(parts, 1, digits:sub(i - g + 1, i))
			i = i - g
			gi = gi + 1
			local nb = grouping:byte(gi)
			if nb and nb ~= 0 then -- (the last group size repeats)
				g = nb
			end
		end
		table.insert(parts, 1, digits:sub(1, i))
		s = pre .. table.concat(parts, sep)
	end
	if zeros > 0 then -- (the precision's zeros pad the grouped digits: %'.9d of 12345 is 000012,345)
		s = pre .. ("0"):rep(zeros) .. s:sub(#pre + 1)
	end
	local w = tonumber(width) or 0
	if #s < w then
		if spec:find("-", 1, true) then
			s = s .. (" "):rep(w - #s)
		elseif spec:find("0", 1, true) and not prec then
			local pre, rest = s:match("^([+%- ]?)(.*)$")
			s = pre .. ("0"):rep(w - #s) .. rest
		else
			s = (" "):rep(w - #s) .. s
		end
	end
	return s
end
-- %f/%e/%g/%a: bash parses the argument as a LONG double and prints with `L` (0.1 is
-- exact to 20 places, 1 is 0x8p-3) — except in posix mode without an `L` modifier,
-- where it's a double. The C helper does the long-double case when the text is a plain
-- number (the C library applies the locale's decimal point and `'` grouping itself; a
-- partly-numeric argument prints its numeric prefix, and is reported).
-- (`full`: the spec string.format takes, nil when the width/precision is too wide)
function pf.float(ps, tk, full, spec, width, prec, conv, arg)
	local long = full or (spec .. width .. (prec and ("." .. prec) or ""))
	local cfull = tk.grp and ("%'" .. long:sub(2)) or long
	local posix = not tk.lmod and rt.cur_shell and rt.cur_shell.opt_posix
	local c1 = arg:sub(1, 1)
	if not posix and c1 ~= "" and c1 ~= "'" and c1 ~= '"' then
		local r, whole = ld_format(cfull .. "L" .. conv, arg)
		if r then
			if not whole then
				pf.badnum(ps, arg)
			end
			return r
		end
	end
	local v, ok = printf_float(arg)
	if not ok then
		pf.badnum(ps, arg)
	end
	if full and not tk.grp then
		local r = string.format(full .. conv, v)
		local dp = rt.decimal_point() -- (the locale's radix character: `1,0000` under de_DE)
		if dp ~= "." then
			r = r:gsub("%.", dp, 1)
		end
		return r
	end
	-- (a wide one: the double's exact hex text through the long-double helper)
	return (ld_format(cfull .. "L" .. conv, string.format("%a", v)))
end
-- `fsh`: printing to the shell's stdout — before a diagnostic, the output's complete
-- lines are written first, so the two interleave as bash's line-buffered stdout does
local function sh_printf(fmt, argv, start, nsets, fsh)
	-- (a \u/\U escape's bytes depend on the locale: key those formats by its generation)
	local key = fmt:find("\\[uU]") and (rt.locale_gen .. "\0" .. fmt) or fmt
	local toks = _pf_cache[key]
	if not toks then
		toks = printf_parse(fmt)
		if _pf_n >= 512 then
			_pf_cache, _pf_n = {}, 0
		end
		_pf_cache[key] = toks
		_pf_n = _pf_n + 1
	end
	local out = {}
	-- (the argument cursor, pf_next; the pending output; bytes written ahead of it; status)
	local ps = { argv = argv, ai = start, out = out, fsh = fsh, flushed = 0, st = 0 }
	local nargs = #argv
	repeat
		local pass_start = ps.ai
		local base = toks.hasn and ps.flushed + #table.concat(out) -- (%n counts from each pass's start)
		for t = 1, #toks do
			local tk = toks[t]
			if type(tk) == "string" then -- literal chunk
				out[#out + 1] = tk
			elseif tk.diag then
				pf.diag(ps, tk.diag)
			else
				local spec, width, prec, full = tk.spec, tk.width, tk.prec, tk.full
				if tk.dynw or tk.dynp then
					if tk.dynw then
						local w = pf.getint(ps)
						if w < 0 then -- (a negative `*` width left-justifies)
							w = -w
							if not spec:find("-", 1, true) then
								spec = spec .. "-"
							end
						end
						width = tostring(w)
					end
					if tk.dynp then
						local p = pf.getint(ps)
						prec = p >= 0 and tostring(p) or nil -- (a negative one is as if absent)
					end
					if #width <= 2 and #(prec or "") <= 2 then
						full = spec .. width .. (prec and ("." .. prec) or "")
					end
				end
				local conv = tk.conv
				if conv == "s" then
					local a = pf_next(ps)
					out[#out + 1] = (width == "" and not prec) and a or pf.str(spec, width, prec, a)
				elseif conv == "d" or conv == "i" or conv == "u" or conv == "o" or conv == "x" or conv == "X" then
					local v = pf.intarg(ps, pf_next(ps), conv ~= "d" and conv ~= "i")
					conv = conv == "i" and "d" or conv
					if tk.grp and (conv == "d" or conv == "u") then -- (%'d: LC_NUMERIC's grouping)
						out[#out + 1] = pf.grouped(spec, width, prec, conv, v)
					else
						out[#out + 1] = full and string.format(full .. conv, v) or pf.bigint(spec, width, prec, conv, v)
					end
				elseif tk.strftime then
					-- the argument is getintmax'd; none at all is -1: now (-2: when the shell
					-- started, bash's shell_start_time)
					local epoch = -1
					if ps.argv[ps.ai] ~= nil then
						epoch = pf.intarg(ps, pf_next(ps))
					end
					if epoch == -1 then
						epoch = os.time()
					elseif epoch == -2 then
						epoch = rt.cur_shell and rt.cur_shell.start_time or os.time()
					end
					-- (a time localtime can't represent is the epoch)
					local sres = os.date(tk.tfmt, tonumber(epoch)) or os.date(tk.tfmt, 0) or ""
					if #sres >= 128 then
						sres = ""
					end
					out[#out + 1] = pf.str(spec, width, prec, sres)
				elseif conv == "f" or conv == "F" or conv == "e" or conv == "E" or conv == "g" or conv == "G"
					or conv == "a" or conv == "A" then
					-- (into a local first: a bad number's diagnostic flushes `out`, moving its end)
					local r = pf.float(ps, tk, full, spec, width, prec, conv, pf_next(ps))
					out[#out + 1] = r
				elseif conv == "n" then -- %n: store the number of bytes written so far in NAME
					local nm = pf_next(ps)
					if nm ~= "" then
						if not nm:match("^[%a_][%w_]*$") then -- (legal_identifier: no array element)
							pf.diag(ps, "`" .. nm .. "': not a valid identifier")
							return table.concat(out), 1
						end
						if nsets then
							nsets[#nsets + 1] = { nm, ps.flushed + #table.concat(out) - base }
						end
					end
				elseif conv == "c" then -- (a missing or empty argument is a NUL byte)
					local c = pf_next(ps):sub(1, 1)
					out[#out + 1] = pf.str(spec, width, nil, c == "" and "\0" or c)
				elseif conv == "b" then
					local a = pf_next(ps)
					if fsh and a:find("\\[xuU]") then -- (a diagnostic may come: complete lines first)
						pf.flush_lines(ps)
					end
					local bs, bstop = rt.ansi_unescape(a, "b")
					-- (width AND precision apply to the expanded string, like %s)
					out[#out + 1] = pf.str(spec, width, prec, bs)
					if bstop then
						return table.concat(out), ps.st
					end
				elseif conv == "q" then -- (the precision cuts the QUOTED text)
					out[#out + 1] = pf.str(spec, width, prec, printf_q(pf_next(ps)))
				elseif conv == "Q" then -- (a literal precision cuts the raw text; the quoted is whole)
					local a = pf_next(ps)
					if prec and prec ~= "" and not tk.dynp then
						a = a:sub(1, tonumber(prec))
					end
					out[#out + 1] = pf.str(spec, width, nil, printf_q(a))
				elseif conv == "" then -- the format ended inside a conversion (`%10`)
					pf.diag(ps, "`" .. tk.miss .. "': missing format character")
					return table.concat(out), 1
				else -- invalid conversion: bash reports it and STOPS the output there
					pf.diag(ps, "`" .. conv .. "': invalid format character")
					return table.concat(out), 1
				end
			end
		end
	until ps.ai > nargs or ps.ai == pass_start
	return table.concat(out), ps.st
end

-- Dispatch one already-expanded simple command (no redirs — the caller sets those
-- up). Builtins first, then user functions, then external.
-- Run a shell function `cmd` (its body `fn`) with args[2..] as positional params.
-- A function OVERRIDES a builtin of the same name in bash, so this is dispatched
-- before the builtin table (except via `command`, which passes no_func).
local function run_function(sh, cmd, fn, args, hook, tenv_base)
	if PREEMPT[0] ~= 0 then -- (a function's entry is a preemption point, like a loop head:
		rt.preempt() -- pure recursion has none — rt.preempt)
	end
	if sh.vars.FUNCNEST then -- ($FUNCNEST: past that many nested calls, the line is abandoned)
		rt.funcnest_over(sh, cmd)
	end
	local savedline = sh.cur_line -- the call-site line: $LINENO is restored to it on return
	-- (an error out of compiled code called from here skips ITS frames' epilogues: the
	-- depth, frames and stacks are unwound to these marks below)
	local cd0, pd0, fs0, ne0 = sh.calldepth, sh.pd, sh.funcstack and #sh.funcstack or 0, sh.noerr
	-- a $( … ) body's tail command calling this function: its own last command is a tail
	-- too (parser.mark_fntail — fntail_arm names the function), else no tail inside
	local arm0, armk0 = sh.fntail_arm, sh.fntail_kind
	local tl = sh.shlvl_tail
	if tl and sh.shlvl_cs and (tl < 0 and -1 - tl or tl) == pd0 then
		sh.fntail_arm, sh.fntail_kind = cmd, tl < 0 and 1 or 2
	elseif arm0 then
		sh.fntail_arm = nil
	end
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
	table.insert(sh.srcstack, 1, sh.cur_source or sh.main_source or sh.argv0 or "")
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
	local rsave, rsavedout, rok, pnp, pnf
	if fr then
		pnp, pnf = rt.procsub_mark(sh) -- (a >() target there: drained after the body, as on a
		-- (compound command — a compiled caller has no drain.) They are applied at the line
		-- execute_function sets: `line_number = function_line_number = tc->line`, not the call's
		local sv_cl, sv_fl = sh.cur_line, sh.force_line -- (force_line: whichever tier called)
		local fd = sh.func_def and sh.func_def[cmd]
		-- (the parser's: see funcdef_node; 0 — no line at all)
		local bl = fd and (not sh.eof_read and fd.rline_own or fd.rline)
		if bl then
			sh.cur_line, sh.force_line = bl, bl
		end
		rsave, rok = apply_redirs(sh, fr)
		sh.cur_line, sh.force_line = sv_cl, sv_fl
		rsavedout = sh.out
		if redirs_touch_stdout(fr) then
			sh.out = io.write
		end
	end
	local ok, err = true, nil
	if fr and rok == false then
		sh.status = 1 -- a failed redirect skips the body (bash)
	elseif type(fn) == "function" then
		-- (one a fragment defined, compiled for another trap state: its recompile for this one)
		local fm = sh.func_mode and sh.func_mode[cmd]
		local f2 = fm and M.fn_remode and M.fn_remode(sh, cmd, fm)
		if f2 then
			fn = f2
		end
		ok, err = pcall(fn, sh) -- a COMPILED function closure
	else
		-- a hot function in a cold run: its compiled version, once the tier has it
		local def = sh.func_def and sh.func_def[cmd]
		local cfn = hook("call", cmd, def, sh)
		if not cfn and def and M.fn_hook then -- (tier loaded: a hot one compiles standalone)
			cfn = M.fn_hook(sh, cmd, def)
		end
		if cfn then
			ok, err = pcall(cfn, sh)
		else
			ok, err = pcall(exec_list, sh, fn, hook, false)
		end
		-- the tier compiled this function while a loop in it ran hot: the rest of THIS call
		-- continues compiled from that loop (err.pc), in the frame already set up here
		if not ok and type(err) == "table" and err.__curse_fnswitch and err.depth == sh.calldepth then
			ok, err = pcall(err.fn, sh, err.pc)
		end
	end -- an interp AST body
	if fr then
		io.flush()
		sh.out = rsavedout
		restore_redirs(rsave)
		M._int.drain_procsub(sh, pnp, pnf)
	end
	sh.loopdepth = saved_ld
	-- `return N` sets the function's status but not $? (return.def: only return_catch_value),
	-- so the RETURN trap sees the status from before it; N is $? once the trap has run
	-- (N parked in sh.fret: a compiled body's own, or a `return N` raised mid-body here)
	if not ok and type(err) == "table" and err.__curse_return then
		sh.fret = err.__curse_return
		ok, err = true, nil
		sh.noerr = ne0 -- (a return raised mid-body — a trap's — skips a condition's noerr--)
	end
	-- RETURN trap: fires as the function returns, still in ITS context (FUNCNAME, the
	-- definition's $LINENO), preserving its exit status. A top-level RETURN trap is NOT
	-- inherited by a function unless functrace (`set -T`) is on (bash: rt.debug_enter hid
	-- it) — so one present now is inherited or was SET during this call, and fires — a
	-- sourced script's return fires it regardless (see the `.`/source builtin) — and a
	-- function run by the DEBUG trap doesn't fire it.
	if ok then
		rt.fn_return(sh, cmd)
	end
	if not ok then
		while sh.pd > pd0 + 1 do
			sh:popCall()
		end
		while #sh.funcstack > fs0 + 1 do
			table.remove(sh.funcstack, 1)
			table.remove(sh.linestack, 1)
			table.remove(sh.srcstack, 1)
		end
		sh.calldepth = cd0 + 1
	end
	rt.debug_leave(sh, dbg_saved)
	table.remove(sh.funcstack, 1)
	table.remove(sh.linestack, 1)
	table.remove(sh.srcstack, 1)
	sh.cur_source = saved_src
	sh:popCall()
	sh.calldepth = sh.calldepth - 1
	sh.fntail_arm, sh.fntail_kind = arm0, armk0
	sh.cur_line = savedline -- back in the caller: $LINENO (e.g. for a top-level ERR trap) is the call site
	if not ok then
		if type(err) == "table" and err.__curse_return then
			sh.status = err.__curse_return
		else
			error(err)
		end
	end
end

-- ---- background job table (for `jobs`, `wait -n`, `wait %jobspec`) ----
local WNOHANG = 1
-- Reap a job (blocking unless nohang); caches its exit status. Returns the status,
-- or nil if it's still running (nohang) / already gone.
local function job_reap(sh, job, nohang)
	if job.done then
		return job.status
	end
	if job.g then -- an in-process background job
		if nohang then
			rt.sched_pump({})
		else
			rt.wait_groups({ job.g }, sh.in_wait and sh)
		end
		if not job.g.done then
			return nil
		end
		rt.job_done_g(sh, job)
		return job.status
	end
	local sb = ffi.new("int[1]")
	local r = rt.wait_child(job.pid, sb, nohang and WNOHANG or 0, not nohang and sh.in_wait and sh or nil) -- (background tasks run meanwhile)
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
	if r < 0 and not nohang and not sh.wait_sig then
		job.done = true
		job.status = 127
		return 127
	end -- already gone
	return nil -- still running (or, in a subshell, not our child to reap — keep it listed)
end
-- The commands of a job's processes, as bash keeps one per pipeline member: its text split
-- at each top-level ` | ` (outside quotes).
local function job_members(cmd)
	if not cmd:find(" | ", 1, true) then
		return { cmd }
	end
	local out, start, q, k, n = {}, 1, nil, 1, #cmd
	while k <= n do
		local c = cmd:sub(k, k)
		if q then
			if c == q then
				q = nil
			elseif c == "\\" and q == '"' then
				k = k + 1
			end
		elseif c == "'" or c == '"' then
			q = c
		elseif c == "\\" then
			k = k + 1
		elseif c == " " and cmd:sub(k, k + 2) == " | " then
			out[#out + 1] = cmd:sub(start, k - 1)
			start = k + 3
			k = k + 2
		end
		k = k + 1
	end
	out[#out + 1] = cmd:sub(start)
	return out
end
-- A job still in the table (the current/previous job of a table that's been swapped out
-- — a subshell's, `wait`'s own view — is not one)
local function job_listed(sh, j)
	if j and not j.gone then
		for _, x in ipairs(sh.jobs or {}) do
			if x == j then
				return j
			end
		end
	end
	return nil
end
-- Resolve a jobspec to a job, as bash's get_job_spec (builtins/common.c): one leading `%`
-- is dropped; then digits are the job number, and only the NEXT char decides the rest —
-- ``/`%`/`+` the current job, `-` the previous one (`%+junk` is `%+`), `?str` a job whose
-- command contains str in any case, else one whose command starts with the word
-- (get_job_by_name). A name more than one job matches is "WHO: NAME: ambiguous job spec"
-- (returns nil, true) — and, bash's quirk, so is one matched by a later pipeline member.
local function job_resolve(sh, spec, who)
	if spec == "" then
		return nil
	end
	local w = spec:sub(1, 1) == "%" and spec:sub(2) or spec
	local jobs = sh.jobs or {}
	if w:match("^%d+$") then
		local n = tonumber(w)
		for _, j in ipairs(jobs) do
			if j.id == n and not j.gone then
				return j
			end
		end
		return nil
	end
	local c = w:sub(1, 1)
	if c == "" or c == "%" or c == "+" then
		return job_listed(sh, sh.job_cur)
	elseif c == "-" then
		return job_listed(sh, sh.job_prev)
	end
	local sub = c == "?"
	local name = sub and w:sub(2) or w
	local lname = name:lower()
	local found, dup
	for _, j in ipairs(jobs) do
		if not j.gone then
			local mem = job_members(j.cmd or "")
			for k = 1, #mem do
				local m = mem[k]
				local hit
				if sub then
					hit = m:lower():find(lname, 1, true)
				else
					hit = m:sub(1, #name) == name
				end
				if hit then
					dup = found or k > 1
					found = j
					break
				end
			end
			if dup then
				break
			end
		end
	end
	if dup then
		io.stderr:write("curse: " .. (who or "bash") .. ": " .. name .. ": ambiguous job spec\n")
		return nil, true
	end
	return found
end

local SPECIAL_BUILTIN -- forward decl (assigned below); posix dispatch/funcdef rules
-- xtrace (`set -x`): before running a command, write `$PS4<cmd words>` to stderr,
-- single-quoting any word that isn't a plain token (bash). PS4's first char is
-- repeated by call depth. A plain token is bare; anything else is quoted the way
-- bash quotes it (shell_quote: `$'…'` for control/non-printable, else `'…'`).
local xtrace_line, xtrace = rt.xtrace_line, rt.xtrace

-- bash's describe_command (type.def), for `type` and `command -v/-V`. FL: all, short (the
-- sentence), reuse (command -v), type (-t), path_only (-p), force (-P), nofunc (-f),
-- abspath (command -V: a relative hit made absolute), stdpath (command -p). Order: alias,
-- keyword, function, builtin, then a file — an absolute name, the hash table, $PATH (an
-- empty element is the current directory). Returns whether anything was found.
local function d_execable(p) -- (file_status FS_EXECABLE: +x and not a directory)
	return C.access(p, 1) == 0 and not file_test("-d", p)
end
local function d_path(sh, pathstr, name, all) -- find_user_command / user_command_matches (FS_EXEC_ONLY)
	local ign = rt.exec_ignores(sh)
	if not all then
		return { (rt.search_path(sh, name, pathstr, ign)) }
	end
	local hits = {}
	for _, dir in ipairs(rt.path_units(pathstr)) do
		if dir == "" then
			dir = "."
		elseif dir:byte(1) == 126 and not sh.opt_posix then
			dir = rt.tilde_prefix(sh, dir)
		end
		local p = dir:byte(-1) == 47 and dir .. name or dir .. "/" .. name
		if rt.cmd_fstatus(p, ign) == 3 then
			hits[#hits + 1] = p
		end
	end
	return hits
end
local function describe(sh, nm, fl)
	local found = false
	local function say(typeword, sentence, reusable)
		if fl.type then
			sh:echo(typeword)
		elseif fl.short then
			sh:echo(sentence)
		elseif reusable and (fl.reuse or (fl.path_only and typeword == "file")) then
			sh:echo(reusable)
		end
	end
	if not fl.force then
		local av = sh.aliases[nm]
		if av and (sh.shopt.expand_aliases or sh.opt_i) then
			say("alias", rt.L1("%s is aliased to `%s'\n", nm, av),
				"alias " .. nm .. "=" .. (av == "'" and "\\'" or "'" .. av:gsub("'", "'\\''") .. "'"))
			if not fl.all then
				return true
			end
			found = true
		end
		if KEYWORDS[nm] then
			say("keyword", rt.L1("%s is a shell keyword\n", nm), nm)
			if not fl.all then
				return true
			end
			found = true
		end
		if not fl.nofunc and sh.functions[nm] then
			if fl.short then
				sh:echo(rt.L1("%s is a function\n", nm))
				local d = func_body_text(sh, nm)
				if d then
					sh:echo(d)
				end -- canonical (or verbatim) body
			else
				say("function", nil, nm)
			end
			if not fl.all then
				return true
			end
			found = true
		end
		if rt.builtin_enabled(sh, nm) then
			say("builtin", rt.L1((sh.opt_posix and SPECIAL_BUILTIN[nm]) and "%s is a special shell builtin\n"
				or "%s is a shell builtin\n", nm), nm)
			if not fl.all then
				return true
			end
			found = true
		end
	end
	if nm:find("/", 1, true) and d_execable(nm) then -- (an absolute program: no hash, no $PATH)
		say("file", rt.L1("%s is %s\n", nm, nm), nm)
		return true
	end
	if not fl.all or fl.force then -- the hash table (bash's phash_search: a relative entry as ./…)
		local p = not nm:find("/", 1, true) and sh.hashpath == sh:get("PATH") and rt.phash_search(sh, nm)
		if p then
			say("file", rt.L1("%s is hashed (%s)\n", nm, p), p)
			return true
		end
	end
	local hits
	if fl.stdpath then
		hits = d_path(sh, std_path(), nm, false)
	else
		hits = d_path(sh, sh:get("PATH"), nm, fl.all)
	end
	for _, p in ipairs(hits) do
		if p == nm or sh.opt_posix then -- (posix: only executables; relative made absolute)
			if not d_execable(p) then
				if not fl.all then
					break
				end
				p = nil
			elseif p:sub(1, 1) ~= "/" and (fl.reuse or fl.path_only or fl.short) then
				p = sh:cwd():gsub("/$", "") .. "/" .. (fl.abspath and p:gsub("^%./", "") or p)
			end
		elseif fl.abspath and p:sub(1, 1) ~= "/" then
			p = sh:cwd():gsub("/$", "") .. "/" .. p:gsub("^%./", "")
		end
		if p then
			found = true
			say("file", rt.L1("%s is %s\n", nm, p), p)
			if not fl.all then
				break
			end
		end
	end
	return found
end
-- `command -v/-V NAME…` (command.def): -v reusable, -V the sentence with absolute paths
-- (and "not found"); -p the standard path. Status 0 if any name resolved (or none given).
local function command_describe(sh, args, j, verbose, usep)
	local anyfound = false
	local fl = { reuse = not verbose, short = verbose, abspath = verbose, stdpath = usep }
	for k = j, #args do
		if describe(sh, args[k], fl) then
			anyfound = true
		elseif verbose then
			io.stderr:write("curse: command: " .. args[k] .. ": not found\n")
		end
	end
	sh.status = (anyfound or not args[j]) and 0 or 1
	sh.write_err = nil -- (command.def has no sh_chkwrite: a failed write doesn't change $?)
end
local function exec_simple(sh, args, hook, no_func)
	local cmd = args[1]
	if sh.opt_posix and not no_func and SPECIAL_BUILTIN[cmd] and not sh.opt_i then
		-- a special builtin's error can end a non-interactive posix shell (rt.spb_run) —
		-- not when `command`/`builtin` runs it: those dispatch with no_func
		return rt.spb_run(sh, exec_simple, sh, args, hook, true)
	end
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
	-- inside an in-process subshell/$(…), a builtin that changes process-global state (fds,
	-- environ, rlimits, signal dispositions) saves it first (rt.ISO_BUILTIN)
	if cmd ~= nil and sh.disabled_builtins and sh.disabled_builtins[cmd] then
		return sh:exec_t(args) -- `enable -n NAME`: found on $PATH instead
	end
	if args[2] == "--help" and rt.HELPOPT[cmd] then -- (CASE_HELPOPT: the builtin's help, status 2)
		return rt.builtin_help(sh, cmd)
	end
	local prep = ISO_BUILTIN[cmd] -- (in an in-process subshell: save the process state it changes)
	if prep then
		prep(sh)
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
	elseif cmd == "break" or cmd == "continue" then -- outside a loop: a no-op (bash), not a fatal unwind
		if args[2] == "--" then
			table.remove(args, 2)
		end
		if (sh.loopdepth or 0) == 0 then -- (checked first — bash: said, not an error, status 0)
			if not sh.opt_posix then
				io.stderr:write("curse: " .. cmd .. ": only meaningful in a `for', `while', or `until' loop\n")
			end
			sh.status = 0
		elseif args[2] and not rt.legal_number(args[2]) then -- non-numeric count: FATAL (status 128) in a
			io.stderr:write("curse: " .. cmd .. ": " .. args[2] .. ": numeric argument required\n")
			sh.status = 128 -- non-interactive shell (bash exits); interactive just aborts it
			if not sh.opt_i then
				error({ __curse_exit = 128 })
			end
		elseif args[3] ~= nil then -- (the count is checked first — bash's get_numeric_arg)
			rt.too_many(sh, cmd)
		elseif args[2] and rt.legal_number(args[2]) <= 0 then -- (bash: reported, and ALL the loops end)
			io.stderr:write("curse: " .. cmd .. ": " .. args[2] .. ": loop count out of range\n")
			sh.status = 1
			error({ __curse_break = sh.loopdepth, __curse_status = 1 })
		else
			sh.status = 0
			local n = math.min(rt.legal_number(args[2]) or 1, sh.loopdepth)
			error(cmd == "break" and { __curse_break = n } or { __curse_continue = n })
		end
	elseif cmd == "[" or cmd == "test" then
		do_test(sh, args)
	elseif cmd == "return" then
		-- (the argument is checked first: too many aborts the line, a non-number is 2)
		local ra = args[2] == "--" and 3 or 2
		local rcode
		if args[ra] ~= nil then -- (bash's get_exitstat: the number, then no_args)
			rcode = rt.return_status(sh, args[ra])
			if rt.legal_i64(args[ra]) and args[ra + 1] ~= nil then
				rt.too_many(sh, "return")
			end
		end
		-- `return` is only valid inside a function, a sourced script, or a trap;
		-- elsewhere bash reports an error (status 2) but keeps running (no unwind).
		if rt.return_outside(sh) then
			return
		end
		error({ __curse_return = rcode or rt.return_default(sh) })
	elseif cmd == "exit" then
		rt.exit_note(sh)
		local ea = args[2] == "--" and 3 or 2
		if args[ea] and not rt.legal_i64(args[ea]) then -- (get_exitstat: the number
			io.stderr:write("curse: exit: " .. args[ea] .. ": numeric argument required\n")
			error({ __curse_exit = 2 })
		end
		if args[ea + 1] ~= nil then -- first, then too many: the command is discarded)
			rt.too_many(sh, "exit")
		end
		local code = rt.return_status(sh, args[ea], "exit")
		-- inside a function, bash runs the EXIT trap right here, with the function's frame
		-- still active (`trap 'echo $FUNCNAME' EXIT; f() { exit; }; f` prints f)
		if sh:in_function() and not sh.in_exit_trap and rt.exit_trap_own(sh)
			and sh.traps and sh.traps.EXIT and sh.traps.EXIT ~= "" then
			sh.status = code
			M.run_exit_trap(sh)
			code = sh.status
		end
		error({ __curse_exit = code })
	elseif cmd == "command" then
		-- command [-pVv] NAME [ARG…] (bash's command.def): options up to `--`, the last of
		-- -v/-V wins; -p finds NAME along the standard PATH (lookup only: $PATH stays).
		local j, usep, vflag = 2, false, nil
		while args[j] and args[j]:match("^%-.") and args[j] ~= "--" do
			for k = 2, #args[j] do
				local f = args[j]:sub(k, k)
				if f == "p" then
					usep = true
				elseif f == "v" or f == "V" then
					vflag = f
				elseif args[j] == "--help" then -- (GETOPT_HELP: the builtin's help, status 2)
					return rt.builtin_help(sh, "command")
				else
					io.stderr:write("curse: command: -" .. f .. ": invalid option\n" .. rt.usage("command"))
					sh.status = 2
					return
				end
			end
			j = j + 1
		end
		if args[j] == "--" then -- (end of options)
			j = j + 1
		end
		-- (command.def: no NAME is success; then a restricted shell refuses -p — -v/-V too)
		if usep and args[j] ~= nil and rt.restricted(sh, "command: -p: restricted") then
			return
		end
		if vflag then
			command_describe(sh, args, j, vflag == "V", usep)
			return
		end
		-- a special builtin run through `command` loses its fatal-error property (posix)
		local svc, iee = sh.via_command, sh.ign_ee
		sh.via_command = true
		sh.ign_ee = iee or sh.noerr > 0 -- (errexit-exempt: -e cleared for what it runs, as eval)
		if args[j] == nil then
			sh.status = 0
		else
			local sv_pl = sh.path_lookup
			local kd = usep and name_type(sh, args[j], true)
			if usep and (kd == "file" or not kd) then -- (not a builtin: find it along the
				sh.path_lookup = std_path() -- standard path — for this one lookup)
			end
			local ok, err = pcall(exec_simple, sh, { unpack(args, j) }, hook, true)
			sh.path_lookup = sv_pl
			sh.via_command, sh.ign_ee = svc, iee
			if not ok then
				error(err, 0)
			end
		end -- run rest, skipping FUNCTION lookup
		sh.via_command, sh.ign_ee = svc, iee
	elseif sh.functions[cmd] and not no_func then
		run_function(sh, cmd, sh.functions[cmd], args, hook)
	else
		sh:exec_t(args)
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
local function dbracket_pattern(sh, w, xt)
	local p = expand_pattern(sh, w, xt)
	if word_initial_tilde(w) and p:sub(1, 1) == "~" then
		local p2 = tilde_prefix(sh, p)
		if xt and p2 ~= p then -- (the expanded directory reads as quoted)
			local nt = #(p:match("^~[^/:]*"))
			xt[1] = rt.xglob_quote(p2:sub(1, #p2 - (#p - nt))) .. xt[1]:sub(nt + 1)
		end
		p = p2
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
-- The ERE text of a `=~` RHS word: bash tilde-expands a word-initial ~ and matches THAT
-- expansion literally (a tilde prefix isn't part of the regex), the rest via expand_regex.
function M.regex_rhs(sh, rnode)
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
	return expand_regex(sh, rnode)
end
local DB_ARITH_OP = { ["-eq"] = 1, ["-ne"] = 1, ["-lt"] = 1, ["-le"] = 1, ["-gt"] = 1, ["-ge"] = 1 }
local function eval_dbracket(sh, node)
	local k = node.kind
	if k == "and" then
		return eval_dbracket(sh, node.l) and eval_dbracket(sh, node.r)
	end
	if k == "or" then
		return eval_dbracket(sh, node.l) or eval_dbracket(sh, node.r)
	end
	if k == "not" then
		if sh.opt_x and node.e.kind ~= "and" and node.e.kind ~= "or" and node.e.kind ~= "not" and not node.e.paren then
			sh.dbneg = true -- (xtrace: a negated test prints as `[[ ! … ]]`)
		end
		return not eval_dbracket(sh, node.e)
	end
	if k == "str" then
		local v = dbracket_word(sh, node.word)
		if sh.opt_x then
			dbracket_trace(sh, "-n " .. (v == "" and "''" or v))
		end
		return v ~= ""
	end
	if k == "unary" and node.op == "-v" then
		local v = expand_word(sh, node.word)
		if sh.opt_x then
			dbracket_trace(sh, "-v " .. (v == "" and "''" or v))
		end
		return var_is_set(sh, v, true)
	end
	if k == "unary" then
		local v = dbracket_word(sh, node.word)
		if sh.opt_x then
			dbracket_trace(sh, node.op .. " " .. (v == "" and "''" or v))
		end
		return unary(sh, node.op, v)
	end
	if k == "binary" then
		local l, r, op, textual, rtextual, pat, xr
		op = node.op
		if DB_ARITH_OP[op] and node.l.src and node.r.src then
			-- bash 5.2 expands an arithmetic operator's operands like $((…)): no process
			-- substitution, and subscripts quoted (`index[7<(4+2)]` is arithmetic) — but
			-- quotes are removed first (`[[ '3' -eq 3 ]]`): a quoted operand is a plain word
			textual, rtextual = not node.l.src:find("['\"\\]"), not node.r.src:find("['\"\\]")
			l = textual and arith_expand_text(sh, node.l.src) or dbracket_word(sh, node.l)
			r = rtextual and arith_expand_text(sh, node.r.src) or dbracket_word(sh, node.r)
		elseif op == "=~" then -- (each operand expanded ONCE; the trace shows the regex text)
			l = dbracket_word(sh, node.l)
			pat = M.regex_rhs(sh, node.r)
			r = pat
		elseif (op == "==" or op == "=" or op == "!=") and not (node.rq and not sh.shopt.nocasematch) then
			l = dbracket_word(sh, node.l)
			xr = sh.opt_x and {} or nil -- (traced as bash's globbing text: quoted chars backslashed)
			pat = dbracket_pattern(sh, node.r, xr)
			r = xr and xr[1] or pat
		else
			l, r = dbracket_word(sh, node.l), dbracket_word(sh, node.r)
			if sh.opt_x and (op == "==" or op == "=" or op == "!=") then -- (a wholly quoted rhs)
				xr = { rt.xglob_quote(r) }
			end
		end
		if sh.opt_x then -- (an empty operand traces as '')
			r = xr and xr[1] or r
			dbracket_trace(sh, (l == "" and "''" or l) .. " " .. op .. " " .. (r == "" and "''" or r))
		end
		local ic = sh.shopt.nocasematch and true or nil -- shopt -s nocasematch: case-insensitive
		if op == "==" or op == "=" then
			if node.rq and not ic then
				return l == r
			else
				return rt.glob_match(l, pat, ic)
			end
		elseif op == "!=" then
			if node.rq and not ic then
				return l ~= r
			else
				return not rt.glob_match(l, pat, ic)
			end
		elseif op == "=~" then
			-- a quoted part of the regex is matched literally (bash), so re-expand with
			-- regex-escaping of quoted segments instead of using the plain rhs.
			-- bash also tilde-expands a word-initial ~ on the =~ RHS and matches THAT
			-- expansion literally (a tilde prefix isn't part of the regex): split off the
			-- ~-token, expand it, and re-expand it as a quoted (regex-escaped) segment.
			local caps, bad = rt.regex_captures(l, pat, ic) -- real POSIX ERE + BASH_REMATCH
			if bad then
				error({ __curse_regexerr = true })
			end -- invalid regex -> [[ ]] status 2
			sh:array_assign("BASH_REMATCH", caps or {}, false)
			return caps ~= nil
		elseif op == "-eq" or op == "-ne" or op == "-lt" or op == "-le" or op == "-gt" or op == "-ge" then
			-- [[ ]] arithmetic comparisons evaluate each side as an arith EXPRESSION
			-- (bash: [[ 1+2 -eq 3 ]] is true), unlike `test` which needs integer literals.
			-- An operand's arith error makes just THIS primary false (bash's arithcomp:
			-- `if (expok == 0) return FALSE`, the right side then unevaluated); `||`/`!`
			-- go on. A subscript error still abandons the line.
			local ok, nl = pcall(M.dbracket_arith, sh, l, textual)
			local nr
			if ok then
				ok, nr = pcall(M.dbracket_arith, sh, r, rtextual)
			else
				nr = nl
			end
			if not ok then
				if type(nr) == "table" and nr.__curse_matherr and not nr.__curse_subscript then
					return false
				end
				error(nr, 0)
			end
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
-- Evaluate an expression STRING (a value re-read as arithmetic): a parse error is a shell
-- arith error (fails the command), never a raw Lua error out of compiled code.
function M.arith_eval_str(sh, s)
	local ok, ast = pcall(P.arith, s == "" and "0" or s, sh.arith_expanded and "expanded" or nil)
	if not ok then
		arith_pre(sh, ast)
		io.stderr:write("curse: " .. P.arith_errmsg(s, ast) .. "\n")
		error({ __curse_exit = 1, __curse_matherr = true, __curse_experr = true })
	end
	return eval(sh, ast)
end
function M.dbracket_arith(sh, s, textual)
	local sv, sx = P.arith_cmd, sh.arith_expanded
	P.arith_cmd = "[["
	-- (a word-expanded operand: its subscripts aren't expanded again; a textual one is
	-- arith_expand_text output, whose escaped subscripts the evaluator dequotes as $((…)))
	sh.arith_expanded = not textual
	local ok, v
	if textual then -- (arith_expand_text output: its subscript escapes need the strict parse)
		ok, v = pcall(function()
			local pok, ast = pcall(P.arith, s == "" and "0" or s, "strict")
			if not pok then
				arith_pre(sh, ast)
				io.stderr:write("curse: " .. P.arith_errmsg(s, ast) .. "\n")
				error({ __curse_exit = 1, __curse_matherr = true, __curse_experr = true })
			end
			return eval(sh, ast)
		end)
	else
		ok, v = pcall(M.arith_eval_str, sh, s)
	end
	P.arith_cmd, sh.arith_expanded = sv, sx
	if not ok then
		error(v, 0)
	end
	return v
end -- -eq/-lt… operand

-- Run a loop body, catching break/continue (decrementing multi-level n and
-- re-raising when it targets an outer loop). Returns "break", "continue", or nil.
-- Anything that leaves the loop from here (an outer break/continue, exit, return, an
-- aborted line) first gives back the loop's level: the loop's own decrement is skipped.
local function loop_signal(sh, err)
	if type(err) == "table" then
		if err.__curse_break then
			if err.__curse_break > 1 then
				sh.loopdepth = sh.loopdepth - 1
				error({ __curse_break = err.__curse_break - 1 })
			end
			return "break"
		elseif err.__curse_continue then
			if err.__curse_continue > 1 then
				sh.loopdepth = sh.loopdepth - 1
				error({ __curse_continue = err.__curse_continue - 1 })
			end
			return "continue"
		end
	end
	sh.loopdepth = sh.loopdepth - 1
	error(err, 0) -- exit/return/real error propagates
end
local function run_loop_body(sh, body, hook)
	local ne = sh.noerr
	local ok, err = pcall(exec_list, sh, body, hook, false)
	if ok then
		return nil
	end
	sh.noerr = ne -- (a break/continue raised inside an `if`/&& condition: its noerr drops)
	return loop_signal(sh, err)
end

-- Snapshot the <()/>() counts before a command expands its words/redirs, so its
-- cleanup drains ONLY the procsubs it registered — not ones an enclosing group's
-- redirect (`{ …; } > >(tac)`) left pending, which drain after the whole group.
-- (One implementation, in runtime: the compiled tier marks the same way.)
local procsub_mark = rt.procsub_mark
-- Process-substitution cleanup, run after the command a <()/>() was attached to: close
-- the shell's end of each pipe it created (a >(cmd) then sees EOF; an unread <(cmd)
-- writer gets EPIPE) and reap the child. Only entries added since the mark. (np, the
-- mark's first half, is always 0 and unused: procsub_mark's pair is kept for callers.)
local function drain_procsub(sh, np, nf)
	nf = nf or 0
	local files = sh.procsub_files
	if not files or #files <= nf then
		return
	end
	io.flush()
	-- (bash forks each <()/>() child at once, holding every earlier one's end: `tee >(wc -c)
	-- >(wc -l)` — wc -c sees EOF only once wc -l exits. Let a child not yet started start
	-- now, with those ends still open, before the shell closes its own.)
	local gs = {}
	for i = nf + 1, #files do
		if files[i].g then
			gs[#gs + 1] = files[i].g
		end
	end
	rt.procsub_start(gs)
	for i = nf + 1, #files do
		C.close(files[i].fd)
		rt.fd_owner[files[i].fd] = nil
	end
	-- NOT waited for: bash reaps a procsub child asynchronously (only `wait` waits:
	-- procsub_waitpid / procsub_waitall) — a >(cat) whose pipe an `exec 3>` still holds must
	-- not block the shell, nor `read -t .5 < <(sleep 2)` last 2s. Its group runs on as a
	-- (jobless) task; a later `wait $!`/`wait` finds it here (rt.procsub_wait).
	sh.procsub_status = {} -- (the latest ones, for a later `wait $!`: pid -> group)
	for i = nf + 1, #files do
		local g = files[i].g
		if g then -- (no g: its launch failed — nothing ran, nothing to reap)
			sh.procsub_status[files[i].pid] = g
			if not g.done then
				sh.procsub_live = sh.procsub_live or {}
				sh.procsub_live[#sh.procsub_live + 1] = g
			end
		end
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
-- `unset map["$key"]`: bash 5.2 doesn't expand a subscript's QUOTED parts a second time
-- (unset expands the subscript itself) — protect their expansions with backslashes, which
-- array_key's expansion then removes. Only after an unquoted `NAME[`; nil = not this form.
local function unset_arrayref(sh, w)
	if sh.shopt.assoc_expand_once then
		return nil -- (unset takes the subscript literally then: nothing to protect)
	end
	local p1 = w.parts[1]
	if not (p1 and p1.lit and not p1.q and p1.lit:match("^[%a_][%w_]*%[")) then
		return nil
	end
	local quoted
	for i = 2, #w.parts do
		quoted = quoted or w.parts[i].q
	end
	if not quoted then
		return nil
	end
	local buf = {}
	for i, p in ipairs(w.parts) do
		local v = expand_part_str(sh, p)
		buf[i] = (i > 1 and p.q) and v:gsub("[\\$`\"']", "\\%0") or v
	end
	return table.concat(buf)
end
local function expand_args(sh, st, args, is_assign)
	if sh.arrayref_args then
		sh.arrayref_args = nil -- (the previous command's: see rt.mark_arrayref)
	end
	local unset_cmd = is_assign == "unset"
	local words = st.words
	if sh.opt_B == false then -- (`set +B`: no brace expansion)
		words = P.unbrace_words(words)
	end
	for wi, w in ipairs(words) do
		local p1 = w.parts[1]
		local ref = unset_cmd and wi > 1 and unset_arrayref(sh, w)
		if ref then
			args[#args + 1] = rt.cstr(ref)
		elseif wi > 1 and is_assign == true and p1 and p1.lit and p1.lit:match("^[%a_][%w_]*%+?=") then
			args[#args + 1] = rt.cstr(expand_assign_word(sh, w, true)) -- name=value word: no glob, ~ after =/:
		elseif w.plain then
			args[#args + 1] = p1.lit -- (a plain unquoted literal: nothing to expand, split or glob)
		else
			local fs = expand_to_fields(sh, w)
			for k = 1, #fs do
				args[#args + 1] = rt.cstr(fs[k])
			end -- argv entries are C strings: cut at NUL
			if #fs == 1 and wi > 1 and p1 and p1.lit and not p1.q and #w.parts > 1 and sh.shopt.assoc_expand_once
				and p1.lit:match("^[%a_][%w_]*%[") then
				rt.mark_arrayref(sh, fs[1])
			end
		end
		-- (unset's W_ARRAYREF: an unquoted `NAME[…]` word — `unset A[$k]` / `unset A[\]]` —
		-- names an associative element up to its final `]`; see b_unset)
		if unset_cmd and wi > 1 and p1 and p1.lit and not p1.q and p1.lit:match("^[%a_][%w_]*%[")
			and w.src and w.src:sub(-1) == "]" then
			rt.mark_arrayref(sh, args[#args])
		end
	end
end

-- Declaration builtins whose `name=value` arguments are assignment words.
local ASSIGN_CMD = { export = 1, declare = 1, typeset = 1, readonly = 1, ["local"] = 1 }
-- POSIX "special built-in utilities": under `set -o posix`, a prefix assignment
-- on one of these persists in the shell (see the prefix-assignment handling).
-- `exec` is special too but is intercepted earlier with its own env handling.
SPECIAL_BUILTIN = rt.SPECIAL_BUILTIN
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
-- A compound command's DEBUG fires at its HEAD, and $BASH_COMMAND reads as bash prints that
-- head (print_for_command_head …): `for x in a b`, `select s in …`, `((i<3))`, `case w in`.
-- head(sh, st, text): set it (not inside a trap); head(nil, st, kw): `kw NAME in WORDS`.
local function head(sh, st, text)
	if not sh then
		local ws = {}
		for _, w in ipairs(st.words or {}) do
			if w.src then
				ws[#ws + 1] = rt.srcw(w.src)
			end
		end
		return text .. " " .. st.name .. " in " .. table.concat(ws, " ")
	end
	if not (sh.in_trap and sh.in_trap > 0) then
		sh.cur_cmd = { t = "head", text = text }
	end
end
local function run_debug(sh, line)
	local h = sh.traps and sh.traps.DEBUG
	if not h or h == "" or sh.in_debug or (sh.in_pipestage or 0) > 0 then
		return
	end
	-- DEBUG doesn't reach into a subshell/command substitution unless functrace extends it.
	-- (A function call hides it at entry instead — rt.debug_enter — so one the function
	-- sets itself still fires in its body.)
	if (sh.in_subprogram or 0) > 0 and not rt.pseudo_trapped(sh, "DEBUG") then
		return -- (one the subshell set itself is live there)
	end
	sh.in_debug = true
	local saved = sh.status
	if line then
		sh.cur_line = line
	end
	local exited, rret = run_trap(sh, h, "debug trap")
	local trap_status = sh.status
	sh.status = saved
	sh.in_debug = false
	if rret then -- `return` in the DEBUG trap returns from the running function
		error({ __curse_return = rret })
	end
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
			error({ __curse_return = trap_status }) -- (the function returns 2: bash)
		end
		return true
	end
end
M.run_debug = run_debug -- compiled tier fires DEBUG before each native command

local wall_secs = rt.wall_secs

local exec_stmt
-- A simple command's pieces for rt.sr_run (module-level: no per-command closures). spec:
-- the statement's constant part, cached per AST node (weakly: a set -k rewrite is a fresh
-- node each run).
local SIMPLE = { spec = setmetatable({}, { __mode = "k" }) }
function SIMPLE.new_spec(st)
	local names
	if st.assigns then
		names = {}
		for _, a in ipairs(st.assigns) do
			if not a.index then
				names[#names + 1] = a.name
			end
		end
	end
	local spec = { aas = st.arrayargs, assigns = st.assigns, names = names, eredirs = st.redirs,
		so = st.redirs and redirs_touch_stdout(st.redirs) or nil, ix = true }
	SIMPLE.spec[st] = spec
	return spec
end
-- the prefix bindings (`x=1 y=$x cmd`), in order, each value expanded as it binds
function SIMPLE.bind(sh, spec)
	local assigns = spec.assigns
	for i = 1, #assigns do
		local a = assigns[i]
		if a.index then -- (`a[i]=v cmd`: not a valid command-prefix binding)
			rt.pbind_bad(sh, a.name, tostring(a.index))
		elseif a.raw then
			rt.pbind(sh, a.name, nil, false, a.raw)
		elseif a.arith then -- (`x=$((…))`, parsed as arithmetic)
			rt.pbind(sh, a.name, rt.i64_to_str(eval(sh, a.arith)), false)
		else
			rt.pbind(sh, a.name, rt.xw_rhs(sh, a.rhs), a.append)
		end
	end
end
-- the redirections, into rt.sr_run_cmd's saves; a failed one on a posix special builtin
-- is fatal (EX_REDIRFAIL)
function SIMPLE.redirs(rs, sh, argv, spec)
	local sv, ok = apply_redirs(sh, spec.eredirs, argv[1], nil, argv)
	for i = 1, #sv do
		rs[i] = sv[i]
	end
	rs.e2o, rs._sh = sv.e2o, sv._sh
	if not ok and sh.opt_posix and SPECIAL_BUILTIN[argv[1]] and not sh.opt_i then
		sh.status = 1
		error({ __curse_exit = 1 })
	end
	return ok
end
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
	if sh.opt_n and not sh.opt_i and t ~= "parse_error" then -- (a syntax error is still reported)
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
		if t == "assign" and cc and (cc.assigns or cc.list) then -- (or a binding of an assignlist)
			for _, a in ipairs(cc.assigns or cc.list) do
				own = own or a == st
			end
		end
		if not own then
			if not (sh.in_trap and sh.in_trap > 0) then
				sh.cur_cmd = st -- $BASH_COMMAND (a trap's own commands don't replace it)
			end
			if t == "case" and sh.opt_x and st.subject.src and sh.traps and sh.traps.DEBUG then
				xtrace_line(sh, "case " .. rt.srcw(st.subject.src) .. " in") -- (before DEBUG: bash)
				sh.xcase = st
			end
			if run_debug(sh, (sh.in_trap and sh.in_trap > 0 and (sh.calldepth or 0) == sh.trap_calldepth) and sh.cur_line or st.line) then
				sh.xcase = nil
				return -- extdebug: the DEBUG trap said skip it
			end
		end
	end
	-- redirs trailing a compound command: apply around the whole thing, then run it
	-- with redirs temporarily detached (so this guard doesn't re-fire).
	if st.redirs and COMPOUND_REDIR[t] then
		local rd = st.redirs
		local pnp, pnf = procsub_mark(sh) -- a >() redirect target drains after the whole command
		local line0 = sh.cur_line
		if st.top and rd[1].line and not (sh.in_trap and sh.in_trap > 0) then
			sh.cur_line = rd[1].line -- (a top-level one's errors are at its end; nested, bash
		end -- hasn't moved the line on from the enclosing command's)
		local save, ok = apply_redirs(sh, rd)
		if not ok then
			sh.status = 1
			restore_redirs(save)
			sh.cur_line = line0 -- (its ERR trap: bash hasn't updated $LINENO for the redirect)
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
	-- (a function definition leaves the line alone — bash)
	if st.line and t ~= "funcdef" then
		-- a simple command's line is where its SECOND token ended (bash's yacc lookahead:
		-- `nope "x<NL>y"` errors on line 2); cline records that
		local ln = (t == "simple" or t == "assign" or t == "assignlist" or t == "arrayassign") and st.cline or st.line
		if not (sh.in_trap and sh.in_trap > 0 and (sh.calldepth or 0) == sh.trap_calldepth) then
			sh.cur_line = ln
			sh.cur_cline = st.cline or st.line -- (where its $(…) bodies number from)
		elseif sh.trap_base then -- a trap's own commands: its handler's line k is the trapped
			sh.cur_line = sh.trap_base + ln - 1 -- line + k-1 (parse_and_execute counts on from
		end -- it — not in a function the trap calls, whose lines count as usual — bash)
	end
	if t == "assign" then
		local pnf = sh.procsub_files and #sh.procsub_files or 0
		rt.assign_full(sh, st)
		-- this null command's status, whatever its outcome (bash's execute_null_command;
		-- a line abort's is set where it is contained: rt.line_aborted)
		sh:array_assign("PIPESTATUS", { tostring(sh.status) }, false)
		if sh.procsub_files then -- (`x=<(…)`: a null command closes its <() when it ends)
			rt.assign_drain(sh, st, pnf)
		end
	elseif t == "arrayassign" then
		if sh.opt_x and st.raw then -- (bash traces an array literal as written: `+ a=(1 "b c")`)
			xtrace_line(sh, st.name .. (st.append and "+=" or "=") .. rt.srcw(st.raw))
		end
		if st.index then -- `a[0]=(1 2)`: can't assign a list to an array MEMBER (bash)
			rt.arrayassign_member(sh, st.name, st.index)
		else
			local ncs0 = sh.ncs
			local pnf = sh.procsub_files and #sh.procsub_files or 0
			rt.arrayassign_stmt(sh, st.name, nil, st.append, st)
			if sh.status == 0 and sh.ncs ~= ncs0 then -- (`a=( $(exit 3) )`: 3)
				sh.status = sh.last_cmdsub_status
			end
			sh:array_assign("PIPESTATUS", { tostring(sh.status) }, false)
			if sh.procsub_files then -- (`a=( <(…) )`: closed when the assignment ends)
				rt.assign_drain(sh, st, pnf)
			end
		end
	elseif t == "funcdef" then
		rt.def_function(sh, st) -- (the one registration, shared with the compiled tier)
	elseif t == "assignlist" then
		-- a bad array subscript / bad-subst in one binding aborts the REST of the list
		-- (bash: `a=x b[0+]=y c=z` sets only a), keeping the error status.
		local ncs0 = sh.ncs
		local pnf = sh.procsub_files and #sh.procsub_files or 0
		sh.cur_alist = st -- (its bindings' <() stay open until the whole list ends)
		local cc0 = sh.cur_cmd -- (each binding is part of the list: no DEBUG of its own, even
		for _, a in ipairs(st.list) do -- after a command substitution in an earlier one ran)
			sh.assign_err = nil
			sh.cur_cmd = cc0
			exec_stmt(sh, a, hook)
			if sh.assign_err then
				sh.cur_alist = nil
				if sh.procsub_files then -- (the list's <() close with it)
					drain_procsub(sh, 0, pnf)
				end
				return
			end
		end
		-- status: the LAST command substitution's, else 0 (execute_null_command)
		sh.status = sh.ncs ~= ncs0 and sh.last_cmdsub_status or 0
		sh:array_assign("PIPESTATUS", { tostring(sh.status) }, false)
		sh.cur_alist = nil
		if sh.procsub_files then
			drain_procsub(sh, 0, pnf)
		end
	elseif t == "simple" then
		if st.shtail then -- (the last command of a ( … ) / $( … ): rt.exec_tail_lvl)
			sh.shlvl_tail = st.shtail == 2 and sh.pd or -1 - sh.pd
			sh.shlvl_cs = st.cstail
		elseif st.fntail and sh.fntail_arm == st.fntail then -- (see run_function)
			sh.shlvl_tail = sh.fntail_kind == 2 and sh.pd or -1 - sh.pd
			sh.shlvl_cs = true
		end
		if sh.opt_k and st.words then
			-- set -k (keyword): an assignment-shaped word ANYWHERE is an assignment for the
			-- command, not only before its name (bash)
			local keep, extra
			for _, w in ipairs(st.words) do
				local p1 = w.parts and w.parts[1]
				if p1 and p1.lit and not p1.q and w.src and p1.lit:match("^[%a_][%w_]*%+?=") then
					local ok, a = pcall(function()
						return P.parse(w.src).stmts[1]
					end)
					if ok and a and a.t == "assign" then
						extra = extra or {}
						extra[#extra + 1] = a
					else
						keep = keep or {}
						keep[#keep + 1] = w
					end
				else
					keep = keep or {}
					keep[#keep + 1] = w
				end
			end
			if extra then
				local st2 = {}
				for k2, v in pairs(st) do
					st2[k2] = v
				end
				st2.words = keep or {}
				local as = {}
				for _, a in ipairs(st.assigns or {}) do
					as[#as + 1] = a
				end
				for _, a in ipairs(extra) do
					as[#as + 1] = a
				end
				st2.assigns = as
				st = st2
			end
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
		local is_assign = cw1lit ~= nil and ASSIGN_CMD[cw1lit] ~= nil or (cw1lit == "unset" and "unset")
		local args = {}
		local ncs0 = sh.ncs -- (a command substitution performed while expanding: see below)
		-- A word-expansion error (bad substitution, invalid indirect name) aborts the
		-- WHOLE simple command with status 1 but is non-fatal: the script continues.
		local eok, eerr = pcall(expand_args, sh, st, args, is_assign)
		if not eok then
			if type(eerr) == "table" and eerr.__curse_experr and not eerr.__curse_lineabort then
				rt.posix_arith_fatal(sh, eerr)
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
				sh.cur_alist = st -- (its <() close with the null command, below)
				for _, a in ipairs(st.assigns) do
					-- NAME=(…) is a literal only as a command PREFIX; with no command left after
					-- expansion (`a=(1 2) 2>/dev/null`, `a=(x) $empty`) it's an array assignment
					exec_stmt(sh, a, hook)
				end
				sh.cur_alist = nil
				if sh.status == 0 and sh.ncs ~= ncs0 then -- (`x=1 $(exit 5)`: 5)
					sh.status = sh.last_cmdsub_status
				end
			else -- a bare $(...) / redirection: status is the last cmdsub's, else 0
				sh.status = sh.ncs ~= ncs0 and sh.last_cmdsub_status or 0
			end
			-- a redirection with no command still opens/truncates its target (`> file`)
			if st.redirs then
				local save, ok = apply_redirs(sh, st.redirs)
				if not ok then
					sh.status = 1
				end
				restore_redirs(save)
			end
			sh:array_assign("PIPESTATUS", { tostring(sh.status) }, false) -- (a null command's too)
			drain_procsub(sh, pnp, pnf) -- (`x=<(…) $empty`: closed as the null command ends)
			return
		end
		-- the prefix bindings, a declaration builtin's NAME=(…) literals, the command (its
		-- set -x trace, its redirections, `exec`), $_ and PIPESTATUS: the simple-command
		-- runner the compiled tier shares (rt.sr_run)
		rt.sr_run(sh, args, SIMPLE.spec[st] or SIMPLE.new_spec(st), st.assigns and SIMPLE.bind or nil, hook, nil,
			st.redirs and SIMPLE.redirs or nil)
		drain_procsub(sh, pnp, pnf) -- feed >() temps, clean up <()/>() temp files
	elseif t == "forc" then
		-- DEBUG fires (at the `for` line) before the init, before EACH condition
		-- evaluation, and before EACH step — bash's `[6][6][7]…` per-iteration pattern.
		-- (a slot as bash stores it: leading blanks dropped, an empty one is `1` — make_cmd.c
		-- make_arith_for_command; it still fires DEBUG and traces `+ (( 1 ))`)
		local function stext(slot)
			local s = (st.src and st.src[slot] or ""):match("^[ \t]*(.-)$")
			return s == "" and "1" or s
		end
		local function fdbg(slot)
			local intrap = sh.in_trap and sh.in_trap > 0 and (sh.calldepth or 0) == sh.trap_calldepth
			if sh.opt_x and st.src then -- (traced before its DEBUG: eval_arith_for_expr)
				if not intrap then -- (under the `for` line — the step's too, not the body's last)
					sh.cur_line = st.line
				end
				arith_trace(sh, stext(slot)) -- (bash keeps a trailing blank)
			end
			if sh.traps and sh.traps.DEBUG then
				head(sh, st, "((" .. stext(slot) .. "))")
			end
			run_debug(sh, intrap and sh.cur_line or st.line)
		end
		-- A slot whose arith failed to parse (`i='3'`) was deferred: bash reports the
		-- error at RUNTIME and runs the loop zero (or partial) iterations, non-fatally.
		local inslot, svcmd = false, nil
		local function ev(node, slot)
			sh.cur_line = st.line -- $LINENO inside the for(( init/cond/step is the `for` line (bash),
			-- not whatever line the body last ran (the cond re-evals per iteration)
			if node.k == "arith_perr" then
				local sv = P.arith_cmd
				P.arith_cmd = "(("
				local _, perr = pcall(P.arith, node.raw)
				arith_pre(sh, perr)
				io.stderr:write("curse: " .. P.arith_errmsg(node.raw, perr) .. "\n")
				P.arith_cmd = sv
				error({ __curse_exit = 1, __curse_experr = true })
			end
			-- (an arithmetic error names `((` and ends the loop with status 1, the shell goes on:
			-- the loop's handler below sees `inslot` still set)
			svcmd, inslot = P.arith_cmd, true
			P.arith_cmd = "(("
			local v = eval(sh, node)
			P.arith_cmd, inslot = svcmd, false
			return v
		end
		local bodystatus = 0 -- a loop's status is its last body command's (0 if none)
		local ld0 = sh.loopdepth or 0
		sh.loopdepth = ld0 + 1
		local cok, cerr = pcall(function()
			fdbg(1)
			if st.init then
				ev(st.init, 1)
			end
			while true do
				local hr, herr = hook("loop", st.id, st, sh)
				if hr then -- (the rest of the loop ran compiled: see tier's loop fragments)
					if herr ~= nil then
						error(herr, 0)
					end
					bodystatus = sh.status
					break
				end
				if PREEMPT[0] ~= 0 then
					rt.preempt()
				end
				fdbg(2)
				if st.cond then
					if not truth(ev(st.cond, 2)) then
						break
					end
				end
				local act = run_loop_body(sh, st.body, hook)
				bodystatus = sh.status
				if act == "break" then
					break
				end
				fdbg(3)
				if st.step then
					ev(st.step, 3)
				end -- continue still runs the step
			end
		end)
		sh.loopdepth = ld0 -- (a signal re-raised from the body already gave the level back)
		if not cok and inslot then -- (an init/cond/step failed)
			P.arith_cmd = svcmd
			if type(cerr) == "table" and cerr.__curse_matherr and not cerr.__curse_subscript then
				cerr = { __curse_exit = 1, __curse_experr = true }
			end
		end
		if not cok then
			if type(cerr) == "table" and cerr.__curse_experr then
				sh.status = 1
				if sh.opt_e and sh.noerr == 0 then -- (an arith-for's failure: errexit, unless exempt)
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
			local hr, herr = hook("loop", st.id, st, sh)
			if hr then -- (the rest of the loop ran compiled: see tier's loop fragments)
				if herr ~= nil then
					sh.loopdepth = sh.loopdepth - 1
					error(herr, 0)
				end
				bodystatus = sh.status
				break
			end
			if PREEMPT[0] ~= 0 then
				rt.preempt()
			end
			-- a break/continue in the CONDITION affects this loop too (bash)
			sh.noerr = sh.noerr + 1
			local cok, cerr = pcall(exec_list, sh, st.cond, hook, false)
			sh.noerr = sh.noerr - 1
			if not cok and loop_signal(sh, cerr) == "break" then
				break
			end -- (continue: fall through to re-test)
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
		rt.warn_stmt(sh, st)
	elseif t == "parse_error" then
		rt.parse_error_stmt(sh, st)
	elseif t == "group" then
		-- { list; } runs in the current shell. Any trailing redirs are applied by the
		-- COMPOUND_REDIR wrapper above (which checks open failures + errexit), so here
		-- st.redirs is already detached.
		exec_list(sh, st.body, hook, false)
	elseif t == "subshell" then
		-- ( list ) runs IN-PROCESS: rt.subshell_run checkpoints what a fork would isolate
		-- (vars, params, functions, cwd, …) and restores it after. (A no-op OSR hook inside:
		-- a switch into compiled code mustn't unwind past the checkpoint.)
		local saves
		if sh.traps and sh.traps.ERR and not (sh.in_trap and sh.in_trap > 0) then
			sh.cur_cmd = st -- ($BASH_COMMAND for an ERR trap it fires: the whole `( … )`)
		end
		local ok, err = pcall(sh.subshell_run, sh, function(sh)
			if st.redirs then
				if st.top and st.redirs[1].line and not (sh.in_trap and sh.in_trap > 0) then
					sh.cur_line = st.redirs[1].line
				end
				local sv, rok = apply_redirs(sh, st.redirs)
				saves = sv
				if rok == false then -- (a failed redirect: the body never runs, status 1)
					sh.status = 1
					return
				end
			end
			exec_list(sh, st.body, SUBHOOK, false)
		end, nil, st, st.inplace) -- (st: its text, for the report if a signal kills it)
		if saves then
			restore_redirs(saves)
		end
		if not ok then
			error(err, 0)
		end
		-- (bash waits for the forked child as a one-process job: setjstatus → PIPESTATUS)
		sh:array_assign("PIPESTATUS", { tostring(sh.status) }, false)
	elseif t == "background" then
		-- cmd & : runs IN-PROCESS as a background task (rt: Shell:bg_launch) — a subshell
		-- the scheduler runs whenever the shell waits; $! is its virtual pid, status 0.
		local c1 = st.cmd
		while c1 and (c1.t == "pipeline") and c1.cmds do
			c1 = c1.cmds[1]
		end
		local dtext = require("deparse").command_text(st.cmd) -- (bash prints the job as print_cmd.c does)
		local cmdstr = (dtext ~= "" and dtext) or st.text
			or (c1 and c1.words and c1.words[1] and c1.words[1].parts[1] and c1.words[1].parts[1].lit) or "job"
		local cmd = st.cmd
		local run = rt.bg_tail_stmt(cmd)
		rt.env_rebuilt(sh) -- (execute_simple_command's, before the fork)
		local job = sh:bg_launch(function(ssh)
			exec_stmt(ssh, run, SUBHOOK)
		end, cmdstr, cmd.t == "subshell", cmd.t == "simple")
		if cmd.t == "pipeline" and job and job.g then
			rt.job_mark_pipe(job) -- (a pipeline job: `kill %N` reaches its every stage)
		end
		sh.status = 0
	elseif t == "coproc" then
		-- coproc NAME cmd: run cmd asynchronously with its stdin/stdout on two pipes whose
		-- other ends the shell keeps as NAME=(read-fd write-fd); NAME_PID and $! = its pid.
		if not st.name:match("^[%a_][%w_]*$") then -- `coproc @ {…}`
			rt.ierr = true -- (check_identifier's / execute_coproc's internal_error)
			io.stderr:write("curse: `" .. st.name .. "': not a valid identifier\n")
			sh.status = 1
			return
		end
		local cmd = st.cmd
		rt.coproc_start(sh, st.name, function(ssh)
			exec_stmt(ssh, cmd, SUBHOOK)
		end, cmd.t == "subshell", cmd.t == "simple")
	elseif t == "arithcmd" then
		-- A `(( expr ))` command (standalone or as an if/while condition) is NOT fatal
		-- on a division-by-zero — it just yields status 1 and execution continues
		-- (unlike a `$(( ))` word expansion, which aborts the command list).
		if sh.opt_x and st.src then
			arith_trace(sh, st.src)
		end
		local sv = P.arith_cmd
		P.arith_cmd = "((" -- (bash's this_command_name in its error messages)
		local ok, v = pcall(eval, sh, st.expr)
		P.arith_cmd = sv
		if ok then
			sh.status = truth(v) and 0 or 1
		elseif type(v) == "table" and v.__curse_matherr and not v.__curse_subscript then
			sh.status = 1
		else
			error(v)
		end
	elseif t == "dbracket" then
		-- (an arith error in an -eq operand makes just that primary false — eval_dbracket;
		-- one expanding a WORD, `[[ a =~ $((1/0)) ]]`, abandons the line: DISCARD, bash)
		local ok, v = pcall(eval_dbracket, sh, st.expr)
		if ok then
			sh.status = v and 0 or 1
		elseif type(v) == "table" and v.__curse_regexerr then
			sh.status = 2
		else
			error(v)
		end
	elseif t == "case" then
		if sh.xcase == st then
			sh.xcase = nil -- (already traced, ahead of its DEBUG trap)
		elseif sh.opt_x and st.subject.src then
			xtrace_line(sh, "case " .. rt.srcw(st.subject.src) .. " in") -- (as written: bash)
		end
		local subj = expand_word(sh, st.subject)
		local fall = false -- carrying a `;&` fall-through into the next clause
		-- a matching body still sees the PREVIOUS $? (bash); the case's status is its LAST
		-- executed body's, 0 when that body is empty or nothing matched
		local lastempty = true
		for _, cl in ipairs(st.clauses) do
			local matched = fall
			if not matched then
				for _, pat in ipairs(cl.pats) do
					local g = case_pattern(sh, P.parse_word(pat)) -- vars resolved; quoted metachars literal
					if rt.glob_match(subj, g, sh.shopt.nocasematch and true or nil, not sh.shopt.extglob) then
						matched = true
						break
					end
				end
			end
			if matched then
				lastempty = #cl.body == 0
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
		if lastempty then
			sh.status = 0
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
				if k < #st.items then -- (a non-final operand ignores errexit throughout — in a
					-- function it calls too — as a condition does)
					sh.noerr = sh.noerr + 1
					local ok, err = pcall(exec_stmt, sh, it.cmd, hook)
					sh.noerr = sh.noerr - 1
					if not ok then
						error(err, 0)
					end
				else
					exec_stmt(sh, it.cmd, hook)
				end
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
		-- (`! set …` ignores its OWN special-builtin failure — rt.spb_run — not one inside
		-- a function or group it runs)
		local c1 = st.cmds and #st.cmds == 1 and st.cmds[1]
		local w1 = c1 and c1.t == "simple" and c1.words and c1.words[1]
		sh.spb_neg = w1 and #w1.parts == 1 and SPECIAL_BUILTIN[w1.parts[1].lit or ""] and true or nil
		local ok, err = pcall(exec_stmt, sh, setmetatable({ negate = false }, { __index = st }), hook)
		sh.spb_neg = nil
		sh.noerr = sh.noerr - ign
		if not ok then
			error(err, 0)
		end
		sh.status = (sh.status == 0) and 1 or 0
	elseif t == "pipeline" then
		-- a | b | c: the stages run IN-PROCESS under the runtime's coroutine scheduler (each on
		-- its own shell clone, joined by real pipes; external commands are real processes).
		-- It sets $?/PIPESTATUS, drains the last stage into a $(…) capture, and runs a
		-- `shopt -s lastpipe` last stage in this shell. (No OSR hook inside a stage: a switch
		-- must not unwind out of its coroutine.)
		local cmds, nst = st.cmds, #st.cmds
		if nst == 1 then
			exec_stmt(sh, cmds[1], hook) -- just a `! cmd` negation, no real pipe
		else
			local lastpipe = sh.shopt.lastpipe and not sh.opt_i
			local fns, inproc = {}, {}
			for k = 1, nst do
				-- DEBUG fires before each stage IN THE PARENT (bash: the stage itself does NOT
				-- fire it), but only for a stage that is itself a DEBUG-firing node — a
				-- `{ }`/compound stage fires nothing (`{ …; } | cat` fires once, for cat). The
				-- lastpipe stage fires via its own exec_stmt instead.
				local inshell = k == nst and lastpipe
				if DEBUG_FIRE[cmds[k].t] and not inshell then
					if not (sh.in_trap and sh.in_trap > 0) then
						sh.cur_cmd = cmds[k] -- $BASH_COMMAND: this stage
					end
					run_debug(sh, (sh.in_trap and sh.in_trap > 0 and (sh.calldepth or 0) == sh.trap_calldepth) and sh.cur_line or (cmds[k].line or st.line))
				end
				local stage = cmds[k]
				fns[k] = function(ssh)
					if not inshell then -- a stage re-runs neither DEBUG nor ERR
						ssh.in_pipestage = (ssh.in_pipestage or 0) + 1
					end
					exec_stmt(ssh, stage, SUBHOOK)
				end
				inproc[k] = rt.stage_kind(stage, function(c)
					return sh.functions[c] ~= nil
				end)
			end
			sh:run_pipeline(fns, false, inproc, nil, nil, cmds)
			-- bash quirk (execute_cmd.c:720): the LAST stage of a pipeline, when it is a
			-- subshell `(…)` that failed, runs the ERR trap for that subshell — on top of
			-- the pipeline's own ERR fire — so `(false)|(false)` triggers ERR twice. It
			-- keys on the subshell's OWN failure (not the pipeline's `!`, which applies to
			-- the pipeline), so `! (false)|(false)` still fires it once. A group/simple
			-- last stage does not (only the pipeline fires).
			if cmds[nst] and cmds[nst].t == "subshell" and (sh.last_stage_status or 0) ~= 0 and sh.noerr == 0 then
				fire_err_trap(sh)
			end
		end
	elseif t == "forin" then
		-- an invalid loop-variable name (`for i.j`/`for -`) is a NON-fatal runtime
		-- error (bash: status 1, no iterations), not a parse error.
		if not st.name:match("^[%a_][%w_]*$") then
			rt.for_badname(sh, st.name)
			return
		end
		-- expand the word list ONCE (bash semantics) and stash it in sh.forstate so
		-- a mid-loop OSR resumes the same list + index.
		local list = {}
		-- a failglob no-match while expanding the word list fails the `for` non-fatally
		-- (status 1, no iterations), like bash — not an abort.
		local eok, eerr = pcall(function()
			for _, w in ipairs(sh.opt_B == false and P.unbrace_words(st.words) or st.words) do
				local fs = expand_to_fields(sh, w)
				for k = 1, #fs do
					list[#list + 1] = fs[k]
				end
			end
		end)
		if not eok then
			if type(eerr) == "table" and eerr.__curse_experr and not eerr.__curse_lineabort then
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
		-- (this activation's state: a recursive call re-running this loop must not clobber
		-- it; republished before each OSR point, so a switch resumes THIS loop)
		local fs = { list = list, idx = 0 }
		local bodystatus = 0
		sh.loopdepth = (sh.loopdepth or 0) + 1
		while true do
			sh.forstate[st.id] = fs
			local hr, herr = hook("loop", st.id, st, sh)
			if hr then -- (the rest of the loop ran compiled: see tier's loop fragments)
				if herr ~= nil then
					sh.loopdepth = sh.loopdepth - 1
					error(herr, 0)
				end
				bodystatus = sh.status
				break
			end
			if PREEMPT[0] ~= 0 then
				rt.preempt()
			end
			fs.idx = fs.idx + 1
			if fs.idx > #fs.list then
				break
			end
			if sh.opt_x then -- the header as written, each iteration (bash; before DEBUG)
				xtrace_line(sh, head(nil, st, "for"))
			end
			if sh.traps and sh.traps.DEBUG then
				head(sh, st, head(nil, st, "for"))
			end
			run_debug(sh, st.line) -- DEBUG fires at the `for` header before each iteration
			if not rt.for_assign(sh, st.name, fs.list[fs.idx]) then
				bodystatus = 1
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
	elseif t == "select" then
		-- select NAME [in WORDS]: print the numbered menu + $PS3 to stderr, read a line from
		-- stdin (EOF ends the loop); an empty line redisplays the menu; otherwise REPLY=line,
		-- NAME=the chosen item (or empty when it isn't a valid number), run the body.
		if not st.name:match("^[%a_][%w_]*$") then
			rt.ierr = true -- (check_identifier's / execute_coproc's internal_error)
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
		local bodystatus = 0
		sh.loopdepth = (sh.loopdepth or 0) + 1
		if sh.opt_x then -- (traced before the DEBUG trap runs: execute_select_command)
			xtrace_line(sh, head(nil, st, "select"))
		end
		if sh.traps and sh.traps.DEBUG then -- (once, before the menu: execute_select_command)
			head(sh, st, head(nil, st, "select"))
			run_debug(sh, (sh.in_trap and sh.in_trap > 0 and (sh.calldepth or 0) == sh.trap_calldepth) and sh.cur_line or st.line)
		end
		rt.select_menu(sh, list)
		while true do
			hook("loop", st.id, st, sh) -- (st: the tier hook tells the program's loops from eval'd ones)
			if not rt.select_next(sh, list, st.name) then -- (the prompt/read/REPLY/NAME round: EOF
				bodystatus = 1 -- or a readonly NAME ends the loop, status 1)
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
M.exec_stmt = exec_stmt -- (runtime and the source/fc/eval builtins run parsed statements through it)
M.xtrace = xtrace -- set -x trace, for rt.exec_dynamic (compiled dynamic command word)

-- Run a trap handler string; preserves $LINENO (so an ERR/EXIT trap sees the
-- failing command's line, not the handler's). Returns true if it called exit; and, when
-- the handler ran `return N` while a function or sourced script is running, N as a 2nd
-- result: the CALLER (once it has undone its own state) raises it, so the return ends
-- that function/source — bash's _run_trap_internal longjmps to return_catch (trap.c).
-- (Not for the EXIT/RETURN traps: their callers keep the status.)
local trap_seen, trap_seen_n = {}, 0 -- (handler texts run once: the next run compiles)
-- (an INTERP_FRAMES runner: the compiled handler's error prefixes read sh.cur_line)
local function run_trap_mod(mod, sh)
	local r = require("tier").run_compiled(mod, sh, nil, true) -- (no tail call: this frame
	return r -- must stay on the stack for rt.current_line to find)
end
rt.INTERP_FRAMES[run_trap_mod] = true
-- tag: bash's parse_and_execute input name for this kind of trap — "trap" (a signal's),
-- "exit trap", "debug trap", "error trap", "return trap" (trap.c) — which labels a syntax
-- error in the handler text (`NAME: debug trap: line N:`); the text's lines count from
-- the line the handler runs at (the callers set it: 1 unless DEBUG/ERR/RETURN, which
-- don't reset line_number — SEVAL_RESETLINE).
run_trap = function(sh, code, tag)
	local exited, savedline, rret = false, sh.cur_line, nil
	local spl, slb = sh.perr_label, sh.trap_lbase
	sh.perr_label, sh.trap_lbase = tag, tag and savedline or nil
	local saved_tcd, saved_ts, saved_tb = sh.trap_calldepth, sh.trap_saved, sh.trap_base
	sh.trap_base = sh.cur_line or 1 -- (the handler's first line: the trapped one)
	sh.trap_calldepth = sh.calldepth or 0
	sh.trap_saved = sh.status -- (bash's trap_saved_exit_value: see rt.return_default)
	sh.in_trap = (sh.in_trap or 0) + 1
	local sxd = sh.xdepth -- (a handler's commands trace one level deeper: `++ cmd`, bash)
	sh.xdepth = (sxd or 0) + 1
	-- (bash's save_pipestatus_array: the handler's own commands leave $PIPESTATUS as it was)
	local psb = sh.vars.PIPESTATUS
	local psa = psb and psb.arr
	-- A handler that runs again is compiled (tier fragment, keyed by its text and the trap
	-- state): the first run interprets it, so a one-shot EXIT trap never loads the compiler.
	local seen = trap_seen[code]
	local mod
	M.v_echo(sh, code, nil, {}) -- (set -v: the handler's text as it's read)
	if seen then
		mod = require("tier").try_fragment(code, false, sh, true)
	else
		trap_seen_n = trap_seen_n + 1
		if trap_seen_n > 256 then
			trap_seen, trap_seen_n = {}, 1
		end
		trap_seen[code] = true
	end
	if sh.jobs_waited or sh.jobs_pending then -- (the handler is parse_and_execute'd: reading it notifies and cleans up — rt.jobs_line)
		rt.jobs_line(sh)
	end
	local stmts, k = mod and {} or P.parse(code, sh).stmts, 0 -- (sh: aliases expand, bash)
	local function body()
		if mod then -- (a line abort is contained by run_compiled: the rest of that line is skipped)
			return run_trap_mod(mod, sh)
		end
		while k < #stmts do
			k = k + 1
			local st = stmts[k]
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
	end
	local ne0 = sh.noerr
	local ok, err = pcall(body)
	-- (the handler is parse_and_execute'd: a line abort in it — a div0 — skips the rest of
	-- that handler line only)
	while not ok and type(err) == "table" and err.__curse_lineabort and not err.__curse_discard do
		sh.status, sh.noerr = 1, ne0
		while k < #stmts and not stmts[k + 1].lgstart do
			k = k + 1
		end
		ok, err = pcall(body)
	end
	sh.in_trap = sh.in_trap - 1
	sh.xdepth = sxd
	if psa and sh.vars.PIPESTATUS == psb then
		psb.arr = psa
	end
	sh.trap_calldepth, sh.trap_saved, sh.trap_base = saved_tcd, saved_ts, saved_tb
	sh.cur_line = savedline
	sh.perr_label, sh.trap_lbase = spl, slb
	if not ok then
		if type(err) == "table" and err.__curse_discard then -- (bash's DISCARD: unwinds the
			error(err, 0) -- handler and abandons the interrupted top-level command)
		elseif type(err) == "table" and err.__curse_parseerr then -- syntax error in the trap code: warned, non-fatal, doesn't exit or change status (bash)
		elseif type(err) == "table" and err.__curse_exit then
			sh.status = err.__curse_exit
			exited = true
		elseif type(err) == "table" and (err.__curse_break or err.__curse_continue)
			and sh.lc_depth and sh.lc_depth > 0 and sh.loopdepth == sh.lc_depth then
			-- the interrupted loop is COMPILED: it acts on the break/continue after the
			-- command that was running (its sh.loopctl checks), as bash's breaking/continuing
			sh.status = 0
			sh.loopctl = { kind = err.__curse_break and "break" or "continue", n = err.__curse_break or err.__curse_continue }
		elseif type(err) == "table" and err.__curse_return then
			sh.status = err.__curse_return -- `return N` in a trap sets its status
			if (sh.calldepth or 0) > 0 or (sh.sourcedepth or 0) > 0 then
				rret = err.__curse_return
			end
		else
			error(err)
		end -- a real error propagates
	end
	return exited, rret
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
	-- (not inherited by functions/subshells — but one SET in a function or subshell
	-- fires there, as bash's trap is active in the context that set it)
	-- (functions hide it on entry — rt.debug_enter; a subshell doesn't inherit it either)
	-- (a stage skips only the INHERITED trap: one set inside the stage fires there)
	local sp, ps = sh.in_subprogram or 0, sh.in_pipestage or 0
	local errscope = sh.opt_errtrace or ((ps == 0 or ps == sh.err_trap_ps) and (sp == 0 or sp == sh.err_trap_sp))
	if sh.err_skip then -- (the failing call set the trap itself: bash sampled none before it)
		sh.err_skip = nil
		return
	end
	if h and h ~= "" and not sh.in_err_trap and errscope then
		sh.in_err_trap = true
		local saved = sh.status
		local exited, rret = run_trap(sh, h, "error trap")
		local xst = sh.status
		sh.status = saved
		sh.in_err_trap = false
		if exited then -- `exit` in the ERR trap exits the shell (_run_trap_internal)
			error({ __curse_exit = xst })
		end
		if rret then -- `trap 'return N' ERR`: the failing command's function returns N
			error({ __curse_return = rret })
		end
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
-- expand it as if double-quoted — $var/$(…)/`…`, `\` escaping only $ ` " \ (bash's
-- Q_DOUBLE_QUOTES; a bare `"` is literal, so the heredoc-style body parse).
M.prompt_string = function(sh, s, isprompt)
	local decoded = sh:prompt_escapes(s or "", isprompt)
	if not decoded:find("[$`\\]") or not rt.prompt_expands(sh) then
		return decoded
	end
	return expand_word(sh, P.parse_heredoc(decoded, false, nil, true))
end
M.run_trap_str = function(sh, code) -- a late-forked subshell child runs its own EXIT trap
	return run_trap(sh, code, "exit trap")
end

-- (`return N` status is now rt.return_status — a pure runtime primitive the compiled
-- tier calls directly.)

-- Run the trap for the signal `signum` that the async handler delivered via the VM
-- hook (lib_cursesig.c). No pending queue — the hook hands us exactly the signal
-- that fired. A signal arriving DURING a handler runs nested, inside it, as bash's
-- run_pending_traps does at the handler's next command (running_trap only warns) — all
-- but SIGCHLD inside its own trap (SIG_INPROGRESS: it runs again once that one ends). A
-- signal trap doesn't change $? unless it exits/returns; `exit` in the handler
-- propagates to exit the shell (bash).
local chld_running, chld_again
local function run_signal(sh, signum, direct, nested)
	if signum == 17 and chld_running then
		chld_again = true
		return
	end
	if not direct and (rt.defer_loading(sh, signum) or rt.defer_signal(sh, signum)) then
		return -- (the parent's: runs once the in-process subshell has ended)
	end
	local h = sh.traps and sh.traps["SIG" .. (NUMSIG[signum] or "")]
	if not h or h == "" then
		if not h and not direct then -- (caught untrapped: the EXIT trap, then death — rt.termsig)
			rt.termsig(sh, signum)
		end
		return
	end
	if not direct and not nested and rt.fg_held(signum) then
		return -- (a foreground command runs: the trap runs once it has finished)
	end
	-- an asynchronously-delivered signal handler reports $LINENO = 1 (bash).
	local saved, sl = sh.status, sh.cur_line
	sh.cur_line = 1
	local exited, rret
	if signum == 17 then
		chld_running = true
		local ok, e1, e2 = pcall(run_trap, sh, h, "trap")
		chld_running = nil
		if not ok then
			chld_again = nil
			error(e1, 0)
		end
		exited, rret = e1, e2
		if chld_again then -- (children reaped meanwhile: the trap runs for them too)
			chld_again = nil
			C.kill(C.getpid(), 17)
		end
	else
		exited, rret = run_trap(sh, h, "trap")
	end
	sh.cur_line = sl
	-- a trapped signal ends a `wait`: 128+sig (see b_wait) — but SIGCHLD only in posix mode
	if sh.in_wait and (signum ~= 17 or sh.opt_posix) then
		sh.wait_sig = signum
	end
	if exited then
		error({ __curse_exit = sh.status })
	end -- `exit` in the trap exits the shell
	if rret then -- `return` in the handler returns from the interrupted function
		sh.status = saved
		error({ __curse_return = rret })
	end
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
	if not ok then
		if type(err) == "table" and err.__curse_noexittrap then
			sh.traps = sh.traps and shallow_noexit(sh.traps) -- `exec cmd`: the process is gone
		end
		if type(err) == "table" and err.__curse_exit then
			-- (the REPL stops reading — except an interactive one after a syntax error)
			sh.exit_requested = not (err.__curse_parseerr and sh.opt_i and sh.defer_exit_trap) or nil
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
	-- (the script ran to its end: the reader reading end of input notifies of the jobs
	-- that ended meanwhile — rt.jobs_line; not after an `exit`)
	-- (reader_loop read end of input: bash's `executing` is 0 from here — not after an
	-- `exit`, nor under -c (ONESHOT) — so executing_line_number stops naming a [[ ]] /
	-- (( )) / for (( )) command's own line: M.fn_redir_line)
	sh.eof_read = ok and not sh.opt_c or nil
	if ok and (sh.jobs_waited or sh.jobs_pending) and sh.main_src and not sh.opt_c then
		local okp, ast = pcall(P.parse, sh.main_src)
		rt.jobs_line(sh, okp and ast.eofline or nil)
	end
	M.run_exit_trap(sh)
	if sh.coprocs and next(sh.coprocs) then
		rt.coproc_exit_dispose(sh, ok)
	end
end
M.run_exit_trap = function(sh)
	local h = sh.traps and sh.traps.EXIT
	if h and h ~= "" and not sh.in_exit_trap then
		sh.in_exit_trap = true
		local saved = sh.status
		sh.cur_line = 1 -- (bash: the EXIT trap's $LINENO counts from 1)
		if not run_trap(sh, h, "exit trap") then
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
-- module's run() so `exit`, nounset, errexit etc. thrown from compiled
-- code unwind cleanly (setting $?) instead of crashing as an uncaught table.
function M.finish_run(sh, fn)
	finish(sh, pcall(fn))
end

-- Run LAZILY from source: parse one top-level statement, execute it, repeat.
-- Instant start on large scripts (no full parse up front), and it never
-- tokenizes past an `exit` — so a hybrid shell+binary installer just works with
-- no special-casing. `hook("stmt", k)` fires per top-level statement (same k as
-- the eager AST, so tier OSR-by-stmt still lines up).
-- Run one logical line (a parser group) the way the shell runs its own input.
local function run_group(sh, lg, hook, k)
	sh.cmd_number = (sh.cmd_number or 0) + 1 -- (the prompt's \#)
	if sh.jobs_waited or sh.jobs_pending then -- (reading a line: notify_and_cleanup — rt.jobs_line)
		rt.jobs_line(sh, lg.rline)
	end
	-- bash parses a whole LOGICAL LINE (a `simple_list` up to a top-level newline)
	-- before executing any of it, so a syntax error ANYWHERE on the line means the
	-- line runs nothing (retroactive). Handle that first.
	if lg.perr then
		-- A RECOVERABLE parse error (invalid `NAME=( … )` array-literal element) is
		-- reported but NON-fatal: the assignment is dropped (var stays unset) and the
		-- script continues, like bash. Any other syntax error runs nothing + exits 2.
		if lg.perr.recoverable then
			M.report_recoverable(sh, lg.perr)
		else
			exec_stmt(sh, lg.perr, hook)
		end -- raises __curse_exit=2 (bash exits)
	end
	-- line mode (a script whose parse depends on run-time state — aliases, history
	-- expansion, set -v): the reader above hands over one logical line at a time and the
	-- tier runs it COMPILED (M.lm_exec: false when this line can't compile)
	if sh.lm and M.lm_exec and #lg.stmts > 0 then
		local k2 = M.lm_exec(sh, lg, k)
		if k2 then
			return k2
		end
	end
	for _, st in ipairs(lg.stmts) do
		k = k + 1
		hook("stmt", k)
		local ne0, pf0 = sh.noerr, sh.procsub_files and #sh.procsub_files or 0
		local ok, err = pcall(exec_stmt, sh, st, hook)
		if not ok then
			-- a fatal WORD-context expansion (div0 in $((…)), failglob no-match) aborts
			-- the REST of this line; under `set -e` it exits the shell like any failure
			if type(err) == "table" and err.__curse_lineabort then
				if rt.lineabort_exits(sh, err) then
					error(err)
				end
				sh.noerr = ne0 -- (an `if`/`&&` condition it unwound out of: errexit is live again)
				rt.posix_arith_fatal(sh, err)
				rt.line_aborted(sh, err.__curse_badusage and not sh.opt_c and 2 or 1, pf0) -- (a failed ${x:=w})
				rt.line_drift(sh, lg.sline, lg.eline) -- (bash's line numbers drift from here)
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
	return k
end

-- Does BUF still need more lines to be a complete command (the REPL's test)?
local function needs_more(buf)
	local bs = buf:match("(\\*)$")
	if #bs % 2 == 1 then -- (a trailing unescaped backslash continues the line)
		return true
	end
	local ok, r = pcall(P.parse, buf)
	local perr = (not ok and tostring(r)) or (r and r.stmts and r.stmts[1] and r.stmts[1].t == "parse_error"
		and tostring(r.stmts[1].msg)) or ""
	return perr:find("unexpected end of file", 1, true) ~= nil or perr:find("unexpected EOF", 1, true) ~= nil
end

-- the here-document delimiters a line opens (`<<EOF`, `<<-'EOF'`), outside quotes
local function heredoc_opens(line)
	local out, i, n, q = {}, 1, #line, nil
	while i <= n do
		local c = line:sub(i, i)
		if q then
			if c == q then
				q = nil
			elseif c == "\\" and q == '"' then
				i = i + 1
			end
		elseif c == "\\" then
			i = i + 1
		elseif c == "'" or c == '"' or c == "`" then
			q = c
		elseif c == "#" and (i == 1 or line:sub(i - 1, i - 1):match("[%s;&|()]")) then
			break
		elseif line:sub(i, i + 1) == "<<" and line:sub(i + 2, i + 2) ~= "<" then
			local j = i + 2
			local strip = line:sub(j, j) == "-"
			if strip then
				j = j + 1
			end
			j = line:match("^[ \t]*()", j)
			local w = line:match("^[^%s;&|()<>]+", j)
			if w then
				out[#out + 1] = { word = (w:gsub("[\\'\"]", "")), strip = strip }
				i = j + #w - 1
			end
		end
		i = i + 1
	end
	return out
end

-- The rest of the script once command history is on (`set -o history` / `set -H`): read
-- it the way bash's reader does, one physical line at a time — history-expand each line
-- (not here-document bodies), record it (cmdhist joins a multi-line command into one
-- entry), and run each complete command as soon as it has been read.
-- set -v for text parsed a logical line at a time (eval, source): echo each line of TEXT
-- once the parser has read into it — through line UPTO (1-based, relative to TEXT; nil =
-- all of it). `st` carries what's been echoed.
local function v_echo(sh, text, upto, st)
	if not sh.opt_v then
		return
	end
	if not st.lines then
		st.lines, st.done = {}, st.done or 0
		for l in (text:sub(-1) == "\n" and text or text .. "\n"):gmatch("([^\n]*)\n") do
			st.lines[#st.lines + 1] = l
		end
	end
	upto = math.min(upto or #st.lines, #st.lines)
	for k = st.done + 1, upto do
		io.stderr:write(st.lines[k], "\n")
	end
	st.done = math.max(st.done, upto)
end
M.v_echo = v_echo

-- One physical input line through history (bash's shell_getc → pre_process_line):
-- a here-document body line is recorded as read; otherwise `!` expansion (echoing the
-- result; a failed or `:p` expansion discards the line: nil) and recording. ST is the
-- per-command recording state, HDQ the here-documents still open, MID whether this
-- line continues a command. Shared by the script reader below and the REPL.
function M.history_line(sh, st, hdq, line, mid, lno)
	local H = require("hist")
	if #hdq > 0 then -- a here-document body line: no expansion, kept as read
		if H.enabled(sh) then
			H.read_line(sh, st, line, true)
		end
		local d = hdq[1]
		if (d.strip and (line:gsub("^\t+", "")) or line) == d.word then
			table.remove(hdq, 1)
		end
		return line
	end
	local hx = H.expanding(sh) and H.chars(sh)
	if hx and (line:find(hx, 1, true) or line:sub(1, 1) == select(2, H.chars(sh))) then
		sh.cur_line = lno or sh.cur_line
		-- (inside a multi-line command, `!!` is the command before it: the entry
		-- this command is being recorded into is set aside while expanding)
		local hl, held = H.list(sh), nil
		if mid and st.first_saved then
			held = table.remove(hl)
		end
		local code, out = H.expand(sh, line)
		if held then
			hl[#hl + 1] = held
		end
		if code < 0 then
			io.stderr:write("curse: " .. out .. "\n")
			return nil
		elseif code == 2 then -- `:p`: print it and add it to the history, don't run it
			io.stderr:write(out .. "\n")
			if H.enabled(sh) and out ~= "" then
				H.read_line(sh, st, out, false)
			end
			return nil
		elseif code == 1 then
			io.stderr:write(out .. "\n")
			line = out
		end
	end
	if line ~= "" and H.enabled(sh) then
		H.read_line(sh, st, line, false)
	end
	for _, d in ipairs(heredoc_opens(line)) do
		hdq[#hdq + 1] = d
	end
	return line
end

local function run_history_lines(sh, text, line1, hook, k)
	local pos, lnum, n = 1, line1, #text
	local buf, bufline, st, hdq = {}, line1, {}, {}
	local function flush()
		if #buf == 0 then
			return
		end
		local code = table.concat(buf, "\n")
		buf = {}
		local nf = P.open(code, sh, bufline)
		while true do
			local lg = nf()
			if lg == nil then
				break
			end
			k = run_group(sh, lg, hook, k)
			if sh.opt_t and not sh.opt_c then -- (set -t: see run_lazy)
				error({ __curse_exit = sh.status })
			end
		end
	end
	while pos <= n do
		local e = text:find("\n", pos, true) or (n + 1)
		local line = text:sub(pos, e - 1)
		pos = e + 1
		if sh.opt_v then -- set -v: each input line is echoed as it's read (bash)
			io.stderr:write(line, "\n")
		end
		local this = lnum
		lnum = lnum + 1
		if #buf == 0 then
			st, bufline = {}, this
		end
		line = M.history_line(sh, st, hdq, line, #buf > 0, this)
		if line then
			buf[#buf + 1] = line
		else
			lnum = lnum - 1 -- (a discarded line isn't counted: bash's line numbers lag)
		end
		if #hdq == 0 and #buf > 0 and not needs_more(table.concat(buf, "\n")) then
			flush()
		end
	end
	flush()
	return k
end

-- (`line1`: the line `src` starts on — a script read from stdin a command at a time)
function M.run_lazy(sh, src, hook, line1)
	sh.main_src = sh.main_src or src
	hook = hook or function() end
	local nextf = P.open(src, sh, line1) -- sh: alias expansion uses the live alias table
	finish(
		sh,
		pcall(function()
			local k = 0
			if sh.opt_v and not sh.opt_i then -- (`bash -v`: read line by line from the start)
				run_history_lines(sh, src, line1 or 1, hook, k)
				return
			end
			while true do
				local lg = nextf()
				if lg == nil then
					break
				end
				k = run_group(sh, lg, hook, k)
				-- set -t (onecmd): the reader's loop ends after the command it read and ran
				-- (bash's reader_loop: just_one_command) — not a -c string's
				if sh.opt_t and not sh.opt_c then
					error({ __curse_exit = sh.status })
				end
				-- `set -o history` / `set -H` / `set -v` just took effect: the rest of the
				-- script is read line by line (recorded, `!`-expanded, echoed) from where
				-- parsing stopped
				if lg.pos and (sh.opt_history == true or sh.opt_H == true or sh.opt_v == true) and not sh.opt_i then
					local s, p, pl = lg.src, lg.pos, lg.pline
					if s:sub(p, p) == "#" then
						p = s:find("\n", p, true) or (#s + 1)
					end
					if s:sub(p, p) == "\n" then
						p, pl = p + 1, pl + 1
					end
					run_history_lines(sh, s:sub(p), pl, hook, k)
					break
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
-- An array PROMPT_COMMAND runs each non-empty element in index order, an associative one
-- nothing (eval.c execute_prompt_command); $_ is put back after each (execute_variable_command).
function M.run_prompt_command(sh, hook)
	local b = sh.vars.PROMPT_COMMAND
	if not b or b.assoc then
		return
	end
	if b.arr then
		for _, pc in ipairs(sh:array_values("PROMPT_COMMAND")) do
			if pc ~= "" then
				M.run_variable_command(sh, pc, hook)
			end
		end
		return
	end
	local pc = sh:get("PROMPT_COMMAND")
	if pc ~= "" then
		M.run_variable_command(sh, pc, hook)
	end
end
function M.run_variable_command(sh, pc, hook)
	hook = hook or function() end
	local saved, under = sh.status, sh.vars._ and sh:get("_")
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
				local ne0, pf0 = sh.noerr, sh.procsub_files and #sh.procsub_files or 0
				local sok, serr = pcall(exec_stmt, sh, st, hook)
				if not sok then
					if type(serr) == "table" and serr.__curse_exit and not serr.__curse_lineabort then
						error(serr)
					elseif type(serr) == "table" and serr.__curse_lineabort then
						rt.posix_arith_fatal(sh, serr)
						sh.noerr = ne0
						rt.line_aborted(sh, 1, pf0)
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
	if under then
		sh:set_str("_", under)
	end
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
			local ne0, pf0 = sh.noerr, sh.procsub_files and #sh.procsub_files or 0
			local sok, serr = pcall(exec_stmt, sh, st, hook)
			if not sok then
				if type(serr) == "table" and serr.__curse_lineabort then
					if rt.lineabort_exits(sh, serr) then
						error(serr)
					end
					rt.posix_arith_fatal(sh, serr)
					sh.noerr = ne0
					rt.line_aborted(sh, 1, pf0)
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
M.SUBHOOK = SUBHOOK -- ($(…) bodies run from runtime use it too)
M._int = {
	arith_pre = arith_pre,
	SPECIAL_BUILTIN = SPECIAL_BUILTIN,
	exec_simple = exec_simple,
	expand_part_str = expand_part_str,
	file_test = file_test,
	sq = sq,
	BUILTINS = BUILTINS,
	SETOPTS = SETOPTS,
	SHOPT_ORDER = SHOPT_ORDER,
	parse_umask = parse_umask,
	umask_symbolic = umask_symbolic,
	job_reap = job_reap,
	block_sig = block_sig,
	canon_sig = canon_sig,
	sig_order = sig_order,
	SIGNUM = SIGNUM,
	NUMSIG = NUMSIG,
	array_key = array_key,
	arith_key = arith_key,
	arith_resolve = arith_resolve,
	arith_nounset = arith_nounset,
	sh_printf = sh_printf,
	fd_getc = fd_getc,
	fd_ready = fd_ready,
	read_split = read_split,
	do_arrayassign = do_arrayassign,
	arrayassign_items = arrayassign_items,
	literal_sub = literal_sub,
	expand_word = expand_word,
	drain_procsub = drain_procsub,
	xtrace_quote = rt.xtrace_quote,
	unset_arrayref = unset_arrayref,
	eval = eval,
	fmt_decl = fmt_decl,
	decl_elems = decl_elems,
	fmt_set_var = fmt_set_var,
	opt_on = opt_on,
	set_opt = set_opt,
	SETFLAG = SETFLAG,
	SETOPT = SETOPT,
	func_body_text = func_body_text,
	func_export_text = func_export_text,
	exec_list = exec_list,
	run_history_lines = run_history_lines,
	exec_stmt = exec_stmt,
	apply_redirs = apply_redirs,
	arith_expand_text = arith_expand_text,
	dbracket_word = dbracket_word,
	dbracket_pattern = dbracket_pattern,
	redirs_touch_stdout = redirs_touch_stdout,
	describe = describe,
	command_describe = command_describe,
	statbuf = statbuf,
	statbuf2 = statbuf2,
	run_trap = run_trap,
	job_resolve = job_resolve,
	SIGDESC = SIGDESC,
	rl_capture = rl_capture,
	rl_lib = rl_lib,
	SHOPT_DEFAULT = SHOPT_DEFAULT,
	shopt_on = shopt_on,
	C = C,
	P = P,
	rt = rt,
}

rt.INTERP_FRAMES[exec_stmt] = true -- (error prefixes: sh.cur_line is current under it)
rt.SRC_FRAMES[run_function], rt.SRC_FRAMES[rt.source_run] = true, true -- (they set sh.cur_source)
return M
