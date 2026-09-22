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
		if not ch.wc or ch.wc < 32 or ch.wc == 127 or M.iswprint(ch.wc) == 0 then
			needc = true
			break
		end
	end
	if not needc then
		return "'" .. s:gsub("'", "'\\''") .. "'"
	end -- all printable (e.g. `'μ'`)
	local out = { "$'" }
	for _, ch in ipairs(chars) do
		if ch.wc and ch.wc >= 32 and ch.wc ~= 127 and M.iswprint(ch.wc) ~= 0 then
			if ch.s == "'" then
				out[#out + 1] = "\\'"
			elseif ch.s == "\\" then
				out[#out + 1] = "\\\\"
			else
				out[#out + 1] = ch.s
			end -- printable codepoint: keep the raw bytes
		else
			for i = 1, #ch.s do -- control char / non-printable / bad byte: escape each byte
				local b = ch.s:byte(i)
				if b == 10 then
					out[#out + 1] = "\\n"
				elseif b == 9 then
					out[#out + 1] = "\\t"
				elseif b == 13 then
					out[#out + 1] = "\\r"
				elseif b == 92 then
					out[#out + 1] = "\\\\"
				elseif b == 39 then
					out[#out + 1] = "\\'"
				elseif b >= 32 and b < 127 then
					out[#out + 1] = string.char(b)
				else
					out[#out + 1] = ("\\%03o"):format(b)
				end
			end
		end
	end
	out[#out + 1] = "'"
	return table.concat(out)
end

local Shell = {}
Shell.__index = Shell
M.Shell = Shell

local seeded = false
function Shell.new()
	if not seeded then
		math.randomseed(os.time() + tonumber(ffi.C.getpid and ffi.C.getpid() or 0))
		seeded = true
	end
	local sh = setmetatable({
		vars = {}, -- name -> { s = string?, n = int64? }  (lazy: fill on demand)
		status = 0, -- $?
		argv0 = "bash", -- $0 (set by the CLI/daemon to the script/shell name)
		shellname = "bash", -- the shell we're mimicking, from our invocation basename
		-- (\s prompt escape, posix-when-sh). Set by the CLI.
		start_time = os.time(), -- for $SECONDS
		opt_e = false, -- set -e (errexit)
		opt_u = false, -- set -u (nounset)
		opt_C = false, -- set -C (noclobber)
		opt_pipefail = false,
		aliases = {}, -- name -> replacement text (alias builtin)
		shopt = {}, -- shopt option name -> bool (expand_aliases, nullglob, …)
		traps = {}, -- canonical signal name (EXIT, SIGINT, …) -> handler string
		noerr = 0, -- >0 = errexit suppressed (inside a condition / negation)
		params = {}, -- positional $1..
		out = io.write, -- stdout sink (swappable for capture)
		forstate = {}, -- loop id -> { list = {strings}, idx } for `for x in`; kept
		-- in `sh` so a mid-loop OSR resumes the SAME expansion+index
		functions = {}, -- name -> AST body (interpreter); the compiled module has
		-- its own closures
		-- Function-call plumbing with NO per-call allocation: positional args go into
		-- a per-depth POOL array (reused across calls at that depth), the count is
		-- tracked explicitly (nparams), and the save-stacks reuse their slots.
		params = {}, -- current $@ array (may be an oversized pool array)
		nparams = 0, -- current $# (params[1..nparams] are live)
		pd = 0, -- call/param depth
		paramstack = {}, -- saved `params` per depth
		npstack = {}, -- saved `nparams` per depth
		argpool = {}, -- reusable args array per depth
		savedstack = {}, -- `local`-shadow record per depth (false until a local shadows)
		tenv = {}, -- tempenv shadow stack: {name, box, env, consumed, seq} per
		-- `x=v cmd` binding; `unset` peels the highest-seq shadow layer
		-- (tenv entry OR a `local` shadow), matching bash dynamic scope.
		vseq = 0, -- monotonic counter ordering local/tempenv shadow layers
		calldepth = 0, -- interpreter-only OSR gate (managed at the interp call site)
	}, Shell)
	sh:import_env()
	M.reset_locale(sh) -- adopt $LANG/$LC_* (bash calls setlocale at startup)
	if sh.vars["OPTIND"] == nil then
		sh:set_str("OPTIND", "1")
	end -- bash: OPTIND starts at 1
	if sh.vars["HOSTNAME"] == nil then
		sh:set_str("HOSTNAME", M.hostname())
	end
	-- curse identifies as bash (see shellname/basename); advertise a version so
	-- feature-detection (`test -n "$BASH_VERSION"`, `[[ $BASH_VERSION == 5* ]]`)
	-- works. A normal var: scripts can reassign or `unset` it (bash).
	if sh.vars["BASH_VERSION"] == nil then
		sh:set_str("BASH_VERSION", "5.2.0(1)-release")
	end
	return sh
end

-- positional parameters ($# is read directly as sh.nparams). $0 is the script/
-- shell name (not a positional; not affected by set/shift).
function Shell:param(n)
	if n == 0 then
		return self.argv0 or "bash"
	end
	return (n <= self.nparams) and self.params[n] or ""
end
function Shell:paramsJoin(sep)
	return table.concat(self.params, sep or " ", 1, self.nparams)
end
-- "$*" in a string context: params joined by IFS[0] (space if IFS unset, nothing
-- if IFS is set but empty) — bash. "$@" always joins by a literal space.
function Shell:paramsStar()
	return self:paramsJoin(self.vars["IFS"] and self:get("IFS"):sub(1, 1) or " ")
end
-- The positional params as a fresh 1-based list (for the field engine's $@/$* segments).
function Shell:paramList()
	local t = {}
	for i = 1, self.nparams do
		t[i] = self.params[i]
	end
	return t
end
-- ${@:off:len}/${*:off:len} slices over [$0, $1, …] (the offset is indexed so ${@:0}
-- includes $0), unlike every other $@ expansion which is $1.. only — matches interp.
function Shell:paramListSub()
	local t = { self.argv0 or "" }
	for i = 1, self.nparams do
		t[i + 1] = self.params[i]
	end
	return t
end
-- Backslash-escape glob metacharacters in a string so it matches literally in a glob
-- pattern (the compiled tier's twin of interp's expand_escaped for a QUOTED pattern part:
-- `case $x in "$p"*)` — "$p"'s metachars are literal, the trailing * is active).
function M.glob_quote(s)
	return (s:gsub("[%*%?%[%]\\%(%)%|%+%@%!]", "\\%0"))
end
-- ERE-escape a QUOTED part of a `[[ =~ ]]` regex (the compiled twin of interp's expand_regex
-- for a quoted segment): a quoted `"$re"`/`"a.c"` matches literally, so every ERE metachar is
-- backslash-escaped. Mirrors interp's expand_escaped metachar set for the =~ context.
function M.regex_quote(s)
	return (s:gsub("[%.%^%$%*%+%?%(%)%[%]%{%}%|\\]", "\\%0"))
end

-- Positional-only call boundary: push args (varargs) into the depth pool — no
-- table allocation per call after warmup.
function Shell:pushParams(...)
	local d = self.pd + 1
	self.pd = d
	self.paramstack[d] = self.params
	self.npstack[d] = self.nparams
	local a = self.argpool[d]
	if not a then
		a = {}
		self.argpool[d] = a
	end
	local n = select("#", ...)
	for i = 1, n do
		a[i] = (select(i, ...))
	end
	self.params = a
	self.nparams = n
end
function Shell:popParams()
	local d = self.pd
	self.pd = d - 1
	self.params = self.paramstack[d]
	self.nparams = self.npstack[d]
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
	local fs = self.funcstack
	if not fs then
		fs = {}
		self.funcstack = fs
	end
	table.insert(fs, 1, name)
	local ls = self.linestack
	if not ls then
		ls = {}
		self.linestack = ls
	end
	table.insert(ls, 1, line or 0)
	local ss = self.srcstack
	if not ss then
		ss = {}
		self.srcstack = ss
	end
	table.insert(ss, 1, self.cur_source or self.argv0 or "")
end
function Shell:leaveFunc()
	if self.funcstack then
		table.remove(self.funcstack, 1)
	end
	if self.linestack then
		table.remove(self.linestack, 1)
	end
	if self.srcstack then
		table.remove(self.srcstack, 1)
	end
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
				if old and old.exported then
					ffi.C.setenv(name, self:get(name) or "", 1)
				else
					ffi.C.unsetenv(name)
				end
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
	if not saved then
		saved = {}
		self.savedstack[d] = saved
	end
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
			if not e.consumed and e.name == name then
				te = e
				break
			end
		end
		self.vseq = self.vseq + 1
		if te and te.frame == self.pd then
			saved[name] = { box = te.box, seq = self.vseq }
			te.consumed = true
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
-- the shadowed outer one). Returns false (else true) when the name is READONLY: bash
-- fails that operand (message + `local` returns 1) WITHOUT shadowing it or changing
-- the value, and continues with the rest — so the caller ORs the results into $?.
function Shell:localAssign(arg)
	local nm, op, val = arg:match("^([%a_][%w_]*)(%+?=)(.*)$")
	local name = nm or arg
	-- readonly NAME: no shadow, no assignment (the readonly global stays visible in the
	-- frame). Message routes through any 2>&1 capture, exactly like interp.
	local eb = self.vars[name]
	if eb and eb.ro then
		self:errmsg("curse: local: " .. name .. ": readonly variable\n")
		return false
	end
	if nm then
		self:localVar(nm, true)
		self:set_str(nm, op == "+=" and (self:get(nm) .. val) or val)
	else
		self:localVar(arg)
	end
	-- set -a (allexport): the local scalar is exported for the frame's lifetime; popCall
	-- reverts the env entry on return (an unset outer var is unset again).
	if self.opt_a then
		local b = self.vars[name]
		if b and not b.arr then
			b.exported = true
			ffi.C.setenv(name, self:get(name) or "", 1)
		end
	end
	return true
end

-- Split on default-IFS whitespace (no empty fields), for unquoted `$var` in a
-- `for x in $list` word list. (Custom IFS comes with the fuller word engine.)
function Shell:split(s)
	local out = {}
	for w in s:gmatch("%S+") do
		out[#out + 1] = w
	end
	return out
end

-- Bash-correct standalone IFS split (for `read`): whitespace-IFS runs collapse and
-- trim edges; each non-whitespace-IFS char delimits (empty fields allowed), with a
-- trailing delimiter not adding a trailing empty.
function M.ifs_split(ifs, s)
	local fields, cur = {}, nil
	local function isws(c)
		return c == " " or c == "\t" or c == "\n"
	end
	local function inifs(c)
		return c ~= "" and ifs:find(c, 1, true) ~= nil
	end
	local function brk()
		if cur ~= nil then
			fields[#fields + 1] = cur
			cur = nil
		end
	end
	local i, n = 1, #s
	while i <= n do
		local c = s:sub(i, i)
		if c == "\1" and i < n then -- CTLESC: next char is literal (read backslash-escape)
			cur = (cur or "") .. s:sub(i + 1, i + 1)
			i = i + 2
		elseif inifs(c) then
			if isws(c) then
				if cur ~= nil then
					brk()
				end
				i = i + 1
				while i <= n and isws(s:sub(i, i)) do
					i = i + 1
				end
				if i <= n and inifs(s:sub(i, i)) and not isws(s:sub(i, i)) then
					i = i + 1
					while i <= n and isws(s:sub(i, i)) do
						i = i + 1
					end
				end
			else
				if cur == nil then
					cur = ""
				end
				brk()
				i = i + 1
				while i <= n and isws(s:sub(i, i)) do
					i = i + 1
				end
			end
		else
			cur = (cur or "") .. c
			i = i + 1
		end
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
ffi.cdef([[
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
]])
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
M.lc_mb_cur_max = function()
	return lc_mb_cur_max
end
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
		if all and all ~= "" then
			cands = { all, "C" }
		else
			local b = sh.vars[name]
			local lv = b and sh:get(name)
			cands = {}
			if lv and lv ~= "" then
				cands[#cands + 1] = lv
			end
			if lang and lang ~= "" then
				cands[#cands + 1] = lang
			end
			cands[#cands + 1] = "C"
		end
		for _, v in ipairs(cands) do
			if C.setlocale(cat, v) ~= nil then
				break
			end
		end
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
	if lc_mb_cur_max <= 1 then
		return #s
	end
	ffi.fill(_mb_st, ffi.sizeof(_mb_st))
	local ptr, i, n, count = ffi.cast("const char *", s), 0, #s, 0
	while i < n do
		local r = tonumber(C.mbrtowc(_mb_wc, ptr + i, n - i, _mb_st))
		if r == 0 or r > (n - i) then
			r = 1
		end -- NUL / invalid / incomplete: one char, one byte
		i = i + r
		count = count + 1
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
		for k = 1, n do
			out[k] = { s = s:sub(k, k), wc = s:byte(k) }
		end
		return out
	end
	ffi.fill(_mb_st, ffi.sizeof(_mb_st))
	local ptr, i = ffi.cast("const char *", s), 0
	while i < n do
		local r = tonumber(C.mbrtowc(_mb_wc, ptr + i, n - i, _mb_st))
		local wc = _mb_wc[0]
		if r == 0 or r > (n - i) then
			r = 1
			wc = nil
		end -- bad byte: no codepoint
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
	if not b or b < 0x80 or lc_mb_cur_max <= 1 then
		return 1
	end
	ffi.fill(_mb_st, ffi.sizeof(_mb_st))
	local r = tonumber(C.mbrtowc(_mb_wc, ffi.cast("const char *", s) + (i - 1), #s - i + 1, _mb_st))
	if r <= 0 or r > (#s - i + 1) then
		return 1
	end
	return r
end

-- Re-encode a codepoint to bytes in the current locale (wcrtomb); on failure keep
-- the original bytes. Used to write back a case-folded character.
local _mb_buf = ffi.new("char[16]")
function M.wc_to_bytes(wc, orig)
	if lc_mb_cur_max <= 1 then
		return string.char(wc % 256)
	end
	ffi.fill(_mb_st, ffi.sizeof(_mb_st))
	local r = tonumber(C.wcrtomb(_mb_buf, wc, _mb_st))
	if r <= 0 or r > 16 then
		return orig
	end
	return ffi.string(_mb_buf, r)
end
M.towupper = function(wc)
	return tonumber(C.towupper(wc))
end
M.towlower = function(wc)
	return tonumber(C.towlower(wc))
end
M.iswprint = function(wc)
	return tonumber(C.iswprint(wc))
end
-- Collation order per LC_COLLATE (glob-result sort, [[ < ]] compare), with a
-- byte-order tiebreak so equal-weight strings keep a stable total order like bash.
-- Under LC_COLLATE=C this is plain byte order (strcoll == strcmp), so it is a
-- no-op there; only a real collating locale reorders.
function M.coll_lt(a, b)
	local c = tonumber(C.strcoll(a, b))
	if c ~= 0 then
		return c < 0
	end
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
function M.subshell_wait(pid)
	C.waitpid(pid, _ss_st, 0)
	return M.wexit(_ss_st[0])
end
function M.subshell_exit(status)
	io.flush()
	C._exit(status or 0)
end

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
	local w = io.open(tmp, "w")
	if not w then
		return -1
	end
	w:write(content)
	w:close()
	local f = C.open(tmp, 0, 0) -- O_RDONLY
	os.remove(tmp) -- the open fd keeps the inode alive
	return f
end
function M.redir_apply(sh, op, fd, target, saves)
	io.flush() -- flush buffered stdout before moving fds (else it lands in the new target)
	local function backup(f)
		saves[#saves + 1] = { fd = f, saved = C.dup(f) }
	end
	local function open_out(path) -- honor noclobber (set -C) for a truncating '>'
		if not sh.opt_C then
			return C.open(path, 577, 438)
		end -- O_WRONLY|O_CREAT|O_TRUNC
		local h = C.open(path, 705, 438) -- + O_EXCL
		if h >= 0 then
			return h
		end
		if
			C.curse_rt_stat(path, _redir_stat) == 0
			and bit.band(ffi.cast("uint32_t *", _redir_stat + 24)[0], 0xF000) ~= 0x8000
		then
			return C.open(path, 1, 438) -- existing NON-regular (e.g. /dev/null): plain O_WRONLY
		end
		return -1
	end
	if op == "out" or op == "clobber" then
		backup(fd)
		local h = (op == "out") and open_out(target) or C.open(target, 577, 438)
		if h < 0 then
			return false
		end
		if h ~= fd then
			C.dup2(h, fd)
			C.close(h)
		end
	elseif op == "app" then
		backup(fd)
		local h = C.open(target, 1089, 438) -- O_WRONLY|O_CREAT|O_APPEND
		if h < 0 then
			return false
		end
		if h ~= fd then
			C.dup2(h, fd)
			C.close(h)
		end
	elseif op == "in" then
		backup(fd)
		local h = C.open(target, 0, 0) -- O_RDONLY
		if h < 0 then
			return false
		end
		if h ~= fd then
			C.dup2(h, fd)
			C.close(h)
		end
	elseif op == "rw" then
		backup(fd)
		local h = C.open(target, 66, 438) -- O_RDWR|O_CREAT
		if h < 0 then
			return false
		end
		if h ~= fd then
			C.dup2(h, fd)
			C.close(h)
		end
	elseif op == "dup" or op == "dupin" then -- N>&M / N<&M / N>&-
		if target == "-" then
			backup(fd)
			C.close(fd)
		else
			local tf = tonumber(target)
			if not tf then
				return false
			end
			if C.fcntl(tf, 1) == -1 then
				return false
			end -- F_GETFD: target fd not open -> bash fails
			backup(fd)
			C.dup2(tf, fd)
		end
	elseif op == "outboth" or op == "appboth" then -- &> / &>>
		backup(1)
		backup(2)
		local h = (op == "appboth") and C.open(target, 1089, 438) or open_out(target)
		if h < 0 then
			return false
		end
		C.dup2(h, 1)
		C.dup2(h, 2)
		C.close(h)
	elseif op == "heredoc" or op == "herestring" then
		backup(fd)
		local h = _temp_fd(target) -- target = the already-built body text
		if h < 0 then
			return false
		end
		if h ~= fd then
			C.dup2(h, fd)
			C.close(h)
		end
	else
		return nil
	end -- op the compiler shouldn't have handed us
	return true
end
function M.redir_restore(saves)
	io.flush()
	-- s.saved >= 0: the fd was open — restore it. s.saved < 0 (C.dup failed): the fd was NOT
	-- open before, so CLOSE it rather than dup2(-1) which leaks it (matches interp restore_redirs).
	for i = #saves, 1, -1 do
		local s = saves[i]
		if s.saved >= 0 then
			C.dup2(s.saved, s.fd)
			C.close(s.saved)
		else
			C.close(s.fd)
		end
	end
end

-- A FILE redirect whose target is EXPANDABLE (`> $f`, `< $dir/in`, `> *.glob`): the compiled
-- tier hands the mask-aware segments; expand them, require EXACTLY one field (else "ambiguous
-- redirect", status 1), then apply — matching interp's ftgt. A raise during expansion (failglob,
-- set -u) fails the redirect non-fatally, as interp's pcall does.
function M.redir_apply_expand(sh, op, fd, segs, raw, saves)
	local ok, fs = pcall(M.expand_fields, sh, segs)
	if not ok then
		return false
	end
	if #fs ~= 1 then
		io.stderr:write("curse: " .. raw .. ": ambiguous redirect\n")
		return false
	end
	return M.redir_apply(sh, op, fd, fs[1], saves)
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
	if sig ~= 0 and sig ~= 0x7f then
		return 128 + sig
	end
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
		local set = ffi.new("uint8_t[1024]")
		C.sigemptyset(set)
		C.sigprocmask(2, set, nil) -- SIG_SETMASK
	end
	local f = io.open(path, "r")
	local src = f and f:read("*a") or ""
	if f then
		f:close()
	end
	-- A no-shebang script is exec'd as a FRESH process: it sees only the exported
	-- environment, NOT the parent's in-memory shell vars/functions/traps. Build a
	-- new shell (import_env populates it from the environment) rather than reusing
	-- self, so a non-exported `x=1; ./script` doesn't leak x into the script.
	local child = Shell.new()
	child.argv0, child.out = args[1], io.write
	for k = 2, n do
		child.nparams = child.nparams + 1
		child.params[child.nparams] = args[k]
	end
	pcall(require("interp").run_lazy, child, src)
	io.flush()
	C._exit(child.status or 0)
end

-- ENOEXEC fallback for the streaming (non-capturing) path: fd 1 is already the
-- destination, so just fork a child that runs the script and inherits fd 1.
function Shell:run_noexec(path, args, n)
	local pid = C.fork()
	if pid == 0 then
		self:exec_script_child(path, args, n)
	end
	local st = ffi.new("int[1]")
	C.waitpid(pid, st, 0)
	self.status = M.wexit(st[0])
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
	if not (self.sigtraps and next(self.sigtraps)) then
		return nil
	end
	local attr = ffi.new("uint8_t[1024]") -- opaque posix_spawnattr_t; over-allocate
	if C.posix_spawnattr_init(attr) ~= 0 then
		return nil
	end
	local set = ffi.new("uint8_t[1024]") -- copied into attr by setsigmask; needn't outlive it
	C.sigemptyset(set)
	C.posix_spawnattr_setsigmask(attr, set)
	C.posix_spawnattr_setflags(attr, SPAWN_SETSIGMASK)
	return attr
end

function Shell:exec(...)
	local args = { ... }
	local n = #args
	if n == 0 or args[1] == "" then
		self.status = 127
		return
	end
	-- Resolve a bare name to its (cached) $PATH location, but keep argv[0] = the
	-- name as typed. A command with a `/` is exec'd directly.
	local execpath = args[1]
	if not args[1]:find("/", 1, true) then
		execpath = self:resolve_cmd(args[1])
		if not execpath then
			self:errmsg("curse: " .. args[1] .. ": command not found\n")
			self.status = 127
			return
		end
	end
	local argv = ffi.new("const char*[?]", n + 1)
	local anchor = {} -- keep the Lua strings alive while argv points into them
	for i = 1, n do
		anchor[i] = tostring(args[i])
		argv[i - 1] = anchor[i]
	end
	argv[n] = nil
	if self.exec_argv0 then
		anchor.a0 = tostring(self.exec_argv0)
		argv[0] = anchor.a0
	end -- exec -a NAME
	-- Not capturing (self.out is the real fd 1, e.g. a top-level command or a
	-- pipeline stage): let the child write STRAIGHT to fd 1 (inherit fds) instead
	-- of buffering all its output — so an unbounded producer (`cat /dev/zero | …`)
	-- streams and SIGPIPE propagates, and there's no 2x-memory capture.
	if self.out == io.write then
		io.flush() -- our own buffered stdout must reach fd 1 before the child writes
		local pidp = ffi.new("curse_pid_t[1]")
		local attr = child_spawnattr(self)
		local rc = C.posix_spawnp(pidp, execpath, nil, attr, ffi.cast("char *const *", argv), C.environ)
		if attr then
			C.posix_spawnattr_destroy(attr)
		end
		if rc == 8 then
			return self:run_noexec(execpath, args, n)
		end -- no shebang: run as a script
		if rc ~= 0 then
			self:errmsg(
				"curse: " .. tostring(args[1]) .. (rc == 2 and ": command not found\n" or ": Permission denied\n")
			)
			self.status = (rc == 2) and 127 or 126
			return
		end
		local st = ffi.new("int[1]")
		C.waitpid(pidp[0], st, 0)
		self.status = M.wexit(st[0])
		return
	end
	local fds = ffi.new("int[2]")
	if C.pipe(fds) ~= 0 then
		self.status = 127
		return
	end
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
	if attr then
		C.posix_spawnattr_destroy(attr)
	end
	C.posix_spawn_file_actions_destroy(fa)
	local pid = pidp[0]
	if rc == 8 then -- ENOEXEC: no-shebang script — run it through our interpreter in a
		pid = C.fork() -- child, with its stdout dup'd onto the capture pipe's write end.
		if pid == 0 then
			C.dup2(wfd, 1)
			C.close(wfd)
			C.close(rfd)
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
		if nr <= 0 then
			break
		end
		chunks[#chunks + 1] = ffi.string(buf, nr)
	end
	C.close(rfd)
	local st = ffi.new("int[1]")
	C.waitpid(pid, st, 0)
	self.status = M.wexit(st[0])
	local out = table.concat(chunks)
	if out ~= "" then
		self.out(out)
	end
end

-- Command substitution `$(...)`: run the inner program capturing stdout, with
-- trailing newlines stripped (bash). Interpreted (it's I/O-bound, not hot), so
-- it handles builtins, externals, and (in interp mode) functions uniformly.
-- `$(…)` runs in a forked child (CoW — the child already holds all state), so it
-- gets FULL subshell isolation for free (vars, set-flags, fds, cwd, umask, traps,
-- functions, $BASHPID) exactly like bash — which manual in-process save/restore
-- can't reliably do. Output is captured through a pipe, like the subshell path.
-- `runner(self)` executes the body (default: interpret `ast.stmts`); the compiled
-- tier passes a runner that runs a compiled cmdsub fragment instead.
function Shell:capture_forked(ast, runner)
	runner = runner or function(self)
		return require("interp").exec_list(self, ast.stmts, function() end, true)
	end
	io.flush()
	local pfd = ffi.new("int[2]")
	if C.pipe(pfd) ~= 0 then
		return nil
	end -- caller falls back to in-process
	local pid = C.fork()
	if pid == 0 then
		C.close(pfd[0])
		C.dup2(pfd[1], 1)
		C.close(pfd[1])
		self.out = io.write
		self.in_subprogram = (self.in_subprogram or 0) + 1
		local ok, err = pcall(runner, self)
		if not ok and type(err) == "table" and (err.__curse_exit or err.__curse_return) then
			self.status = err.__curse_exit or err.__curse_return
		end
		io.flush()
		C._exit(self.status or 0)
	end
	C.close(pfd[1])
	local chunks, rbuf = {}, ffi.new("char[8192]")
	while true do
		local nr = tonumber(C.read(pfd[0], rbuf, 8192))
		if not nr or nr <= 0 then
			break
		end
		chunks[#chunks + 1] = ffi.string(rbuf, nr)
	end
	C.close(pfd[0])
	local stbuf = ffi.new("int[1]")
	C.waitpid(pid, stbuf, 0)
	self.status = M.wexit(stbuf[0])
	self.last_cmdsub_status = self.status -- like capture_inproc: for an empty-argv command's status
	return (table.concat(chunks):gsub("%z", ""):gsub("\n+$", ""))
end
-- A `$(…)` body is "pure" (no shell-state side effects, so safe to run in-process
-- for speed) when every command is a plain external/non-mutating-builtin call with
-- no assignments, no mutating builtin, no user-function call, and no control flow.
-- Anything else forks for full isolation. (A file redirect like `>f` is fine — the
-- write happens either way; only `exec` rewires shell fds, and it's listed here.)
local CAPTURE_IMPURE = {
	cd = 1,
	set = 1,
	shopt = 1,
	unset = 1,
	export = 1,
	declare = 1,
	typeset = 1,
	["local"] = 1,
	readonly = 1,
	trap = 1,
	umask = 1,
	exec = 1,
	eval = 1,
	source = 1,
	["."] = 1,
	pushd = 1,
	popd = 1,
	hash = 1,
	shift = 1,
	read = 1,
	mapfile = 1,
	readarray = 1,
	let = 1,
	getopts = 1,
	ulimit = 1,
	disown = 1,
	["return"] = 1,
	["set-o"] = 1,
}
local function capture_pure(sh, st)
	local t = st.t
	if t == "andor" then
		for _, it in ipairs(st.items) do
			if not capture_pure(sh, it.cmd) then
				return false
			end
		end
		return true
	elseif t == "pipeline" then
		for _, c in ipairs(st.cmds) do
			if not capture_pure(sh, c) then
				return false
			end
		end
		return true
	elseif t == "simple" then
		if st.assigns or st.arrayargs then
			return false
		end -- prefix/array assignment mutates
		local w = st.words and st.words[1]
		local lit = w and w.parts and #w.parts == 1 and w.parts[1].lit
		if not lit then
			return false
		end -- dynamic/compound command name: be safe, fork
		if CAPTURE_IMPURE[lit] or sh.functions[lit] then
			return false
		end
		return true
	end
	return false -- if/while/for/case/subshell/group/funcdef/background/arithcmd: fork
end

function Shell:capture_src(src, backtick)
	local P = require("parser")
	local I = require("interp")
	-- A SYNTAX error in the body: bash makes `$(…)` fatal to the whole containing
	-- command, but a backtick `…` only PRINTS the error and yields "" (non-fatal —
	-- `echo A``echo "``B` prints "AB" and exits 0). Backticks are parsed lazily at
	-- expansion time, so a throw here (e.g. an unterminated quote) is contained.
	local pok, parsed = pcall(P.parse, src, self) -- self: $()/`` expand aliases from the live table
	if not pok then
		if backtick then
			io.stderr:write("curse: command substitution: " .. tostring(parsed) .. "\n")
			self.status = 1
			return ""
		end
		error(parsed)
	end
	local ast = parsed
	-- $(< file) / `< file`: bash reads the file's contents (a faster $(cat file)) —
	-- a pure read, no isolation needed, so keep it in-process.
	if #ast.stmts == 1 then
		local st = ast.stmts[1]
		if
			st.t == "simple"
			and (not st.words or #st.words == 0)
			and st.redirs
			and #st.redirs == 1
			and st.redirs[1].op == "in"
		then
			local path = I.expand_assign_word(self, P.parse_word(st.redirs[1].target or ""))
			local f = path ~= "" and io.open(path, "r")
			if f then
				local c = f:read("*a") or ""
				f:close()
				self.status = 0
				return (c:gsub("%z", ""):gsub("\n+$", ""))
			end
			io.stderr:write("curse: " .. path .. ": No such file or directory\n")
			self.status = 1
			return ""
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
		if st.t == "parse_error" then
			has_perr = true
		end
		if not capture_pure(self, st) then
			forkit = true
		end
	end
	-- A SYNTAX error in the body is fatal to the CONTAINING command (bash), which the
	-- in-process path propagates via __curse_parseerr — so never fork a parse-error
	-- body (a forked child would only surface it as an exit status, which `echo $(…)`
	-- would then ignore). Otherwise fork impure bodies for full isolation.
	if forkit and not has_perr then
		local out = self:capture_forked(ast)
		if out ~= nil then
			return out
		end
	end
	-- Run via exec_list (NOT interp.run): an `exit`/`return` inside $() ends only
	-- the sub (sets its status), and the parent's EXIT trap must NOT fire here.
	return self:capture_inproc(backtick, function(self)
		return require("interp").exec_list(self, ast.stmts, function() end, true)
	end)
end

-- Run a cmdsub body IN-PROCESS with full $(...) isolation: output buffered into a
-- string, ERR trap suppressed (in_subprogram), errexit not inherited, and
-- LINENO/aliases/loopdepth saved & restored. `runner(self)` executes the body —
-- the interp path passes exec_list, the compiled path a compiled fragment. Errors
-- follow bash: a syntax error is fatal to the containing command (contained for
-- backticks), and exit/return set the sub's status.
function Shell:capture_inproc(backtick, runner)
	local buf = {}
	local saved = self.out
	self.out = function(x)
		buf[#buf + 1] = x
	end
	local saved_cap = self.capturing
	self.capturing = true -- last pipeline stage drains into buf
	self.in_subprogram = (self.in_subprogram or 0) + 1 -- $(...) is a subprogram: ERR trap suppressed
	local saved_ld = self.loopdepth
	self.loopdepth = 0 -- break/continue don't cross into $(...)
	local savede = self.opt_e
	if not (self.shopt and self.shopt.inherit_errexit) then
		self.opt_e = false
	end
	local saved_line = self.cur_line -- $LINENO: the sub's internal lines don't leak out
	-- $() is a child: it INHERITS the parent's aliases but its own alias/unalias
	-- do not leak back out (bash). Give it an independent copy, restored after.
	local saved_aliases = self.aliases
	do
		local c = {}
		for k, v in pairs(saved_aliases) do
			c[k] = v
		end
		self.aliases = c
	end
	local ok, err = pcall(runner, self)
	self.aliases = saved_aliases -- discard aliases defined inside $()
	self.cur_line = saved_line
	self.opt_e = savede
	self.loopdepth = saved_ld
	self.in_subprogram = self.in_subprogram - 1
	self.capturing = saved_cap
	self.out = saved
	if not ok then
		if type(err) == "table" and err.__curse_parseerr then
			if backtick then
				self.status = 1
				return ""
			end -- backtick: contained (non-fatal)
			error(err) -- a SYNTAX error inside $(…) is fatal to the whole containing command (bash)
		elseif type(err) == "table" and (err.__curse_exit or err.__curse_return) then
			self.status = err.__curse_exit or err.__curse_return
		else
			error(err)
		end
	end
	self.last_cmdsub_status = self.status -- for a command whose argv is empty after expansion
	-- bash strips NUL bytes from command-substitution output ("ignored null byte")
	return (table.concat(buf):gsub("%z", ""):gsub("\n+$", ""))
end

-- Compiled-tier command substitution: run a compiled cmdsub fragment `cs_fn(sh)`
-- (the inner program, compiled at emit time). `mustfork` — computed statically by
-- emit: the body mutates shell state, calls a user function, or reads $BASHPID —
-- forks for full subshell isolation; otherwise the (provably pure) body runs
-- in-process for speed. This is the "known at compile time -> compile it" path;
-- emit falls back to capture_src for bodies it can't compile (the tiered path).
-- $(< file) / `< file`: bash reads the file's contents (a faster $(cat file)) — a pure
-- read, no fork. NUL bytes stripped, trailing newlines stripped, status 0; a missing
-- file is status 1 + diagnostic. The compiled tier calls this with the expanded path.
function Shell:capture_file(path)
	local f = path ~= "" and io.open(path, "r")
	if f then
		local c = f:read("*a") or ""
		f:close()
		self.status = 0
		return (c:gsub("%z", ""):gsub("\n+$", ""))
	end
	io.stderr:write("curse: " .. path .. ": No such file or directory\n")
	self.status = 1
	return ""
end

function Shell:capture_compiled(cs_fn, mustfork, backtick)
	if mustfork then
		-- The forked child must inherit the $() isolation: errexit is NOT inherited into a
		-- command sub (unless inherit_errexit), and ERR is suppressed (in_subprogram). Set
		-- these before the fork (the child copies them); restore in the parent after.
		local savede = self.opt_e
		if not (self.shopt and self.shopt.inherit_errexit) then
			self.opt_e = false
		end
		self.in_subprogram = (self.in_subprogram or 0) + 1
		local out = self:capture_forked(nil, cs_fn)
		self.in_subprogram = self.in_subprogram - 1
		self.opt_e = savede
		if out ~= nil then
			return out
		end -- fork failed: fall through to in-process
	end
	return self:capture_inproc(backtick, cs_fn)
end

-- In a forked child (subshell/background/pipeline stage), translate an exit/return
-- thrown as a control table into $? so the child _exits with the right status.
function M.child_status(sh, ok, err)
	if not ok and type(err) == "table" then
		sh.status = err.__curse_exit or err.__curse_return or sh.status
	end
end

-- Register a background job (for `jobs`/`wait %spec`/`wait -n`) and set $!.
function M.job_add(sh, pid, cmdstr)
	sh.jobs = sh.jobs or {}
	local maxid = 0
	for _, j in ipairs(sh.jobs) do
		if not j.done and j.id > maxid then
			maxid = j.id
		end
	end
	local job = { id = maxid + 1, pid = pid, cmd = cmdstr or "", done = false }
	sh.jobs[#sh.jobs + 1] = job
	sh.last_bg_pid = tostring(pid)
	return job
end

-- `cmd &`: fork; the child runs the COMPILED command fragment cmd_fn(sh) with stdin
-- redirected to /dev/null (async, can't steal the terminal) as a subprogram (ERR
-- suppressed); the parent records $! + the job and returns status 0. Compiled tier
-- only, gated by emit to trap-free programs (so the child needs no signal reset).
function Shell:run_background(cmd_fn, cmdstr)
	io.flush()
	local pid = C.fork()
	if pid == 0 then
		local dn = C.open("/dev/null", 0, 0)
		if dn >= 0 then
			C.dup2(dn, 0)
			C.close(dn)
		end
		self.in_subprogram = (self.in_subprogram or 0) + 1
		self.loopdepth = 0
		local ok, err = pcall(function()
			self.out = io.write
			cmd_fn(self)
		end)
		M.child_status(self, ok, err)
		io.flush()
		C._exit(self.status or 0)
	end
	M.job_add(self, pid, cmdstr)
	self.bg_pids = self.bg_pids or {}
	self.bg_pids[#self.bg_pids + 1] = pid
	self.status = 0
end

-- `a | b | c`: fork a child per stage wired by pipes, running each COMPILED stage
-- fragment; the last stage's exit is the pipeline's (or the rightmost non-zero under
-- pipefail). The last stage's stdout goes to fd 1, or the capture buffer inside $(…),
-- or runs in the current shell under `shopt -s lastpipe`. Sets $PIPESTATUS and applies
-- `!` negation. Compiled tier only (gated by emit to no trap/DEBUG/ERR — so no signal
-- reset or per-stage trap firing is needed here). `stage_fns` are cs_N fragments.
function Shell:run_pipeline(stage_fns, negate)
	local nst = #stage_fns
	if nst == 1 then -- defensive: a single stage (emit delegates `! cmd` for exact errexit)
		stage_fns[1](self)
	else
		io.flush() -- flush parent stdio so forked stages don't duplicate buffered output
		local lastpipe = self.shopt.lastpipe and not self.opt_i and nst >= 2
		local pids, prev_read, inline_status = {}, -1, nil
		for k = 1, nst do
			local rd, wr = -1, -1
			if k < nst then
				local p = ffi.new("int[2]")
				C.pipe(p)
				rd, wr = p[0], p[1]
			end
			if k == nst and lastpipe then -- last stage runs in the current shell (side effects persist)
				local save0 = C.dup(0)
				if prev_read >= 0 then
					C.dup2(prev_read, 0)
					C.close(prev_read)
					prev_read = -1
				end
				local savedout = self.out
				self.out = io.write
				local ok, err = pcall(stage_fns[k], self)
				io.flush()
				self.out = savedout
				C.dup2(save0, 0)
				C.close(save0)
				if not ok and type(err) == "table" then
					self.status = err.__curse_exit or err.__curse_return or self.status
				elseif not ok then
					error(err)
				end
				inline_status = self.status or 0
				pids[k] = -1
			elseif k == nst and self.capturing then -- inside $(…): drain last stage into the capture buffer
				local cp = ffi.new("int[2]")
				C.pipe(cp)
				local pid = C.fork()
				if pid == 0 then
					self.in_pipestage = (self.in_pipestage or 0) + 1
					local ok, err = pcall(function()
						if prev_read >= 0 then
							C.dup2(prev_read, 0)
							C.close(prev_read)
						end
						C.dup2(cp[1], 1)
						C.close(cp[1])
						C.close(cp[0])
						self.out = io.write
						stage_fns[k](self)
					end)
					M.child_status(self, ok, err)
					io.flush()
					C._exit(self.status or 0)
				end
				pids[k] = pid
				if prev_read >= 0 then
					C.close(prev_read)
					prev_read = -1
				end
				C.close(cp[1])
				local chunks, rbuf = {}, ffi.new("char[65536]")
				while true do
					local n = tonumber(C.read(cp[0], rbuf, 65536))
					if n <= 0 then
						break
					end
					chunks[#chunks + 1] = ffi.string(rbuf, n)
				end
				C.close(cp[0])
				self.out(table.concat(chunks))
			else
				local pid = C.fork()
				if pid == 0 then
					self.in_pipestage = (self.in_pipestage or 0) + 1
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
						self.out = io.write
						stage_fns[k](self)
					end)
					M.child_status(self, ok, err)
					io.flush()
					C._exit(self.status or 0)
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
				C.waitpid(pids[k], stbuf, 0)
				est = M.wexit(stbuf[0])
			end
			pstat[k] = tostring(est)
			if k == nst then
				last = est
			end
			if est ~= 0 then
				pipe = est
			end -- rightmost non-zero (pipefail)
		end
		self:array_assign("PIPESTATUS", pstat, false)
		self.status = self.opt_pipefail and pipe or last
	end
	if negate then
		self.status = (self.status == 0) and 1 or 0
	end
end

-- A variable box holds a string value and/or a cached int64. An arithmetic
-- write stores only the int64 (s = nil) and defers stringification until a
-- string context reads it — this is the per-iteration allocation curse's JS
-- runtime also learned to avoid.
local function box(name, vars)
	local b = vars[name]
	if b == nil then
		b = {}
		vars[name] = b
	end
	return b
end

-- Parse a bash-ish scalar string to int64 (leading integer, else 0). bash's
-- real recursive/base rules come later; the arith-loop subset only needs this.
local function str_to_i64(s)
	if s == nil or s == "" then
		return i64(0)
	end
	local sign, digits = s:match("^%s*([%-+]?)(%d+)")
	if digits == nil then
		return i64(0)
	end
	local n = i64(0)
	for i = 1, #digits do
		n = n * 10LL + i64(digits:byte(i) - 48)
	end
	if sign == "-" then
		n = -n
	end
	return n
end
M.str_to_i64 = str_to_i64

-- `return [n]` status: no arg -> current $?; a numeric arg -> n mod 256; a
-- non-numeric arg -> 2 + diagnostic (bash). A pure runtime primitive the compiled
-- tier calls directly (no interp).
function M.return_status(sh, value, name)
	if value == nil then
		return sh.status
	end
	local n = tonumber(value)
	if not n then
		io.stderr:write("curse: " .. (name or "return") .. ": " .. value .. ": numeric argument required\n")
		return 2
	end
	return n % 256
end

-- Arithmetic numeric literal / value: like str_to_i64 but with bash arith bases —
-- base#digits (2-64), 0x/0X hex, leading-0 octal. Used ONLY in arithmetic
-- contexts ($(( )), arith var reads); `test` stays decimal (str_to_i64).
local function digit_val(ch, base)
	local b = ch:byte()
	if b >= 48 and b <= 57 then
		return b - 48
	end -- 0-9
	if base and base > 36 then -- bases 37-64 (zsh/bash):
		if b >= 97 and b <= 122 then
			return b - 97 + 10
		end -- a-z -> 10..35
		if b >= 65 and b <= 90 then
			return b - 65 + 36
		end -- A-Z -> 36..61
		if ch == "@" then
			return 62
		end
		if ch == "_" then
			return 63
		end
		return nil
	end
	if b >= 97 and b <= 122 then
		return b - 97 + 10
	end -- a-z -> 10..35 (case-insensitive)
	if b >= 65 and b <= 90 then
		return b - 65 + 10
	end -- A-Z -> 10..35 (base<=36)
	return nil
end
local function arith_num(s)
	if s == nil or s == "" then
		return i64(0)
	end
	s = s:match("^%s*(.-)%s*$")
	local sign = 1
	if s:sub(1, 1) == "-" then
		sign = -1
		s = s:sub(2)
	elseif s:sub(1, 1) == "+" then
		s = s:sub(2)
	end
	local base, digits = 10, nil
	local b, d = s:match("^(%d+)#(.+)$")
	if b then
		-- explicit N#digits: the base must not have a leading zero, and every digit
		-- must be valid for it (bash errors otherwise, unlike the lenient forms below).
		if (b:sub(1, 1) == "0" and #b > 1) or tonumber(b) < 2 or tonumber(b) > 64 then
			error({ __curse_exit = 1, __curse_matherr = true, __curse_experr = true })
		end
		base = tonumber(b)
		digits = d
		for k = 1, #d do
			local dv = digit_val(d:sub(k, k), base)
			if not dv or dv >= base then
				error({ __curse_exit = 1, __curse_matherr = true, __curse_experr = true })
			end
		end
	elseif s:sub(1, 2):lower() == "0x" then
		base = 16
		digits = s:sub(3)
	elseif s:sub(1, 1) == "0" and s:match("^0[0-7]+$") then
		base = 8
		digits = s:sub(2)
	else
		digits = s:match("^%d+") or ""
	end
	if digits == "" or base < 2 or base > 64 then
		return sign < 0 and -str_to_i64(s) or str_to_i64(s)
	end
	local n, B = i64(0), i64(base)
	for k = 1, #digits do
		local dv = digit_val(digits:sub(k, k), base)
		if not dv or dv >= base then
			break
		end
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
	for _ = 1, n do
		r = r * base
	end
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
function M.idiv(l, r)
	if r == i64(0) then
		div0()
	end
	return l / r
end
function M.imod(l, r)
	if r == i64(0) then
		div0()
	end
	return l % r
end

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
	if v >= -I64_EXACT and v <= I64_EXACT then
		return tonumber(v)
	end
	return i64_to_str(v)
end
local function key_i64(k) -- either key form -> int64 (for compare/arith)
	return type(k) == "string" and str_to_i64(k) or i64(k)
end
M.to_arr_key, M.key_i64 = to_arr_key, key_i64

-- Dynamic special variables (only when not explicitly set). Many spec cases just
-- check these "look like" a PID/uid/path, so exact values rarely matter.
ffi.cdef([[
  int getpid(void); int getppid(void); int getuid(void); int geteuid(void); int getegid(void);
  char *getcwd(char *buf, unsigned long size);
  int curse_rt_stat(const char *path, void *buf) asm("stat");
  int curse_rt_lstat(const char *path, void *buf) asm("lstat");
  struct curse_pw { char *pw_name; char *pw_passwd; unsigned int pw_uid; unsigned int pw_gid; char *pw_gecos; char *pw_dir; char *pw_shell; };
  struct curse_pw *getpwuid(unsigned int uid);
]])
local scratch = ffi.new("char[4096]")

-- Shell `set` options. `set -o NAME` and `$-` letters map to a Shell field; option
-- STATE is runtime data (sh.opt_*), so this machinery lives in runtime (interp and the
-- set/shopt builtins import it back via interp._int). SETOPTS is the ordered long-name
-- list; SETOPT maps a long name -> field; SETFLAG maps a `-x` letter -> field.
M.SETOPTS = {
	{ "allexport", "opt_a" },
	{ "braceexpand", "opt_B" },
	{ "emacs", "opt_emacs" },
	{ "errexit", "opt_e" },
	{ "errtrace", "opt_errtrace" },
	{ "functrace", "opt_functrace" },
	{ "hashall", "opt_h" },
	{ "histexpand", "opt_H" },
	{ "history", "opt_history" },
	{ "ignoreeof", "opt_ignoreeof" },
	{ "interactive-comments", "opt_icomments" },
	{ "keyword", "opt_k" },
	{ "monitor", "opt_m" },
	{ "noclobber", "opt_C" },
	{ "noexec", "opt_n" },
	{ "noglob", "opt_f" },
	{ "nolog", "opt_nolog" },
	{ "notify", "opt_b" },
	{ "nounset", "opt_u" },
	{ "onecmd", "opt_t" },
	{ "physical", "opt_P" },
	{ "pipefail", "opt_pipefail" },
	{ "posix", "opt_posix" },
	{ "privileged", "opt_p" },
	{ "verbose", "opt_v" },
	{ "vi", "opt_vi" },
	{ "xtrace", "opt_x" },
}
M.SETOPT = {}
for _, o in ipairs(M.SETOPTS) do
	M.SETOPT[o[1]] = o[2]
end
M.SETFLAG = {
	a = "opt_a",
	B = "opt_B",
	e = "opt_e",
	h = "opt_h",
	H = "opt_H",
	k = "opt_k",
	m = "opt_m",
	C = "opt_C",
	n = "opt_n",
	f = "opt_f",
	b = "opt_b",
	u = "opt_u",
	t = "opt_t",
	P = "opt_P",
	v = "opt_v",
	x = "opt_x",
	p = "opt_p",
	T = "opt_functrace",
	E = "opt_errtrace",
}
-- options that default ON (nil field state == off for the rest).
M.SETDEFAULT = { opt_B = true, opt_h = true, opt_H = true, opt_history = true, opt_icomments = true }
function M.opt_on(sh, field)
	local v = sh[field]
	if v ~= nil then
		return v
	end
	if field == "opt_emacs" then
		return sh.opt_i and true or false
	end -- emacs on only when interactive
	return M.SETDEFAULT[field] or false
end

-- `test`/`[`/`[[ ]]` file predicates (shared by both tiers and the builtins that used
-- to import them from interp). Pure stat/access FFI — a runtime primitive, not
-- interpretation. Offsets are glibc x86-64 struct stat (st_mode@24, st_uid@28,
-- st_gid@32, st_size@48, mtime sec@88/nsec@96, dev@0, ino@8).
local _ft_a, _ft_b = ffi.new("uint8_t[144]"), ffi.new("uint8_t[144]")
function M.file_test(op, path)
	if op == "-e" or op == "-a" then
		return C.access(path, 0) == 0
	end
	if op == "-r" then
		return C.access(path, 4) == 0
	end
	if op == "-w" then
		return C.access(path, 2) == 0
	end
	if op == "-x" then
		return C.access(path, 1) == 0
	end
	if op == "-t" then
		return C.isatty(tonumber(path) or -1) == 1
	end -- fd is a terminal
	local statfn = (op == "-h" or op == "-L") and C.curse_rt_lstat or C.curse_rt_stat
	local ok, rc = pcall(statfn, path, _ft_a)
	if not ok or rc ~= 0 then
		return false
	end
	local mode = ffi.cast("uint32_t *", _ft_a + 24)[0]
	local fmt = bit.band(mode, 0xF000)
	if op == "-f" then
		return fmt == 0x8000
	end -- S_IFREG
	if op == "-d" then
		return fmt == 0x4000
	end -- S_IFDIR
	if op == "-b" then
		return fmt == 0x6000
	end
	if op == "-c" then
		return fmt == 0x2000
	end
	if op == "-p" then
		return fmt == 0x1000
	end
	if op == "-S" then
		return fmt == 0xC000
	end
	if op == "-h" or op == "-L" then
		return fmt == 0xA000
	end -- S_IFLNK
	if op == "-k" then
		return bit.band(mode, 0x200) ~= 0
	end -- sticky
	if op == "-g" then
		return bit.band(mode, 0x400) ~= 0
	end -- setgid
	if op == "-u" then
		return bit.band(mode, 0x800) ~= 0
	end -- setuid
	if op == "-s" then
		return tonumber(ffi.cast("int64_t *", _ft_a + 48)[0]) > 0
	end -- st_size
	if op == "-O" then
		return ffi.cast("uint32_t *", _ft_a + 28)[0] == C.geteuid()
	end -- st_uid
	if op == "-G" then
		return ffi.cast("uint32_t *", _ft_a + 32)[0] == C.getegid()
	end -- st_gid
	return false
end
function M.file_bincmp(op, x, y)
	local function st(path, buf)
		local ok, rc = pcall(C.curse_rt_stat, path, buf)
		return ok and rc == 0
	end
	local ax, ay = st(x, _ft_a), st(y, _ft_b)
	if op == "-ef" then
		if not (ax and ay) then
			return false
		end
		return ffi.cast("uint64_t *", _ft_a)[0] == ffi.cast("uint64_t *", _ft_b)[0] -- st_dev @0
			and ffi.cast("uint64_t *", _ft_a + 8)[0] == ffi.cast("uint64_t *", _ft_b + 8)[0] -- st_ino @8
	end
	local function older(ba, bb) -- ba's mtime < bb's mtime (sec@88, nsec@96, lexicographic)
		local s1, s2 = tonumber(ffi.cast("int64_t *", ba + 88)[0]), tonumber(ffi.cast("int64_t *", bb + 88)[0])
		if s1 ~= s2 then
			return s1 < s2
		end
		return tonumber(ffi.cast("int64_t *", ba + 96)[0]) < tonumber(ffi.cast("int64_t *", bb + 96)[0])
	end
	if op == "-nt" then
		return ax and (not ay or older(_ft_b, _ft_a))
	end -- x newer (or y missing)
	return ay and (not ax or older(_ft_a, _ft_b)) -- -ot: x older (or x missing)
end

-- [[ l == r ]] / [[ l = r ]] (the compiled tier's twin of interp's dbracket_eq): a QUOTED
-- rhs is a literal string (fast `==` unless nocasematch, else glob its escaped form), an
-- UNQUOTED rhs is a glob pattern. Honors shopt nocasematch. `rq` = rhs was quoted.
local function db_glob_escape(s)
	return (s:gsub("[%*%?%[%]\\]", "\\%0"))
end
function M.dbracket_eq(sh, l, r, rq)
	local ic = sh.shopt.nocasematch and true or nil
	if rq and not ic then
		return l == r
	end
	return M.glob_match(l, rq and db_glob_escape(r) or r, ic)
end

-- Password database read DIRECTLY from /etc/passwd, not via getpw*/NSS. A fully
-- static build can't dlopen libnss_*, and for a shell (~user, $SHELL, ~user
-- completion) the local passwd file is what these want. Cached for the process
-- lifetime — daemon workers are short-lived, a cold one-shot reads it once.
local _passwd
local function passwd_all()
	if _passwd then
		return _passwd
	end
	_passwd = {}
	local f = io.open("/etc/passwd", "r")
	if f then
		for line in f:lines() do
			-- name:passwd:uid:gid:gecos:dir:shell
			local name, uid, dir, shell = line:match("^([^:]*):[^:]*:([^:]*):[^:]*:[^:]*:([^:]*):([^:]*)$")
			if name and name ~= "" and name:sub(1, 1) ~= "#" then
				_passwd[#_passwd + 1] = { name = name, uid = tonumber(uid), dir = dir or "", shell = shell or "" }
			end
		end
		f:close()
	end
	return _passwd
end
function M.pw_by_name(n)
	for _, e in ipairs(passwd_all()) do
		if e.name == n then
			return e
		end
	end
end
function M.pw_by_uid(u)
	for _, e in ipairs(passwd_all()) do
		if e.uid == u then
			return e
		end
	end
end
function M.pw_names()
	local o = {}
	for _, e in ipairs(passwd_all()) do
		o[#o + 1] = e.name
	end
	return o
end

-- Tilde expansion (pure runtime: HOME/PWD/OLDPWD + the passwd db + string ops, no
-- recursion into arith/cmdsub/execution). Both tiers use these — the compiled tier
-- references rt.tilde_* directly, never interp.
function M.tilde_prefix(sh, s)
	if s:sub(1, 1) ~= "~" then
		return s
	end
	local r = s:sub(2)
	-- The tilde-prefix login name ends at the first `/` OR `:` (bash: `~:~` -> the
	-- bare `~` expands, `:~` stays; `~root:x` -> /root:x). So `:` terminates the ~/
	-- ~+/~-/~user forms just like `/` does.
	local c1 = r:sub(1, 1)
	if r == "" or c1 == "/" or c1 == ":" then -- ~ / ~/… / ~:… : HOME's value if SET (even ""); else literal
		if sh.vars[sh:deref("HOME")] ~= nil then
			return sh:get("HOME") .. r
		end
		return s
	end
	if r == "+" or r:sub(1, 2) == "+/" or r:sub(1, 2) == "+:" then
		return sh:pwd() .. r:sub(2)
	end
	if r == "-" or r:sub(1, 2) == "-/" or r:sub(1, 2) == "-:" then
		local o = sh:get("OLDPWD")
		return o ~= "" and (o .. r:sub(2)) or s
	end
	-- ~user / ~user/… : the named user's home directory (unknown user stays literal)
	local user, tail = r:match("^([^/:]+)(.*)$")
	if user then
		local pw = M.pw_by_name(user)
		if pw and pw.dir ~= "" then
			return pw.dir .. tail
		end
	end
	return s
end

function M.tilde_assign(sh, s)
	if not s:find("~", 1, true) then
		return s
	end -- fast path: nothing to expand
	local segs = {}
	for seg in (s .. ":"):gmatch("([^:]*):") do
		segs[#segs + 1] = M.tilde_prefix(sh, seg)
	end
	return table.concat(segs, ":")
end

-- Word-initial unquoted-literal tilde. bash also tilde-expands a word shaped like
-- `NAME=value` (a valid identifier before `=`) as if it were an assignment RHS —
-- at the value start and after each `:` — even for a plain command argument
-- (`echo x=~`). Otherwise only a leading `~` expands.
function M.tilde_word_initial(sh, s)
	local pre, rest = s:match("^([%a_][%w_]*%+?=)(.*)$")
	if pre then
		return pre .. M.tilde_assign(sh, rest)
	end
	return M.tilde_prefix(sh, s)
end
local stbuf_a, stbuf_b = ffi.new("uint8_t[144]"), ffi.new("uint8_t[144]")
-- Do two paths name the same directory (same device + inode)? Used to validate an
-- inherited $PWD against the real cwd on startup (bash keeps a symlinked $PWD only
-- if it still refers to the current directory).
local function same_file(a, b)
	if ffi.C.curse_rt_stat(a, stbuf_a) ~= 0 then
		return false
	end
	if ffi.C.curse_rt_stat(b, stbuf_b) ~= 0 then
		return false
	end
	return ffi.cast("uint64_t *", stbuf_a)[0] == ffi.cast("uint64_t *", stbuf_b)[0] -- st_dev @0
		and ffi.cast("uint64_t *", stbuf_a + 8)[0] == ffi.cast("uint64_t *", stbuf_b + 8)[0] -- st_ino @8
end
-- Resolve a bare command NAME to an absolute path via $PATH — the first
-- executable, non-directory match (like execvp) — and cache it (bash's command
-- hash). The cache survives filesystem changes under a STABLE $PATH (only
-- `hash -r` clears it then), but CHANGING $PATH invalidates it — bash rehashes.
function Shell:resolve_cmd(name)
	local curpath = self:get("PATH")
	if self.hashpath and self.hashpath ~= curpath then
		self.hashcache = {}
	end -- PATH changed: rehash
	self.hashpath = curpath
	local c = self.hashcache and self.hashcache[name]
	if c then
		c.hits = c.hits + 1
		return c.path
	end
	for dir in (curpath .. ":"):gmatch("([^:]*):") do
		local cand = (dir == "" and "." or dir) .. "/" .. name
		if
			ffi.C.access(cand, 1) == 0
			and ffi.C.curse_rt_stat(cand, stbuf_a) == 0 -- 1 == X_OK
			and bit.band(ffi.cast("uint32_t *", stbuf_a + 24)[0], 0xF000) ~= 0x4000
		then -- not a dir
			self.hashcache = self.hashcache or {}
			self.hashcache[name] = { path = cand, hits = 1 }
			return cand
		end
	end
	return nil
end
function Shell:phys_cwd()
	local p = ffi.C.getcwd(scratch, 4096)
	return p ~= nil and ffi.string(p) or ""
end
-- Logical current directory: the tracked $PWD (may keep a symlinked name), else
-- the physical cwd. `pwd`, `cd`'s bookkeeping, tilde `~+` and prompts use this.
function Shell:pwd()
	local b = self.vars["PWD"]
	if b and b.s and b.s ~= "" then
		return b.s
	end
	return self:phys_cwd()
end
local pid_cache
function Shell:pid()
	if not pid_cache then
		pid_cache = tonumber(ffi.C.getpid())
	end
	return pid_cache
end
function Shell:special_get(name)
	-- $# as a base value for an operator form (`${##2}` = $# with a `#2` strip); the
	-- bare ${#}/${#@} count and ${#var} length go through their own dedicated nodes.
	if name == "#" then
		return tostring(self.nparams)
	end
	if name == "RANDOM" then
		return tostring(math.random(0, 32767))
	end
	-- $PWD is a real tracked variable (see :pwd / import_env); once unset it reads
	-- empty like any other var, so special_get does NOT fall back to getcwd here.
	if name == "PPID" then
		return tostring(tonumber(ffi.C.getppid()))
	end
	if name == "UID" then
		return tostring(tonumber(ffi.C.getuid()))
	end
	if name == "EUID" then
		return tostring(tonumber(ffi.C.geteuid()))
	end
	if name == "BASHPID" then
		return tostring(tonumber(ffi.C.getpid()))
	end -- fresh: changes in subshells
	if name == "FUNCNAME" then
		return (self.funcstack and self.funcstack[1]) or ""
	end
	if name == "BASH_SOURCE" then
		return self:bash_source_array()[1] or ""
	end -- [0]: current source
	if name == "BASH_LINENO" then
		return self:bash_lineno_array()[1] or "0"
	end -- [0]: caller's line
	if name == "SHELLOPTS" and self.shellopts then
		return self:shellopts()
	end -- live set -o list
	if name == "BASHOPTS" and self.bashopts then
		return self:bashopts()
	end -- live shopt list
	if name == "OSTYPE" then
		return "linux-gnu"
	end
	if name == "MACHTYPE" then
		return "x86_64-pc-linux-gnu"
	end
	if name == "HOSTTYPE" then
		return "x86_64"
	end
	if name == "SECONDS" then
		return tostring(os.time() - (self.start_time or os.time()))
	end
	if name == "LINENO" then
		return tostring(self.cur_line or 0)
	end
	return ""
end

-- Follow nameref (declare -n) chains to the effective variable name. A nameref
-- box has b.ref set and b.s holding the target's name (possibly with a subscript,
-- which is stripped here — element namerefs resolve to the base array).
function Shell:deref(name)
	local seen
	for _ = 1, 100 do
		local b = self.vars[name]
		if not b or not b.ref or b.s == nil or b.s == "" then
			return name
		end
		local t = b.s
		local br = t:find("[", 1, true)
		local tname = br and t:sub(1, br - 1) or t
		-- An invalid target name (e.g. `#`, `1`, `$1`) isn't a real reference: reading
		-- the nameref yields its own stored string, so resolve to the nameref itself.
		if not tname:match("^[%a_][%w_]*$") then
			return name
		end
		-- mutually recursive namerefs (ref1->ref2->ref1) resolve to nothing in bash
		if seen and seen[tname] then
			return ""
		end
		seen = seen or {}
		seen[name] = true
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
	local function valid(t)
		return t:match("^[%a_][%w_]*$") or t:match("^[%a_][%w_]*%[.+%]$")
	end
	if target ~= nil then
		if not valid(target) then
			return false
		end -- explicit target (empty/@/*/1/… rejected)
	else
		-- converting an existing var: its current value becomes the target — bash
		-- rejects the conversion if that value is not a valid target (a non-empty
		-- invalid one; an unset/empty var makes a valid deferred nameref).
		local b = self.vars[name]
		if b and b.s and b.s ~= "" and not valid(b.s) then
			return false
		end
	end
	local b = box(name, self.vars)
	b.ref = true
	if target ~= nil then
		b.s = target
		b.n = nil
		b.arr = nil
	end
	return true
end
function Shell:unref(name)
	local b = self.vars[name]
	if b then
		b.ref = nil
	end
end
function Shell:is_nameref(name)
	local b = self.vars[name]
	return b and b.ref
end
-- ${var@a}: the variable's attribute flags, in bash's order (aA r x i l u n).
function Shell:attr_string(name)
	local b = self.vars[self:deref(name)]
	if not b then
		return ""
	end
	-- bash's canonical attribute order (declare -p and ${x@a} share it): array/assoc,
	-- integer, readonly, export, lower, upper, nameref. Verified against bash 5:
	-- `declare -aixr` -> `airx`, `declare -rxil` -> `irxl`.
	local s = ""
	if b.assoc then
		s = s .. "A"
	elseif b.arr then
		s = s .. "a"
	end
	if b.int then
		s = s .. "i"
	end
	if b.ro then
		s = s .. "r"
	end
	if b.exported then
		s = s .. "x"
	end
	if b.lower then
		s = s .. "l"
	end
	if b.upper then
		s = s .. "u"
	end
	if b.ref then
		s = s .. "n"
	end
	return s
end

-- Mark a variable readonly (declare -r / readonly, applied AFTER its value is assigned —
-- a fresh `declare -r a=(…)` assigns, then locks). No-op if the name has no binding.
function Shell:mark_readonly(name)
	local b = self.vars[self:deref(name)]
	if b then
		b.ro = true
	end
end

-- String value of a var (materialize from the cached int64 if needed).
function Shell:get(name)
	name = self:deref(name)
	local b = self.vars[name]
	if b == nil then
		return self:special_get(name)
	end
	-- $a == ${a[0]}: indexed arrays key on the number 0; assoc arrays on "0".
	if b.arr then
		return (b.assoc and b.arr["0"] or b.arr[0]) or ""
	end
	if b.s == nil then
		if b.n == nil then
			return ""
		end
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
	if self.opt_u and unset and self:special_get(name) == "" and name ~= "@" and name ~= "*" then
		io.stderr:write("curse: " .. name .. ": unbound variable\n")
		error({ __curse_exit = self.opt_c and 127 or 1, __curse_lineabort = self.opt_i or nil })
	end
	return self:get(name)
end
-- Read a scalar variable ($x / ${x} / "$x") in a program that DECLARES a nameref.
-- A nameref can resolve THROUGH to an array/assoc ELEMENT (`declare -n ref='a[2]'`),
-- which :deref renders as the base var's [0] rather than the element — only the word
-- engine derefs an element-nameref. Nameref programs are rare/cold, so reproduce the
-- interp's word-read exactly (element-deref + nounset) via a bootstrap rather than
-- re-deriving the deref subtlety here. (BOOT into the shared expander, not a SEAM.)
function M.nameref_read(sh, name)
	return require("interp")._int.expand_part_str(sh, { var = name })
end
-- ${#name} length in a nameref program. bash's parameter_brace_expand_length follows the
-- nameref to a target VARIABLE (find_variable): a scalar/whole-array/assoc target yields the
-- length of its value (or element [0]), but a target that is an array/assoc ELEMENT (the ref
-- string carries a subscript) has no scalar value_cell there, so the length is 0 — a quirk
-- distinct from ${name#op}, which does the full element deref. Follow the chain: if it ends at
-- an element ref, 0; otherwise the derefed value's codepoint length (nameref_read = the same
-- full deref, which for a scalar/whole-array/assoc target is exactly the length source).
function M.nameref_len(sh, name)
	local seen, n = nil, name
	for _ = 1, 100 do
		local b = sh.vars[n]
		if not b or not b.ref or b.s == nil or b.s == "" then
			break
		end
		if b.s:find("[", 1, true) then
			return 0 -- target is an array/assoc element ref
		end
		if not b.s:match("^[%a_][%w_]*$") then
			break -- invalid target name: the ref reads as its own value
		end
		if seen and seen[b.s] then
			break -- ref cycle
		end
		seen = seen or {}
		seen[n] = true
		n = b.s
	end
	return M.mb_strlen(M.nameref_read(sh, name))
end
-- Capture-aware error write: inside a `$(...)` capture with `2>&1` active, route
-- the message into the capture buffer (self.out) so it's captured like bash;
-- otherwise to real stderr. Mirrors interp's sherr for runtime-side messages.
function Shell:errmsg(msg)
	if self.capturing and (self.err2out or 0) > 0 then
		self.out(msg)
	else
		io.stderr:write(msg)
	end
end

-- int64 value of a var for arithmetic (use the cache, else parse the string).
function Shell:aget(name)
	name = self:deref(name)
	local b = self.vars[name]
	if b == nil then
		return i64(0)
	end
	if b.arr then
		return M.arith_num(b.arr[0] or b.arr["0"] or "0")
	end -- decays to [0]/["0"]
	if b.n == nil then
		b.n = M.arith_num(b.s)
	end -- arith context: honor bases (0x, 010, N#)
	return b.n
end

-- Locale variables: assigning/unsetting any of these re-applies setlocale (bash).
local LOCALE_VARS = {
	LANG = 1,
	LC_ALL = 1,
	LC_CTYPE = 1,
	LC_NUMERIC = 1,
	LC_TIME = 1,
	LC_COLLATE = 1,
	LC_MONETARY = 1,
	LC_MESSAGES = 1,
}
M.LOCALE_VARS = LOCALE_VARS

function Shell:set_str(name, s)
	if s:find("\0", 1, true) then
		s = M.cstr(s)
	end -- bash vars are C strings: cut at NUL
	local dn = self:deref(name)
	local b = box(dn, self.vars)
	b.s = s
	b.n = nil
	if b.exported then
		C.setenv(dn, s, 1)
	end -- keep the env in sync
	if LOCALE_VARS[dn] then
		M.reset_locale(self)
	end -- track the locale live, like bash
end

-- Set a variable AND mark it exported (updating the process env). Used for
-- PWD/OLDPWD, which `cd`/pushd/popd must keep in the environment for children.
function Shell:export_str(name, val)
	self:set_str(name, val)
	self.vars[name].exported = true
	C.setenv(name, val, 1)
end

-- Inherit the process environment as shell variables (bash does this at startup).
-- PWD/OLDPWD are handled specially below: PWD is initialized (and kept logical),
-- OLDPWD inherited if present; `cd` maintains both thereafter.
function Shell:import_env()
	local e = ffi.C.environ
	if e == nil then
		return
	end
	local i, env_pwd, env_oldpwd = 0, nil, nil
	while e[i] ~= nil do
		local s = ffi.string(e[i])
		local eq = s:find("=", 1, true)
		if eq then
			local k = s:sub(1, eq - 1)
			if k == "PWD" then
				env_pwd = s:sub(eq + 1)
			elseif k == "OLDPWD" then
				env_oldpwd = s:sub(eq + 1)
			elseif
				k == "UID"
				or k == "EUID"
				or k == "PPID" -- shell-computed, not from env
				or k == "BASHOPTS"
			then -- readonly, derived live from the option state
			elseif k == "SHELLOPTS" then -- inherited set -o options: enable them (bash), keep exported
				self.shellopts_import = s:sub(eq + 1)
				self.shellopts_exported = true
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
	self:set_str("PWD", pwd)
	self.vars["PWD"].exported = true
	if env_oldpwd then
		self:set_str("OLDPWD", env_oldpwd)
		self.vars["OLDPWD"].exported = true
	end
	-- bash provides a default $PATH when none is inherited (e.g. `unset PATH; sh -c …`).
	if self.vars["PATH"] == nil then
		self:set_str("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
	end
	-- Shell-maintained vars bash always defines even with `env -i` and no rc file.
	if self.vars["IFS"] == nil then
		self:set_str("IFS", " \t\n")
	end
	if self.vars["PS4"] == nil then
		self:set_str("PS4", "+ ")
	end
	-- $SHELL: bash sets it from the passwd entry (the login shell) when not inherited.
	if self.vars["SHELL"] == nil then
		local pw = M.pw_by_uid(tonumber(ffi.C.geteuid()))
		if pw and pw.shell ~= "" then
			self:set_str("SHELL", pw.shell)
		end
	end
	-- SHELLOPTS/BASHOPTS are NOT stored: special_get derives them live from the
	-- current set -o / shopt state (and they're readonly), matching bash.
end

-- Arithmetic write: store the int64, defer the string (lazy).
function Shell:aset(name, n)
	local b = box(self:deref(name), self.vars)
	if b.arr then
		b.arr[b.assoc and "0" or 0] = i64_to_str(i64(n))
		return i64(n)
	end -- (( a = n )) hits a[0]
	b.n = i64(n)
	b.s = nil
	return b.n
end

-- ---- indexed arrays ----
-- Stored in the var box as b.arr = { [0]=…, [1]=… } (0-based, may be sparse, to
-- match bash). A plain scalar has no b.arr; reading $a is ${a[0]}.
local function arr_max(arr)
	local m = i64(-1)
	for k in pairs(arr) do
		local ki = key_i64(k)
		if ki > m then
			m = ki
		end
	end
	return m
end

-- `declare -A name`: mark as associative (string keys, insertion-order iteration —
-- note: real bash iterates in hash order; insertion order matches the common cases).
function Shell:declare_assoc(name)
	local b = box(self:deref(name), self.vars)
	b.assoc = true
	b.arr = b.arr or {}
	b.order = b.order or {}
	if b.s ~= nil then
		b.arr["0"] = b.s
		b.order[#b.order + 1] = "0"
	end -- a scalar becomes [0] (bash)
	b.s = nil
	b.n = nil
end
function Shell:is_assoc(name)
	local b = self.vars[self:deref(name)]
	return b and b.assoc
end

function Shell:array_assign(name, values, append)
	local b = box(self:deref(name), self.vars)
	if append and b.arr then
		local base = arr_max(b.arr) + 1
		for i = 1, #values do
			b.arr[base + i - 1] = values[i]
		end
	else
		b.arr = {}
		b.s = nil
		b.n = nil
		for i = 1, #values do
			b.arr[i - 1] = values[i]
		end
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
	if val:find("\0", 1, true) then
		val = M.cstr(val)
	end -- C-string element: cut at NUL
	local b = box(self:deref(name), self.vars)
	if not b.arr then
		b.arr = {}
		if b.s then
			b.arr[0] = b.s
		end
		b.s = nil
		b.n = nil
	end
	key = norm_key(b, key)
	if type(key) == "number" and key < 0 then
		return false
	end -- out-of-range negative: bash errors
	if b.assoc and b.arr[key] == nil then
		b.order[#b.order + 1] = key
	end
	if append then
		b.arr[key] = (b.arr[key] or "") .. val
	else
		b.arr[key] = val
	end
	return true
end
-- FUNCNAME is a virtual array: the call stack innermost-first, then "main"
-- (empty at the top level). funcstack[1] is the innermost function.
function Shell:funcname_array()
	local fs = self.funcstack
	if not fs or #fs == 0 then
		return {}
	end
	local t = {}
	for i = 1, #fs do
		t[i] = fs[i]
	end
	-- a script (or stdin) has a "main" bottom frame; `sh -c` has none (bash).
	if not self.opt_c then
		t[#t + 1] = "main"
	end
	return t
end
-- ${BASH_SOURCE[@]} / ${BASH_LINENO[@]}: parallel to the call stack. BASH_SOURCE[0]
-- is the current source; BASH_LINENO[0] is where the current function was called.
-- The bottom frame is the main script / line 0. (Single-file scripts: all the
-- sources are the main script path — curse doesn't track per-function def files.)
function Shell:bash_source_array()
	local t = { self.cur_source or self.argv0 or "" }
	local ss = self.srcstack or {}
	for i = 1, #ss do
		t[#t + 1] = ss[i]
	end
	return t
end
function Shell:bash_lineno_array()
	local t = {}
	local ls = self.linestack or {}
	for i = 1, #ls do
		t[i] = tostring(ls[i])
	end
	t[#t + 1] = "0"
	return t
end
local VIRT_ARR = { FUNCNAME = "funcname_array", BASH_SOURCE = "bash_source_array", BASH_LINENO = "bash_lineno_array" }
function Shell:array_get(name, key)
	if VIRT_ARR[name] then
		return self[VIRT_ARR[name]](self)[(tonumber(key) or 0) + 1] or ""
	end
	local b = self.vars[self:deref(name)]
	if b and b.arr then
		return b.arr[norm_key(b, key)] or ""
	end
	if key == 0 then
		return self:get(name)
	end
	return ""
end
-- Sorted variable names beginning with `pfx` (for ${!pfx@} / ${!pfx*}).
function Shell:var_prefix_names(pfx)
	local t = {}
	for k in pairs(self.vars) do
		if k:sub(1, #pfx) == pfx then
			t[#t + 1] = k
		end
	end
	table.sort(t)
	return t
end
-- Is element [key] set? (distinct from "" — for [[ -v a[k] ]]).
function Shell:is_elem_set(name, key)
	local b = self.vars[self:deref(name)]
	if not b then
		return false
	end
	if b.arr then
		return b.arr[norm_key(b, key)] ~= nil
	end
	return key == 0 and (b.s ~= nil or b.n ~= nil)
end
-- unset a single element a[key]; returns false on an out-of-range negative index
-- (bash: `unset a[-2]` on a 1-element array is an error).
function Shell:array_unset(name, key)
	local b = self.vars[self:deref(name)]
	if not (b and b.arr) then
		return true
	end
	local k = norm_key(b, key)
	if type(k) == "number" and k < 0 then
		return false
	end
	b.arr[k] = nil
	return true
end
-- bash iterates an assoc array in HASH-TABLE order, not insertion order: the
-- key's FNV-1 32-bit hash (over its bytes) picks one of 1024 buckets, buckets are
-- walked ascending, and within a bucket the most-recently-inserted key comes
-- first (bash prepends to the chain). Reproduced exactly so ${!m[@]} / ${m[@]}
-- match bash. int64 keeps the 32-bit multiply
-- exact (a plain Lua double would lose precision past 2^53).
local FNV32_OFFSET, FNV32_PRIME, U32 = i64(2166136261), i64(16777619), i64(4294967296)
local function assoc_bucket(key)
	local h = FNV32_OFFSET
	for j = 1, #key do
		h = (h * FNV32_PRIME) % U32 -- FNV-1: multiply first…
		h = bit.bxor(h, i64(key:byte(j))) -- …then xor the byte
	end
	return tonumber(h % i64(1024))
end

function Shell:array_indices(name)
	if VIRT_ARR[name] then
		local a = self[VIRT_ARR[name]](self)
		local t = {}
		for i = 1, #a do
			t[i] = i - 1
		end
		return t
	end
	local b = self.vars[self:deref(name)]
	if b and b.assoc then
		local live = {}
		for idx, k in ipairs(b.order) do
			if b.arr[k] ~= nil then
				live[#live + 1] = { k = k, i = idx, bkt = assoc_bucket(k) }
			end
		end
		table.sort(live, function(a, z)
			if a.bkt ~= z.bkt then
				return a.bkt < z.bkt
			else
				return a.i > z.i
			end
		end)
		local t = {}
		for _, e in ipairs(live) do
			t[#t + 1] = e.k
		end
		return t
	end
	if b and b.arr then
		local t = {}
		for k in pairs(b.arr) do
			t[#t + 1] = k
		end
		table.sort(t, function(a, z)
			return key_i64(a) < key_i64(z)
		end)
		return t -- int64 order (mixed number/string keys)
	end
	if b and (b.s ~= nil or b.n ~= nil) then
		return { 0 }
	end
	return {}
end
function Shell:array_values(name)
	if VIRT_ARR[name] then
		return self[VIRT_ARR[name]](self)
	end
	local idx = self:array_indices(name)
	local t = {}
	for i = 1, #idx do
		t[i] = self:array_get(name, idx[i])
	end
	return t
end
function Shell:array_count(name)
	return #self:array_indices(name)
end

-- ---- parameter expansion ${var OP arg} ----
-- Whole-string glob match via the POSIX regex engine (real char classes/extglob).
-- Deferred to call time through M so it can be defined textually after this.
local function full_match(s, glob)
	if glob:find("!(", 1, true) then
		return M.ext_match(s, glob)
	end -- !() needs the split matcher
	return M.regex_match(s, M.glob_to_ere(glob))
end
-- Fast path: a glob with no char class / extglob / escape and at most ONE `*` is
-- `pre * post` (either side possibly empty), matchable with plain byte find/compare —
-- no regcomp. Returns the stripped string, or nil when the glob needs the regex path.
-- The naive strip below tries every split point × a regcomp each, which is O(n)
-- regex compiles per call — ruinous in a loop (`${p##*/}`), so this handles the
-- overwhelmingly common patterns (literal, `*/`, `.*`, `*.c`, `foo*`) directly.
-- Classify a glob into a fast-path shape: "" (literal, no star) or "*" (single
-- star: prefix "*" suffix), else nil (needs the general regex matcher). Pure
-- function of `glob` — same pattern always yields the same shape.
local function simple_glob_uncached(glob)
	if glob:find("[%?%[%]\\]") then
		return nil
	end -- ?, [ ], backslash-escape
	if glob:find("[@!+?*]%(") then
		return nil
	end -- extglob @(..) etc
	local star = select(2, glob:gsub("%*", ""))
	if star == 0 then
		return "", glob, ""
	end -- literal (pre only, no star)
	if star ~= 1 then
		return nil
	end -- multiple * -> regex path
	local pre, post = glob:match("^(.-)%*(.*)$")
	if post:find("%*") then
		return nil
	end
	return "*", pre, post
end
-- Memoize the shape classification. simple_glob runs on EVERY ${x#pat}/${x%pat},
-- ${x//a/b}, and `case … in pat)` — including in loops with a constant pattern —
-- and re-parsing that constant each call was ~1/4 of curse's compute-path CPU
-- (profiled). Cache keyed by the pattern string (pure fn), bounded by a flush so a
-- long-lived daemon can't grow it without bound (distinct literal patterns are few).
local _glob_cache, _glob_n = {}, 0
local GLOB_NOFAST = {} -- sentinel: this pattern is NOT a fast-path glob
local function simple_glob(glob)
	local c = _glob_cache[glob]
	if c == nil then
		local k, pre, post = simple_glob_uncached(glob)
		c = k ~= nil and { k, pre, post } or GLOB_NOFAST
		if _glob_n >= 1024 then
			_glob_cache = {}
			_glob_n = 0
		end
		_glob_cache[glob] = c
		_glob_n = _glob_n + 1
	end
	if c == GLOB_NOFAST then
		return nil
	end
	return c[1], c[2], c[3]
end
local function fast_strip(val, glob, prefix, longest)
	local kind, pre, post = simple_glob(glob)
	if not kind then
		return nil, false
	end
	if kind == "" then -- pure literal: prefix/suffix must match exactly (longest==shortest)
		local L = pre
		if prefix then
			if val:sub(1, #L) == L then
				return val:sub(#L + 1), true
			end
		else
			if L == "" or val:sub(#val - #L + 1) == L then
				return (L == "" and val or val:sub(1, #val - #L)), true
			end
		end
		return val, true
	end
	-- pattern = pre * post
	if prefix then
		if val:sub(1, #pre) ~= pre then
			return val, true
		end -- must start with pre
		if post == "" then
			return longest and "" or val:sub(#pre + 1), true
		end -- pre* : strip pre / all
		-- find first/last occurrence of post at or after pre
		if longest then
			local last
			local i = #pre + 1
			while true do
				local s = val:find(post, i, true)
				if not s then
					break
				end
				last = s
				i = s + 1
			end
			if last then
				return val:sub(last + #post), true
			end
		else
			local s = val:find(post, #pre + 1, true)
			if s then
				return val:sub(s + #post), true
			end
		end
		return val, true
	else -- suffix: pattern pre*post; val must end with post
		if post ~= "" and val:sub(#val - #post + 1) ~= post then
			return val, true
		end
		local hi = #val - #post - #pre + 1 -- last valid start of pre
		if hi < 1 then
			return val, true
		end
		if pre == "" then -- pattern *post: shortest suffix = post only, longest = whole ending in post
			return longest and "" or val:sub(1, #val - #post), true
		end
		if longest then -- first occurrence of pre in [1, hi]
			local s = val:find(pre, 1, true)
			if s and s <= hi then
				return val:sub(1, s - 1), true
			end
		else -- last occurrence of pre in [1, hi]
			local last, i = nil, 1
			while true do
				local s = val:find(pre, i, true)
				if not s or s > hi then
					break
				end
				last = s
				i = s + 1
			end
			if last then
				return val:sub(1, last - 1), true
			end
		end
		return val, true
	end
end
-- Regex fallback for strip: compile the glob's ERE ONCE, then regexec each candidate
-- prefix/suffix. (The naive form recompiled per split point — O(n) regcomps per call.)
-- `!()` extglob needs the split matcher, so it stays on the per-substring path.
local function strip_regex(val, glob, prefix, longest)
	if glob:find("!(", 1, true) then
		if prefix then
			if longest then
				for k = #val, 0, -1 do
					if full_match(val:sub(1, k), glob) then
						return val:sub(k + 1)
					end
				end
			else
				for k = 0, #val do
					if full_match(val:sub(1, k), glob) then
						return val:sub(k + 1)
					end
				end
			end
		else
			if longest then
				for k = 1, #val + 1 do
					if full_match(val:sub(k), glob) then
						return val:sub(1, k - 1)
					end
				end
			else
				for k = #val + 1, 1, -1 do
					if full_match(val:sub(k), glob) then
						return val:sub(1, k - 1)
					end
				end
			end
		end
		return val
	end
	local rb = ffi.new("char[512]") -- own regex_t (regbuf local is declared later in the file)
	if ffi.C.regcomp(rb, M.glob_to_ere(glob), 1 + 8) ~= 0 then
		return val
	end -- REG_EXTENDED|REG_NOSUB
	local function m(s)
		return ffi.C.regexec(rb, s, 0, nil, 0) == 0
	end
	local res = val
	if prefix then
		if longest then
			for k = #val, 0, -1 do
				if m(val:sub(1, k)) then
					res = val:sub(k + 1)
					break
				end
			end
		else
			for k = 0, #val do
				if m(val:sub(1, k)) then
					res = val:sub(k + 1)
					break
				end
			end
		end
	else
		if longest then
			for k = 1, #val + 1 do
				if m(val:sub(k)) then
					res = val:sub(1, k - 1)
					break
				end
			end
		else
			for k = #val + 1, 1, -1 do
				if m(val:sub(k)) then
					res = val:sub(1, k - 1)
					break
				end
			end
		end
	end
	ffi.C.regfree(rb)
	return res
end
local function strip_prefix(val, glob, longest)
	local r, ok = fast_strip(val, glob, true, longest)
	if ok then
		return r
	end
	return strip_regex(val, glob, true, longest)
end
local function strip_suffix(val, glob, longest)
	local r, ok = fast_strip(val, glob, false, longest)
	if ok then
		return r
	end
	return strip_regex(val, glob, false, longest)
end
local function substr(val, off, len)
	-- ${v:off:len} slices by CHARACTER (codepoint) in the locale, like bash — offset
	-- and length count codepoints, not bytes (byte-equivalent under LC_ALL=C).
	-- ASCII/single-byte fast path: codepoint == byte, so slice directly with the same
	-- offset/length math — no mb_chars char-table.
	if lc_mb_cur_max <= 1 then
		local n = #val
		local o = tonumber(off) or 0
		if o < 0 then
			o = n + o
		end
		if o < 0 then
			o = 0
		end
		local last = n
		if len and len ~= "" then
			local l = tonumber(len) or 0
			last = (l < 0) and (n + l) or (o + l)
		end
		if last > n then
			last = n
		end
		return val:sub(o + 1, last)
	end
	local chars = M.mb_chars(val)
	local n = #chars
	local o = tonumber(off) or 0
	if o < 0 then
		o = n + o
	end
	if o < 0 then
		o = 0
	end
	local last = n
	if len and len ~= "" then
		local l = tonumber(len) or 0
		last = (l < 0) and (n + l) or (o + l)
	end
	if last > n then
		last = n
	end
	local out = {}
	for k = o + 1, last do
		out[#out + 1] = chars[k].s
	end
	return table.concat(out)
end

-- ---- real regex via libc POSIX regcomp/regexec (for case globs, =~, and
-- pathname/glob expansion) — a real engine, unlike Lua patterns. ----
ffi.cdef([[
  int regcomp(void *preg, const char *regex, int cflags);
  int regexec(const void *preg, const char *s, unsigned long nmatch, void *pmatch, int eflags);
  void regfree(void *preg);
  void *opendir(const char *name);
  void *readdir(void *dirp);
  int closedir(void *dirp);
]])
local REG_EXTENDED, REG_NOSUB, REG_ICASE = 1, 8, 2
local regbuf = ffi.new("char[512]") -- opaque regex_t (glibc ~64B; over-allocate)

-- Convert a shell glob to a POSIX ERE, anchored. Char classes carry over (with
-- [!..] -> [^..]); regex-special chars elsewhere are escaped.
-- Split `body` on top-level `|` (respecting nested parens) — extglob arms.
local function split_arms(body)
	local arms, depth, start, k, n = {}, 0, 1, 1, #body
	while k <= n do
		local ch = body:sub(k, k)
		if ch == "\\" then
			k = k + 2 -- a `\|` (quoted/escaped bar) is literal, not a separator
		elseif ch == "(" then
			depth = depth + 1
			k = k + 1
		elseif ch == ")" then
			depth = depth - 1
			k = k + 1
		elseif ch == "|" and depth == 0 then
			arms[#arms + 1] = body:sub(start, k - 1)
			start = k + 1
			k = k + 1
		else
			k = k + 1
		end
	end
	arms[#arms + 1] = body:sub(start)
	return arms
end
-- Convert a glob (incl. extglob ?(..) *(..) +(..) @(..) !(..)) to an ERE body.
local EXTOP = { ["?"] = true, ["*"] = true, ["+"] = true, ["@"] = true, ["!"] = true }
-- `pn` (pathname mode): `*`/`?` do NOT cross `/` (for GLOBIGNORE matching against
-- a whole path). Default (case globs, per-segment expansion) lets them match `/`.
-- `patsub` (only ${v/pat/repl} passes it): a bash quirk unique to the substitution
-- matcher — `]` right after `[^`/`[!` CLOSES an empty negated class (which matches
-- nothing), whereas #/%/case/glob treat that `]` as a literal member.
local function glob_conv(glob, pn, patsub)
	local star = pn and "[^/]*" or ".*"
	local qmark = pn and "[^/]" or "."
	local out, i, n = {}, 1, #glob
	while i <= n do
		local c = glob:sub(i, i)
		if EXTOP[c] and glob:sub(i + 1, i + 1) == "(" then
			local d, j = 1, i + 2
			while j <= n and d > 0 do
				local cc = glob:sub(j, j)
				if cc == "(" then
					d = d + 1
				elseif cc == ")" then
					d = d - 1
					if d == 0 then
						break
					end
				end
				j = j + 1
			end
			local arms = split_arms(glob:sub(i + 2, j - 1))
			local conv = {}
			for _, a in ipairs(arms) do
				conv[#conv + 1] = glob_conv(a, pn, patsub)
			end
			local group = "(" .. table.concat(conv, "|") .. ")"
			-- @ = exactly one; ? = 0/1; * = 0+; + = 1+; ! ≈ group (POSIX ERE can't negate)
			out[#out + 1] = (c == "?" and group .. "?")
				or (c == "*" and group .. "*")
				or (c == "+" and group .. "+")
				or group
			i = j + 1
		elseif c == "\\" then -- backslash escapes the next char -> match it literally
			local nc = glob:sub(i + 1, i + 1)
			-- Escape the char in the ERE ONLY if it is itself an ERE metacharacter. Emitting
			-- `\x` for a NON-metacharacter (e.g. `\'`, `` \` ``, `\<`) hits glibc's GNU regex
			-- extensions (`\'` = end-of-buffer anchor, …) and never matches — a plain char is
			-- already literal in an ERE, so pass it through. Fixes an unquoted `$v` glob like
			-- `*\'.txt` matching `x'.txt`.
			if nc == "" then
				out[#out + 1] = "\\\\"
				i = i + 1
			else
				out[#out + 1] = (nc:match("[%.%[%]%(%)%{%}%*%+%?%|%^%$\\]") and ("\\" .. nc) or nc)
				i = i + 2
			end
		elseif c == "*" then
			out[#out + 1] = star
			i = i + 1
		elseif c == "?" then
			out[#out + 1] = qmark
			i = i + 1
		elseif c == "[" then
			local j, neg, has_rb, members = i + 1, false, false, {}
			if glob:sub(j, j) == "!" or glob:sub(j, j) == "^" then
				neg = true
				j = j + 1
			end
			if patsub and neg and glob:sub(j, j) == "]" then
				-- `[^]`/`[!]` in the subst matcher: the `]` closes an EMPTY negated class,
				-- which matches nothing. Emit a never-match atom: a negated class of every
				-- non-NUL byte matches only NUL, which a shell (C-)string never contains.
				out[#out + 1] = "[^\1-\255]"
				i = j + 1
			else
				if glob:sub(j, j) == "]" then
					has_rb = true
					j = j + 1
				end -- leading ] is a literal member
				while j <= n and glob:sub(j, j) ~= "]" do
					local cj, nx = glob:sub(j, j), glob:sub(j + 1, j + 1)
					if cj == "\\" then -- inside [...], `\` escapes the next char (bash); `\]` is a literal ]
						if nx == "]" then
							has_rb = true
							j = j + 2
						elseif nx == "" then
							members[#members + 1] = "\\"
							j = j + 1
						else
							members[#members + 1] = nx
							j = j + 2
						end -- ERE: backslash isn't special in a class
					elseif cj == "[" and (nx == ":" or nx == "." or nx == "=") then
						-- POSIX [:class:] / [.coll.] / [=equiv=]: copy through its own close
						local e = glob:find(nx .. "]", j + 2, true)
						if e then
							members[#members + 1] = glob:sub(j, e + 1)
							j = e + 2
						else
							members[#members + 1] = cj
							j = j + 1
						end
					else
						members[#members + 1] = cj
						j = j + 1
					end
				end
				if glob:sub(j, j) ~= "]" then
					-- no closing ] : bash treats the `[` as a literal character (not a class)
					out[#out + 1] = "\\["
					i = i + 1
				else
					-- ERE class: a literal ] must come FIRST (right after [ or [^).
					out[#out + 1] = "[" .. (neg and "^" or "") .. (has_rb and "]" or "") .. table.concat(members) .. "]"
					i = j + 1
				end
			end
		elseif c:match("[%.%+%(%)%{%}%|%^%$\\]") then
			out[#out + 1] = "\\" .. c
			i = i + 1
		else
			out[#out + 1] = c
			i = i + 1
		end
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
	if ffi.C.regcomp(regbuf, ere, REG_EXTENDED + REG_NOSUB + (icase and REG_ICASE or 0)) ~= 0 then
		return false
	end
	local rc = ffi.C.regexec(regbuf, s, 0, nil, 0)
	ffi.C.regfree(regbuf)
	return rc == 0
end
local function split_alts(s) -- top-level `|` split (paren/bracket-aware)
	local alts, depth, cur, i, n = {}, 0, {}, 1, #s
	while i <= n do
		local c = s:sub(i, i)
		if c == "\\" then
			cur[#cur + 1] = s:sub(i, i + 1)
			i = i + 2
		elseif c == "(" or c == "[" then
			depth = depth + 1
			cur[#cur + 1] = c
			i = i + 1
		elseif c == ")" or c == "]" then
			depth = depth - 1
			cur[#cur + 1] = c
			i = i + 1
		elseif c == "|" and depth == 0 then
			alts[#alts + 1] = table.concat(cur)
			cur = {}
			i = i + 1
		else
			cur[#cur + 1] = c
			i = i + 1
		end
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
	local ceq = icase and function(a, b)
		return a:lower() == b:lower()
	end or function(a, b)
		return a == b
	end
	-- index of the `)` closing an extglob group whose op is at `gi` (`(` at gi+1)
	local function group_end(gi)
		local d, j = 1, gi + 2
		while j <= plen do
			local cc = pat:sub(j, j)
			if cc == "\\" then
				j = j + 2
			elseif cc == "(" then
				d = d + 1
				j = j + 1
			elseif cc == ")" then
				d = d - 1
				if d == 0 then
					return j
				end
				j = j + 1
			else
				j = j + 1
			end
		end
		return j
	end
	local m -- does pat[pi..] match str[si..slen] EXACTLY?
	m = function(si, pi)
		if pi > plen then
			return si > slen
		end
		local c, nc = pat:sub(pi, pi), pat:sub(pi + 1, pi + 1)
		if EXTOP[c] and nc == "(" then
			local ge = group_end(pi)
			local alts = split_alts(pat:sub(pi + 2, ge - 1))
			local rest = ge + 1
			local function altfull(seg)
				for _, a in ipairs(alts) do
					if M.ext_match(seg, a, icase) then
						return true
					end
				end
				return false
			end
			if c == "@" then
				for j = si - 1, slen do
					if altfull(str:sub(si, j)) and m(j + 1, rest) then
						return true
					end
				end
			elseif c == "?" then
				if m(si, rest) then
					return true
				end
				for j = si, slen do
					if altfull(str:sub(si, j)) and m(j + 1, rest) then
						return true
					end
				end
			elseif c == "!" then
				for j = si - 1, slen do
					if not altfull(str:sub(si, j)) and m(j + 1, rest) then
						return true
					end
				end
			else -- `*` (zero or more) or `+` (one or more)
				local function rep(pos, count)
					if (c == "*" or count >= 1) and m(pos, rest) then
						return true
					end
					for j = pos, slen do
						if altfull(str:sub(pos, j)) and rep(j + 1, count + 1) then
							return true
						end
					end
					return false
				end
				return rep(si, 0)
			end
			return false
		elseif c == "\\" then
			return si <= slen and ceq(str:sub(si, si), nc) and m(si + 1, pi + 2)
		elseif c == "*" then
			for j = si - 1, slen do
				if m(j + 1, pi + 1) then
					return true
				end
			end
			return false
		elseif c == "?" then
			return si <= slen and m(si + 1, pi + 1)
		elseif c == "[" then
			local j = pi + 1
			if pat:sub(j, j) == "!" or pat:sub(j, j) == "^" then
				j = j + 1
			end
			if pat:sub(j, j) == "]" then
				j = j + 1
			end
			while j <= plen and pat:sub(j, j) ~= "]" do
				j = j + 1
			end
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
		if c == "\\" then
			i = i + 2
		elseif c == "[" then -- skip a bracket expression: ] is literal right after [ or [^
			i = i + 1
			if ere:sub(i, i) == "^" then
				i = i + 1
			end
			if ere:sub(i, i) == "]" then
				i = i + 1
			end
			while i <= len and ere:sub(i, i) ~= "]" do
				i = i + 1
			end
			i = i + 1
		elseif c == "(" then
			n = n + 1
			i = i + 1
		else
			i = i + 1
		end
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
	if ffi.C.regcomp(regbuf, ere, REG_EXTENDED + (icase and REG_ICASE or 0)) ~= 0 then
		return nil, true
	end
	local rc = ffi.C.regexec(regbuf, s, NMATCH, pmatch, 0)
	ffi.C.regfree(regbuf)
	if rc ~= 0 then
		return nil
	end
	-- bash's BASH_REMATCH holds group 0 (whole) plus every capturing group, with
	-- non-participating groups as "" — so report up to re_nsub, not just the last
	-- group that happened to match.
	local hi = count_groups(ere)
	if hi > NMATCH - 1 then
		hi = NMATCH - 1
	end
	local caps = {}
	for i = 0, hi do
		local so = pmatch[i].rm_so
		caps[#caps + 1] = (so >= 0) and s:sub(so + 1, pmatch[i].rm_eo) or ""
	end
	return caps
end

-- Full (anchored) shell-glob match, for `case` patterns and [[ == ]].
function M.glob_match(s, glob, icase)
	if not icase then -- simple globs (no ?/[/extglob, ≤1 star) match with plain byte ops
		local kind, pre, post = simple_glob(glob)
		if kind == "" then
			return s == pre
		end -- literal
		if kind == "*" then -- pre*post
			return #s >= #pre + #post and s:sub(1, #pre) == pre and (post == "" or s:sub(#s - #post + 1) == post)
		end
	end
	if glob:find("!(", 1, true) then
		return M.ext_match(s, glob, icase)
	end -- !() needs the split matcher
	return M.regex_match(s, glob_to_ere(glob), icase)
end

local REG_NOTBOL = 1
-- ${v/pat/repl} and ${v//pat/repl}: substitute glob matches using the POSIX
-- regex engine (real char classes, extglob, leftmost-longest), not weak Lua
-- patterns. `all` replaces every match; a leading # / % on `glob` anchors the
-- match at the start / end. An empty pattern is a no-op (matches bash).
function M.subst_glob(val, glob, repl, all)
	local anchor
	if glob:sub(1, 1) == "#" then
		glob = glob:sub(2)
		anchor = "^"
	elseif glob:sub(1, 1) == "%" then
		glob = glob:sub(2)
		anchor = "$"
	end
	if glob == "" then -- empty pattern: no-op, except an anchored one inserts repl
		if anchor == "^" then
			return repl .. val
		elseif anchor == "$" then
			return val .. repl
		end
		return val
	end
	-- Literal pattern (no glob metachars): plain byte find/replace, no regex — the
	-- common `${x//-/_}` / `${x//,/ }` case (regex is left for real globs).
	if not glob:find("[%*%?%[\\]") and not glob:find("[@!+?*]%(") then
		local plen = #glob
		if anchor == "^" then
			return val:sub(1, plen) == glob and (repl .. val:sub(plen + 1)) or val
		elseif anchor == "$" then
			return val:sub(#val - plen + 1) == glob and (val:sub(1, #val - plen) .. repl) or val
		end
		local out, i = {}, 1
		while true do
			local s, e = val:find(glob, i, true)
			if not s then
				break
			end
			out[#out + 1] = val:sub(i, s - 1)
			out[#out + 1] = repl
			i = e + 1
			if not all then
				break
			end
		end
		out[#out + 1] = val:sub(i)
		return table.concat(out)
	end
	local ere = glob_conv(glob, false, true) -- patsub=true: [^]/[!] empty-negated quirk
	if anchor == "^" then
		ere = "^(" .. ere .. ")"
	elseif anchor == "$" then
		ere = "(" .. ere .. ")$"
	else
		ere = "(" .. ere .. ")"
	end
	if ffi.C.regcomp(regbuf, ere, REG_EXTENDED) ~= 0 then
		return val
	end
	local out, pos, n, prev_end = {}, 0, #val, -1
	while pos <= n do
		local sub = val:sub(pos + 1)
		if ffi.C.regexec(regbuf, sub, 1, pmatch, pos > 0 and REG_NOTBOL or 0) ~= 0 then
			break
		end
		local so, eo = pmatch[0].rm_so, pmatch[0].rm_eo
		if eo == so and pos + so == prev_end then
			-- an EMPTY match right where the previous match ended (e.g. `.*` matched to
			-- the end, then matches empty again): don't replace, just carry one char.
			out[#out + 1] = sub:sub(1, so + 1)
			pos = pos + so + 1
		else
			out[#out + 1] = sub:sub(1, so) -- text before the match
			out[#out + 1] = repl
			prev_end = pos + eo
			if eo > so then
				pos = pos + eo
			else
				out[#out + 1] = sub:sub(eo + 1, eo + 1)
				pos = pos + eo + 1
			end -- empty match: keep one char
			if not all or anchor then
				out[#out + 1] = val:sub(pos + 1)
				ffi.C.regfree(regbuf)
				return table.concat(out)
			end
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
	local d = ffi.C.opendir(scan)
	if d == nil then
		return {}
	end
	-- a `!()` segment needs the split matcher (per entry); everything else uses one
	-- precompiled ERE.
	local neg = seg:find("!(", 1, true) ~= nil
	if not neg then
		if ffi.C.regcomp(regbuf, glob_to_ere(seg), REG_EXTENDED + REG_NOSUB) ~= 0 then
			ffi.C.closedir(d)
			return {}
		end
	end
	local hidden = seg:sub(1, 1) == "."
	skipdots = skipdots ~= false -- default: skip . and .. (globskipdots on)
	local out = {}
	while true do
		local e = ffi.C.readdir(d)
		if e == nil then
			break
		end
		local name = ffi.string(ffi.cast("const char *", e) + 19) -- d_name @ 19 (glibc x86-64)
		-- . and .. are matched only by an explicit leading-dot pattern with
		-- globskipdots off; a leading-dot name otherwise needs `.`-pattern or dotglob.
		local dotdot = name == "." or name == ".."
		if (not dotdot or (not skipdots and hidden)) and (name:sub(1, 1) ~= "." or hidden or dotglob) then
			local m
			if neg then
				m = M.ext_match(name, seg) -- (explicit if: a false ext_match must NOT fall to regexec on an uncompiled regbuf)
			else
				m = ffi.C.regexec(regbuf, name, 0, nil, 0) == 0
			end
			if m then
				out[#out + 1] = name
			end
		end
	end
	if not neg then
		ffi.C.regfree(regbuf)
	end
	ffi.C.closedir(d)
	return out
end

local stbuf_g = ffi.new("uint8_t[144]")
local function is_dir(path)
	if ffi.C.curse_rt_stat(path == "" and "." or path, stbuf_g) ~= 0 then
		return false
	end
	return bit.band(ffi.cast("uint32_t *", stbuf_g + 24)[0], 0xF000) == 0x4000
end
-- globstar `**`: every directory at or under `base` (recursively), including base
-- itself (the zero-level case) — the prefixes an intermediate `**/` descends into.
local function rec_dirs(base, dotglob)
	local out = { base }
	local d = ffi.C.opendir(base == "" and "." or base)
	if d == nil then
		return out
	end
	while true do
		local e = ffi.C.readdir(d)
		if e == nil then
			break
		end
		local name = ffi.string(ffi.cast("const char *", e) + 19)
		if name ~= "." and name ~= ".." and (name:sub(1, 1) ~= "." or dotglob) then
			local path = base == "" and name or (base == "/" and "/" .. name or base .. "/" .. name)
			if is_dir(path) then
				for _, sd in ipairs(rec_dirs(path, dotglob)) do
					out[#out + 1] = sd
				end
			end
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
	if not (pattern:find("[*?%[]") or pattern:find("[?*+@!]%(")) then
		return nil
	end
	local abs = pattern:sub(1, 1) == "/"
	local segs = {}
	for s in pattern:gmatch("[^/]+") do
		segs[#segs + 1] = s
	end
	if #segs == 0 then
		return nil
	end
	local cur = { abs and "/" or "" } -- accumulated path prefixes (dir, "" == cwd)
	for si, seg in ipairs(segs) do
		local isglob = seg:find("[*?%[]") or seg:find("[?*+@!]%(")
		local islast = si == #segs
		local nxt = {}
		local function joined(base, name)
			if base == "" then
				return name
			elseif base == "/" then
				return "/" .. name
			else
				return base .. "/" .. name
			end
		end
		if seg == "**" and opts.globstar and not islast then
			-- an intermediate `**/` matches zero or more directory levels
			for _, base in ipairs(cur) do
				for _, dir in ipairs(rec_dirs(base, opts.dotglob)) do
					nxt[#nxt + 1] = dir
				end
			end
		elseif not isglob then
			-- literal segment: append; a nonexistent intermediate dir yields nothing
			-- next round (opendir fails), so no explicit stat needed.
			for _, base in ipairs(cur) do
				nxt[#nxt + 1] = joined(base, seg)
			end
		else
			for _, base in ipairs(cur) do
				local hits = scan_seg(base, seg, opts.dotglob, opts.skipdots)
				table.sort(hits, M.coll_lt) -- glob results sort by LC_COLLATE (bash)
				for _, name in ipairs(hits) do
					nxt[#nxt + 1] = joined(base, name)
				end
			end
		end
		cur = nxt
		if #cur == 0 then
			return nil
		end
	end
	if #cur == 0 then
		return nil
	end
	table.sort(cur, M.coll_lt)
	-- dedup: multiple `**` segments can reach the same path more than once
	local seen, dedup = {}, {}
	for _, p in ipairs(cur) do
		if not seen[p] then
			seen[p] = true
			dedup[#dedup + 1] = p
		end
	end
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
		local ifsset = {}
		for _, ch in ipairs(M.mb_chars(ifs)) do
			ifsset[ch.s] = true
		end
		local mbifs = M.lc_mb_cur_max() > 1 and ifs:find("[\128-\255]") ~= nil
		local function isws(c)
			return c == " " or c == "\t" or c == "\n"
		end
		local function inifs(c)
			return c ~= "" and ifsset[c]
		end
		local function clen(v, i)
			if not mbifs or v:byte(i) < 0x80 then
				return 1
			end
			return M.mb_charlen(v, i)
		end
		local cur = nil
		local function brk()
			if cur ~= nil then
				fields[#fields + 1] = cur
				cur = nil
			end
		end
		local v = value
		local i, n = 1, #v
		while i <= n do
			local cl = clen(v, i)
			local c = cl == 1 and v:sub(i, i) or v:sub(i, i + cl - 1)
			if inifs(c) then
				if isws(c) then
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
				else
					if cur == nil then
						cur = ""
					end
					brk()
					i = i + cl
					while i <= n and isws(v:sub(i, i)) do
						i = i + 1
					end
				end
			else
				cur = (cur or "") .. c
				i = i + cl
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
			if c == "[" then
				depth = depth + 1
				curp[#curp + 1] = c
			elseif c == "]" then
				if depth > 0 then
					depth = depth - 1
				end
				curp[#curp + 1] = c
			elseif c == ":" and depth == 0 then
				if #curp > 0 then
					gipats[#gipats + 1] = table.concat(curp)
					curp = {}
				end
			else
				curp[#curp + 1] = c
			end
		end
		if #curp > 0 then
			gipats[#gipats + 1] = table.concat(curp)
		end
	end
	local noglob = sh.opt_f -- set -f: pathname expansion disabled
	-- globskipdots defaults ON, globstar defaults OFF (SHOPT_DEFAULT, interp.lua).
	local skipdots = giset or (sh.shopt.globskipdots ~= false)
	local globstar = sh.shopt.globstar and true
	-- bash glob_pattern_p: `[` is a metacharacter only when a later `]` closes it
	-- (a lone `[` stays literal — no directory scan); `\c` escapes the next char.
	-- Matches glob_conv's own "no closing ] → literal [" so we never scan for a
	-- pattern that will expand to a literal.
	local function glob_active(s)
		local i, n, open = 1, #s, false
		while i <= n do
			local c = s:sub(i, i)
			if c == "\\" then
				i = i + 2
			elseif c == "*" or c == "?" then
				return true
			elseif c == "[" then
				open = true
				i = i + 1
			elseif c == "]" then
				if open then
					return true
				end
				i = i + 1
			elseif (c == "+" or c == "@" or c == "!") and s:sub(i + 1, i + 1) == "(" then
				return true
			else
				i = i + 1
			end
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
					for _, gp in ipairs(gipats) do
						if M.glob_ignore_match(x, gp) then
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
			elseif sh.shopt.failglob then
				io.stderr:write("curse: no match: " .. s .. "\n")
				error({ __curse_exit = 1, __curse_lineabort = true })
			elseif nullglob then -- drop
			else
				out[#out + 1] = s
			end
		else
			out[#out + 1] = s
		end
	end
	return out
end

-- Mask-aware field split + glob for a MIXED word (`foo$x`, `x=$i`, `$?.txt`) — the
-- genuine-compilation replacement for interp's expand_to_fields on that shape. Emit
-- compiles each part's VALUE into a segment {s=<value>, split, unq}:
--   split=true              value came from an UNQUOTED expansion ($x/$?/param) —
--                           word-split on $IFS, then glob each field (glob-active).
--   split=false, unq=true   an UNQUOTED literal (`*.txt`) — no split, but glob-active.
--   split=false, unq=false  QUOTED/escaped text — literal (no split, no glob).
-- We rebuild the field left to right with a per-char quote mask (`q`: "0"=glob-active,
-- "1"=masked) so `"$x"foo*` globs foo* but not $x's content. $@/$*/array (multi-
-- element) parts are NOT in this subset — those stay on expand_to_fields. Kept
-- byte-for-byte in lockstep with expand_to_fields' feed_split/add + glob tail.
function M.expand_fields(sh, segs)
	local ifs = sh.vars["IFS"] and sh:get("IFS") or " \t\n"
	-- Memoize the IFS char-set parse (shared with expand_to_fields via sh._ifscache).
	local ic = sh._ifscache
	if not ic or ic.ifs ~= ifs then
		local set = {}
		for _, ch in ipairs(M.mb_chars(ifs)) do
			set[ch.s] = true
		end
		ic = { ifs = ifs, set = set, mbifs = M.lc_mb_cur_max() > 1 and ifs:find("[\128-\255]") ~= nil }
		sh._ifscache = ic
	end
	local ifsset, mbifs = ic.set, ic.mbifs
	local function isws(c)
		return c == " " or c == "\t" or c == "\n"
	end
	local function inifs(c)
		return c ~= "" and ifsset[c]
	end
	local function clen(v, i)
		if not mbifs or v:byte(i) < 0x80 then
			return 1
		end
		return M.mb_charlen(v, i)
	end
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
				if isws(c) then
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
				else
					if cur == nil then
						cur = ""
					end
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
	for _, seg in ipairs(segs) do
		if seg.multi then
			-- a $@ / $* part: multiple elements (seg.elems), joined/split per bash. Quoted
			-- "$@" is one field PER element (each concatenates with the abutting text — the
			-- first with what precedes, the last with what follows); quoted "$*" joins on
			-- IFS[0]; unquoted joins on IFS[0] then word-splits (per-element under IFS="").
			local els = seg.elems
			if seg.q then
				if seg.star then
					add(table.concat(els, ifs:sub(1, 1)), false)
				else
					for k = 1, #els do
						if k > 1 then
							brk()
						end
						add(els[k], false)
					end
				end
			elseif ifs == "" then
				for k = 1, #els do
					if k > 1 then
						brk()
					end
					feed_split(els[k])
				end
			else
				feed_split(table.concat(els, ifs:sub(1, 1)))
			end
		elseif seg.split then
			feed_split(seg.s)
		else
			add(seg.s, seg.unq)
		end
	end
	brk()
	-- pathname expansion on fields with unquoted glob metacharacters (mask-aware)
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
			if c == "[" then
				depth = depth + 1
				curp[#curp + 1] = c
			elseif c == "]" then
				if depth > 0 then
					depth = depth - 1
				end
				curp[#curp + 1] = c
			elseif c == ":" and depth == 0 then
				if #curp > 0 then
					gipats[#gipats + 1] = table.concat(curp)
					curp = {}
				end
			else
				curp[#curp + 1] = c
			end
		end
		if #curp > 0 then
			gipats[#gipats + 1] = table.concat(curp)
		end
	end
	local noglob = sh.opt_f
	local skipdots = giset or (sh.shopt.globskipdots ~= false)
	local globstar = sh.shopt.globstar and true
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
	}
	local function glob_active(f) -- glob metachar at a NON-masked (glob-active) position?
		local s, q = f.s, f.q
		local open = false
		for i = 1, #s do
			if not q or q:sub(i, i) == "0" then
				local c = s:sub(i, i)
				if c == "*" or c == "?" then
					return true
				end
				if c == "[" then
					open = true
				elseif c == "]" then
					if open then
						return true
					end
				elseif
					(c == "+" or c == "@" or c == "!")
					and s:sub(i + 1, i + 1) == "("
					and (not q or q:sub(i + 1, i + 1) == "0")
				then
					return true
				end
			end
		end
		return false
	end
	local function glob_pat(f) -- backslash-escape masked (quoted) glob-special chars
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
			local m = M.glob_expand(glob_pat(f), { dotglob = dotglob, skipdots = skipdots, globstar = globstar })
			if m and gipats then
				local filt = {}
				for _, x in ipairs(m) do
					local ig = false
					for _, p in ipairs(gipats) do
						if M.glob_ignore_match(x, p) then
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
			elseif sh.shopt.failglob then
				io.stderr:write("curse: no match: " .. f.s .. "\n")
				error({ __curse_exit = 1, __curse_lineabort = true })
			elseif nullglob then -- drop
			else
				out[#out + 1] = f.s
			end
		else
			out[#out + 1] = f.s
		end
	end
	return out
end

-- Compile-tier array literal (`a=(1 2 3)`, `a=($x)`, `a=([0]=x [k]=v)`, `a+=(…)`, `a=()`):
-- emit has already expanded the elements into `items` in order — a BARE element is one
-- or more {val=field} (field engine), a KEYED element is {key=<literal subscript>, op, val}
-- (emit gates keyed to literal keys, so the subscript needs no word engine). This does
-- exactly do_arrayassign's storage (interp.lua): assoc `[k]+=` in a `=` literal appends to
-- the PRE-statement value (snap); a literal key resolves natively (assoc verbatim, indexed
-- via arith_str); reset unless appending; assoc all-bare = alternating key/value pairs;
-- indexed = auto-index from 0 (or max+1 appending, scalar->[0]); then drop from the env.
function M.arrayassign(sh, name, items, append)
	local rb = sh.vars[sh:deref(name)]
	if rb and rb.ro then
		io.stderr:write("curse: " .. name .. ": readonly variable\n")
		sh.status = 1
		return
	end
	local isassoc = sh:is_assoc(name)
	local anykeyed = false
	for _, it in ipairs(items) do
		if it.key ~= nil then
			anykeyed = true
			break
		end
	end
	local function keyof(kt)
		return isassoc and kt or M.to_arr_key(M.arith_str(sh, kt))
	end
	local snap
	if not append then -- plain assignment resets the array (keeps assoc-ness)
		local b = sh.vars[name]
		if isassoc then
			snap = b and b.arr or nil
		end -- assoc `[k]+=` reads the pre-clear value
		if not b then
			sh:array_assign(name, {}, false)
			b = sh.vars[name]
		end
		b.arr = {}
		b.s = nil
		b.n = nil
		b.empty_decl = nil
		if isassoc then
			b.order = {}
		end
	end
	if isassoc then
		if anykeyed then -- keyed elements assigned; bare ones are an error in bash (skip)
			for _, it in ipairs(items) do
				if it.key ~= nil then
					local idx = keyof(it.key)
					if it.op == "+=" and not append then
						sh:array_set(name, idx, (snap and snap[idx] or "") .. it.val, false)
					else
						sh:array_set(name, idx, it.val, it.op == "+=")
					end
				end
			end
		else -- all-bare assoc literal: alternating key value pairs
			for k = 1, #items, 2 do
				sh:array_set(name, items[k].val, items[k + 1] and items[k + 1].val or "", false)
			end
		end
	else
		local auto = 0
		if append then
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
				local idx = keyof(it.key)
				sh:array_set(name, idx, it.val, it.op == "+=")
				auto = idx + 1 -- indexed += appends to CURRENT
			else
				sh:array_set(name, auto, it.val, false)
				auto = auto + 1
			end
		end
	end
	local b = sh.vars[name]
	if b and b.exported then
		C.unsetenv(name)
	end -- an array can't live in the process env
	sh.status = 0
	sh:set_str("_", "")
end

-- Single array-element assignment `a[i]=v` / `a[i]+=v` for the compiled tier — mirrors interp's
-- assign path (the st.index branch). `key_expanded` is the subscript already word-expanded
-- (emit_word, == interp's array_key for assoc); for an INDEXED array it is arith-evaluated
-- (to_arr_key(arith_str)). Readonly -> reject (status 1, line-abort like interp); a bad
-- subscript (negative out of range) -> status 1, non-fatal. Gated at emit to non-nameref
-- programs and a non-empty, emit_word-able subscript.
function M.assign_element(sh, name, raw, expanded, value, append)
	local rb = sh.vars[sh:deref(name)]
	if rb and rb.ro then
		io.stderr:write("curse: " .. name .. ": readonly variable\n")
		sh.status = 1
		if sh.opt_c or sh.opt_posix then
			error({ __curse_exit = 1 })
		end
		if sh.applying_prefix then
			return
		end
		error({ __curse_exit = 1, __curse_lineabort = true })
	end
	-- array_key: an ASSOC uses the word-expanded subscript verbatim; an INDEXED array
	-- arith-evaluates the RAW subscript (so `a['3']=` is the syntax error bash reports,
	-- while emit_word would have stripped the quotes), exactly interp's array_key.
	local key
	if sh:is_assoc(name) then
		key = expanded
	elseif raw:match("^%s*$") then
		key = 0
	else
		local ok, v = pcall(function()
			return M.to_arr_key(M.arith_str(sh, raw))
		end)
		if not ok then
			io.stderr:write("curse: " .. raw .. ": syntax error in expression\n")
			sh.status = 1
			return
		end
		key = v
	end
	if not sh:array_set(name, key, value, append) then
		io.stderr:write("curse: " .. name .. ": bad array subscript\n")
		sh.status = 1
		sh.assign_err = true
		return
	end
	sh:set_str("_", "") -- a bare assignment resets $_ (bash); status stays the RHS's (emit set 0 first)
end

-- Shared readonly guard for the compiled element-assign paths (assign_element_i / _x). Returns
-- true if the assignment must be ABORTED (name is readonly) — the caller then returns; raises for
-- the fatal (posix / -c / non-prefix) cases exactly like assign_element.
local function elem_readonly_abort(sh, name)
	local rb = sh.vars[sh:deref(name)]
	if not (rb and rb.ro) then
		return false
	end
	io.stderr:write("curse: " .. name .. ": readonly variable\n")
	sh.status = 1
	if sh.opt_c or sh.opt_posix then
		error({ __curse_exit = 1 })
	end
	if sh.applying_prefix then
		return true
	end
	error({ __curse_exit = 1, __curse_lineabort = true })
end
-- INDEXED element assign with the key ALREADY arith-evaluated NATIVELY by the compiled tier
-- (from lifted locals, so a loop variable is CURRENT — arith_str(sh, raw) would read the stale
-- sh.vars copy). `keyi` is the int64 arith value; only reached for a non-assoc array (the emitter
-- gates on is_assoc). Bug fixed: `a[i]=…` in a `for ((;;))` loop with a lifted `i`.
function M.assign_element_i(sh, name, keyi, value, append)
	if elem_readonly_abort(sh, name) then
		return
	end
	if not sh:array_set(name, to_arr_key(keyi), value, append) then
		io.stderr:write("curse: " .. name .. ": bad array subscript\n")
		sh.status = 1
		sh.assign_err = true
		return
	end
	sh:set_str("_", "")
end
-- Element assign whose subscript is a WORD EXPANSION (`a[$i]=…`): `src` is the ALREADY
-- word-expanded subscript value (built by emit_word, so it reads lifted locals). An assoc uses
-- it verbatim as the key; an indexed array arith-evaluates it (with the same error handling as
-- assign_element) — arith'ing the VALUE, not the raw `$i`, so a lifted loop var is current.
function M.assign_element_x(sh, name, src, value, append)
	if elem_readonly_abort(sh, name) then
		return
	end
	local key
	if sh:is_assoc(name) then
		key = src
	elseif src:match("^%s*$") then
		key = 0
	else
		local ok, v = pcall(M.arith_str, sh, src)
		if not ok then
			io.stderr:write("curse: " .. src .. ": syntax error in expression\n")
			sh.status = 1
			return
		end
		key = to_arr_key(v)
	end
	if not sh:array_set(name, key, value, append) then
		io.stderr:write("curse: " .. name .. ": bad array subscript\n")
		sh.status = 1
		sh.assign_err = true
		return
	end
	sh:set_str("_", "")
end

-- Resolve a subscript to its array KEY for the compiled tier, exactly like assign_element /
-- interp's array_key: an ASSOC uses the word-expanded subscript (`expanded`, built by emit_word
-- for the caller); an INDEXED array arith-evaluates the RAW subscript (empty -> 0). A subscript
-- arith syntax error (`${a['3']}`) becomes the tier's non-fatal lineabort (interp's experr).
function M.array_key(sh, name, raw, expanded)
	if sh:is_assoc(name) then
		return expanded
	end
	if raw:match("^%s*$") then
		return 0
	end
	local ok, v = pcall(function()
		return M.to_arr_key(M.arith_str(sh, raw))
	end)
	if not ok then
		io.stderr:write("curse: " .. raw .. ": syntax error in expression\n")
		error({ __curse_exit = 1, __curse_lineabort = true })
	end
	return v
end

-- Scalar `name+=value` (non-index) for the compiled tier, exactly interp's append path: an
-- ARRAY var appends value to element 0, an INTEGER var (declare -i) arithmetic-adds it, and a
-- plain/unset scalar string-concatenates. A readonly var is rejected (status 1, line-abort like
-- a standalone assignment). Gated at emit to non-nameref programs with an emit_word-able rhs.
function M.append_scalar(sh, name, value)
	local b = sh.vars[sh:deref(name)]
	if b and b.ro then
		io.stderr:write("curse: " .. name .. ": readonly variable\n")
		sh.status = 1
		if sh.opt_c or sh.opt_posix then
			error({ __curse_exit = 1 })
		end
		error({ __curse_exit = 1, __curse_lineabort = true })
	end
	if b and b.arr then
		sh:array_set(name, require("interp")._int.array_key(sh, name, "0"), value, true)
	elseif b and b.int then
		sh:aset(name, sh:aget(name) + M.arith_str(sh, value))
	else
		sh:set_str(name, sh:get(name) .. value)
	end
end

-- Read a scalar array/assoc ELEMENT ${name[sub]} (op=nil) for the compiled tier: resolve the
-- key, then defer to Shell:expand_param — the SAME element read + set -u nounset + isset path
-- the interpreter uses, so the value matches exactly.
function M.array_elem(sh, name, raw, expanded)
	return sh:expand_param({ name = name, index = raw }, nil, nil, M.array_key(sh, name, raw, expanded))
end

-- Read an array/assoc ELEMENT in ARITHMETIC context (`$(( a[i] ))`), exactly interp's arith
-- var-with-idx path (interp.lua ~448): a set -u check on the BASE var (arith_nounset — FATAL
-- for an unset base, but an unset ELEMENT of a set array reads as 0), then arith_resolve the
-- element value recursively (a[0]="x+1" -> x+1). A non-numeric element ("12 34") is a NON-fatal
-- syntax error: arith_resolve prints the exact message and raises experr, which is converted to
-- the tier's lineabort so run_compiled contains it (status 1, abort line, continue).
function M.arith_read_elem(sh, name, raw, expanded)
	local I = require("interp")._int
	I.arith_nounset(sh, name) -- fatal if the base var is unset under set -u (outside the pcall)
	local ok, v = pcall(I.arith_resolve, sh, sh:array_get(name, M.array_key(sh, name, raw, expanded)))
	if ok then
		return v
	end
	if type(v) == "table" and (v.__curse_experr or v.__curse_matherr) and not v.__curse_lineabort then
		error({ __curse_exit = v.__curse_exit or 1, __curse_lineabort = true })
	end
	error(v)
end

-- WRITE an array/assoc element in ARITHMETIC context (`(( a[i] = e ))`, `(( a[i] += e ))`).
-- Resolve the key ONCE (so a subscript side effect runs once), read the current element only
-- when the op reads it first (`read_first` for a compound assignment; a plain `=` does not,
-- and so takes no set -u nounset — writing an unset base creates it), then `compute(old)` (the
-- caller's closure, which applies the operator via emit_value) gives the new int64; store it.
function M.arith_elem_write(sh, name, raw, expanded, read_first, compute)
	if read_first then
		require("interp")._int.arith_nounset(sh, name)
	end
	local key = M.array_key(sh, name, raw, expanded)
	local old = read_first and M.arith_str(sh, sh:array_get(name, key) or "") or nil
	local v = compute(old)
	sh:array_set(name, key, M.i64_to_str(v))
	return v
end

-- ++a[i] / a[i]++ (and --): read the element (nounset on the base), store old±1, return the
-- OLD value for post or the NEW value for pre.
function M.arith_elem_incr(sh, name, raw, expanded, delta, is_post)
	require("interp")._int.arith_nounset(sh, name)
	local key = M.array_key(sh, name, raw, expanded)
	local old = M.arith_str(sh, sh:array_get(name, key) or "")
	sh:array_set(name, key, M.i64_to_str(old + delta))
	if is_post then
		return old
	end
	return old + delta
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
	if op == "prefix" then
		return table.concat(self:var_prefix_names(name), " ")
	end
	-- ${!name}: indirect. For a nameref, bash INVERTS this to yield the target NAME;
	-- otherwise it's the value of the variable named by $name.
	if op == "indirect" then
		local b = self.vars[name]
		if b and b.ref and b.s then
			return b.s
		end
		local target = idxnum and self:array_get(name, idxnum) or self:get(name)
		target = target:gsub("%[.*$", "") -- plain-var target (subscript targets rare)
		if target == "" then
			return ""
		end
		if target == "@" or target == "*" then
			return self:paramsJoin(" ")
		end
		if target:match("^%d+$") then
			return self:param(tonumber(target))
		end
		if target == "?" then
			return tostring(self.status)
		end
		return self:get(target)
	end
	local val, isset
	if index == "@" or index == "*" then
		if op == "len" then
			return tostring(self:array_count(name))
		end -- ${#a[@]}
		val = table.concat(self:array_values(name), " ")
		isset = self:array_count(name) > 0
	elseif index then
		-- set-ness (for the no-colon - / + ops) is PRESENCE, not non-emptiness: an
		-- element holding "" is set, so ${a[0]-def} with a=("") yields "" not def.
		val = self:array_get(name, idxnum or 0)
		isset = self:is_elem_set(name, idxnum or 0)
	elseif name:match("^%d+$") then
		local nn = tonumber(name)
		val = self:param(nn)
		isset = (nn <= self.nparams)
	elseif name == "@" or name == "*" then
		val = self:paramsJoin(" ")
		isset = self.nparams > 0
	else
		-- "set" means it actually holds a value: a declared-but-valueless var (declare x)
		-- and an EMPTY array (whose [0] is unset) are NOT set, so ${x-default} yields the
		-- default (bash), even though declare -p lists them.
		local b = self.vars[self:deref(name)]
		if b and b.arr then
			isset = b.arr[0] ~= nil or b.arr["0"] ~= nil
		else
			isset = b ~= nil and (b.s ~= nil or b.n ~= nil)
		end
		isset = isset or self:special_get(name) ~= ""
		val = self:get(name)
	end
	-- The default/alternate word for the test ops arrives as a thunk (lazy: only
	-- expanded when its branch is taken, so a side-effecting default runs at most once).
	local function A()
		if type(arg) == "function" then
			return arg()
		end
		return arg or ""
	end
	-- set -u (nounset): a bare reference to an unset variable errors and exits. The
	-- unset-handling ops (:- - :+ + := = :? ?) and $@/$* are exempt.
	if
		self.opt_u
		and not isset
		and not (name == "@" or name == "*")
		and index ~= "@"
		and index ~= "*"
		and op ~= ":-"
		and op ~= "-"
		and op ~= ":+"
		and op ~= "+"
		and op ~= ":="
		and op ~= "="
		and op ~= ":?"
		and op ~= "?"
		and self:special_get(name) == ""
	then
		io.stderr:write("curse: " .. name .. ": unbound variable\n")
		error({ __curse_exit = self.opt_c and 127 or 1, __curse_lineabort = self.opt_i or nil })
	end
	-- := / = write back to the SAME target that was read: an array element when
	-- subscripted (${a[0]=x} must populate a[0]), else the scalar variable.
	local function assign_default(v)
		if index and index ~= "@" and index ~= "*" then
			self:array_set(name, idxnum or 0, v)
		else
			-- a bare name that IS an array writes element 0 (bash), not a scalar shadow
			local b = self.vars[self:deref(name)]
			if b and b.arr then
				self:array_set(name, 0, v)
			else
				self:set_str(name, v)
			end
		end
	end
	if op == "len" then
		return tostring(M.mb_strlen(val))
	end -- ${#v}: codepoints in the locale
	if op == ":-" then
		return val ~= "" and val or A()
	end
	if op == "-" then
		return isset and val or A()
	end
	if op == ":+" then
		return val ~= "" and A() or ""
	end
	if op == "+" then
		return isset and A() or ""
	end
	if op == ":=" then
		if val == "" then
			local v = A()
			assign_default(v)
			return v
		end
		return val
	end
	if op == "=" then
		if not isset then
			local v = A()
			assign_default(v)
			return v
		end
		return val
	end
	if op == ":?" then
		if val == "" then
			io.stderr:write("curse: " .. name .. ": " .. A() .. "\n")
			error({ __curse_exit = self.opt_c and 127 or 1, __curse_lineabort = self.opt_i or nil })
		end
		return val
	end
	if op == "?" then
		if not isset then
			io.stderr:write("curse: " .. name .. ": " .. A() .. "\n")
			error({ __curse_exit = self.opt_c and 127 or 1, __curse_lineabort = self.opt_i or nil })
		end
		return val
	end
	arg = arg or ""
	if op == "@" then -- ${x@OP} transforms
		-- @a reports the VARIABLE's attributes (e.g. `A` for a declared assoc array),
		-- so it's non-empty even when the scalar view (a[0]) is unset; the other
		-- transforms yield empty on an unset var.
		if arg == "a" then
			return self:attr_string(name)
		end
		if not isset then
			return ""
		end
		if arg == "A" then
			return name .. "=" .. M.shell_quote(val)
		end -- declare-able form
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
	if self.opt_a then
		s = s .. "a"
	end
	if self.opt_b then
		s = s .. "b"
	end
	if self.opt_e then
		s = s .. "e"
	end
	if self.opt_f then
		s = s .. "f"
	end
	s = s .. "h"
	if self.opt_k then
		s = s .. "k"
	end
	if self.opt_m then
		s = s .. "m"
	end
	if self.opt_n then
		s = s .. "n"
	end
	if self.opt_u then
		s = s .. "u"
	end
	if self.opt_v then
		s = s .. "v"
	end
	if self.opt_x then
		s = s .. "x"
	end
	s = s .. "B"
	if self.opt_C then
		s = s .. "C"
	end
	if self.opt_i then
		s = s .. "i"
	end
	if self.opt_c then
		s = s .. "c"
	end
	return s
end

-- System hostname (for \h/\H): $HOSTNAME if set, else /proc/sys/kernel/hostname.
local _hostname
function M.hostname()
	if _hostname then
		return _hostname
	end
	_hostname = os.getenv("HOSTNAME")
	if not _hostname or _hostname == "" then
		local f = io.open("/proc/sys/kernel/hostname", "r")
		if f then
			_hostname = (f:read("*l") or ""):gsub("%s+$", "")
			f:close()
		end
	end
	if not _hostname or _hostname == "" then
		_hostname = "localhost"
	end
	return _hostname
end
function Shell:prompt_escapes(s)
	local out, i, n = {}, 1, #s
	while i <= n do
		local c = s:sub(i, i)
		if c == "\\" then
			local d = s:sub(i + 1, i + 1)
			local simple = ({
				a = "\7",
				e = "\27",
				n = "\n",
				r = "\r",
				["\\"] = "\\",
				["$"] = (self:special_get("EUID") == "0" and "#" or "$"),
				t = os.date("%H:%M:%S"),
				T = os.date("%I:%M:%S"),
				["@"] = os.date("%I:%M %p"),
				A = os.date("%H:%M"),
				d = os.date("%a %b %d"),
				s = self.shellname or "bash",
				v = "5.2",
				V = "5.2.0",
				["!"] = "1",
				["#"] = "1",
				j = "0",
			})[d]
			if d == "[" or d == "]" then
				i = i + 2 -- non-printing markers: drop
			elseif d == "l" then -- basename of the controlling tty, or "tty" when none (bash)
				local tn = C.isatty(0) == 1 and C.ttyname(0) or nil
				out[#out + 1] = tn ~= nil and (ffi.string(tn):gsub(".*/", "")) or "tty"
				i = i + 2
			elseif d == "w" then
				out[#out + 1] = self:pwd()
				i = i + 2
			elseif d == "W" then
				out[#out + 1] = (self:pwd():gsub(".*/", ""))
				i = i + 2
			elseif d == "u" then
				out[#out + 1] = os.getenv("USER") or "user"
				i = i + 2
			elseif d == "h" then
				out[#out + 1] = M.hostname():gsub("%..*$", "")
				i = i + 2
			elseif d == "H" then
				out[#out + 1] = M.hostname()
				i = i + 2
			elseif d == "D" and s:sub(i + 2, i + 2) == "{" then -- \D{strftime}
				local close = s:find("}", i + 3, true)
				local fmt = s:sub(i + 3, (close or i + 2) - 1)
				out[#out + 1] = os.date(fmt ~= "" and fmt or "%X")
				i = (close or i + 2) + 1
			elseif simple then
				out[#out + 1] = simple
				i = i + 2
			elseif d:match("[0-7]") then
				local oct = s:match("^[0-7][0-7]?[0-7]?", i + 1)
				out[#out + 1] = string.char(tonumber(oct, 8) % 256)
				i = i + 1 + #oct
			else
				out[#out + 1] = "\\" .. d
				i = i + 2
			end -- unknown escape kept literal
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	return table.concat(out)
end

-- The per-value string-transform operators (pattern strip, substitute, substring,
-- case, and the ${x@OP} transforms). Factored out so ${a[@]OP} can apply per element.
-- Case-fold `val` per the ${x^PAT}/${x,,PAT} rules: `upper` picks the direction,
-- `all` folds every matching char (else only the first). An empty PAT means "any".
local function fold_case(val, pat, upper, all)
	if pat == nil or pat == "" then
		pat = "?"
	end
	-- `?` (the default, `${x^^}`/`${x,,}` with no pattern) matches EVERY single char,
	-- so skip the per-char glob_match — it would regcomp once per character (ruinous
	-- in a loop). Only a real pattern (`${x^[a-z]}`) needs the match test.
	local any = (pat == "?")
	-- ASCII/single-byte fast path: with the default `?` (fold every char) in a
	-- single-byte locale, folding is exactly string.upper/lower (Lua's toupper/tolower
	-- is the same locale-aware per-byte fold) — no mb_chars char-table, no per-char
	-- loop, no allocation. This is the common `${x^^}`/`${x,,}` case.
	if lc_mb_cur_max <= 1 and any then
		local f = upper and string.upper or string.lower
		if all then
			return f(val)
		end
		if val == "" then
			return val
		end
		return f(val:sub(1, 1)) .. val:sub(2)
	end
	-- Fold per CHARACTER (codepoint) using the locale's towupper/towlower, exactly
	-- as bash does — so `${x^^}` upcases μ→Μ under a UTF-8 locale, Turkish i→İ under
	-- tr_TR, etc. A bad byte (wc == nil) is left as-is.
	local chars = M.mb_chars(val)
	local out, limit = {}, all and #chars or math.min(1, #chars)
	for k = 1, #chars do
		local ch = chars[k]
		local s = ch.s
		if k <= limit and ch.wc and (any or M.glob_match(s, pat)) then
			local w2 = upper and M.towupper(ch.wc) or M.towlower(ch.wc)
			if w2 ~= ch.wc then
				s = M.wc_to_bytes(w2, ch.s)
			end
		end
		out[k] = s
	end
	return table.concat(out)
end
function Shell:apply_str_op(op, val, arg, arg2)
	arg = arg or ""
	if op == "@" then -- ${x@Q}/@U/@u/@L/@E/@K/@k (bash 5.x transforms)
		if arg == "Q" or arg == "K" or arg == "k" then
			return shell_quote(val)
		end
		if arg == "U" then
			return fold_case(val, "?", true, true)
		end -- upcase all (locale)
		if arg == "u" then
			return fold_case(val, "?", true, false)
		end -- upcase first char
		if arg == "L" then
			return fold_case(val, "?", false, true)
		end -- downcase all
		if arg == "E" then
			return M.ansi_unescape(val)
		end
		return val
	end
	if op == "#" then
		return strip_prefix(val, arg, false)
	end
	if op == "##" then
		return strip_prefix(val, arg, true)
	end
	if op == "%" then
		return strip_suffix(val, arg, false)
	end
	if op == "%%" then
		return strip_suffix(val, arg, true)
	end
	if op == "/" then
		return M.subst_glob(val, arg, arg2 or "", false)
	end
	if op == "//" then
		return M.subst_glob(val, arg, arg2 or "", true)
	end
	if op == "sub" then
		return substr(val, arg, arg2)
	end
	-- ${x^^PAT}/${x,,PAT}: fold every char matching glob PAT (default ? = any);
	-- ${x^PAT}/${x,PAT}: fold only the first char, and only if it matches PAT.
	if op == "^^" or op == ",," then
		return fold_case(val, arg, op == "^^", true)
	end
	if op == "^" or op == "," then
		return fold_case(val, arg, op == "^", false)
	end
	return val
end

-- Interpret backslash escapes for `echo -e` and ANSI-C `$'…'` quoting.
-- Encode a Unicode code point as UTF-8 bytes (for \u/\U in $'…', echo -e, printf).
function M.utf8_char(cp)
	if cp < 0x80 then
		return string.char(cp)
	elseif cp < 0x800 then
		return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
	elseif cp < 0x10000 then
		return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
	else
		return string.char(
			0xF0 + math.floor(cp / 262144),
			0x80 + math.floor(cp / 4096) % 64,
			0x80 + math.floor(cp / 64) % 64,
			0x80 + cp % 64
		)
	end
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
				if x == "" then
					out[#out + 1] = "\\c"
					i = i + 2
				else
					out[#out + 1] = string.char(x:byte() % 32)
					i = i + 3
				end
			elseif d == "u" or d == "U" then -- \uXXXX / \UXXXXXXXX code point (echo -e and $'…')
				local hex = s:match(d == "u" and "^%x%x?%x?%x?" or "^%x%x?%x?%x?%x?%x?%x?%x?", i + 2)
				if hex then
					local cp = tonumber(hex, 16)
					local u = {}
					if cp < 0x80 then
						u = { cp }
					elseif cp < 0x800 then
						u = { 0xC0 + math.floor(cp / 64), 0x80 + cp % 64 }
					elseif cp < 0x10000 then
						u = { 0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64 }
					else
						u = {
							0xF0 + math.floor(cp / 262144),
							0x80 + math.floor(cp / 4096) % 64,
							0x80 + math.floor(cp / 64) % 64,
							0x80 + cp % 64,
						}
					end
					for _, b in ipairs(u) do
						out[#out + 1] = string.char(b)
					end
					i = i + 2 + #hex
				else
					out[#out + 1] = "\\" .. d
					i = i + 2
				end
			elseif d == "n" then
				out[#out + 1] = "\n"
				i = i + 2
			elseif d == "t" then
				out[#out + 1] = "\t"
				i = i + 2
			elseif d == "r" then
				out[#out + 1] = "\r"
				i = i + 2
			elseif d == "\\" then
				out[#out + 1] = "\\"
				i = i + 2
			elseif d == "'" then
				out[#out + 1] = "'"
				i = i + 2
			elseif d == '"' then
				out[#out + 1] = '"'
				i = i + 2
			elseif d == "a" then
				out[#out + 1] = "\7"
				i = i + 2
			elseif d == "b" then
				out[#out + 1] = "\8"
				i = i + 2
			elseif d == "e" or d == "E" then
				out[#out + 1] = "\27"
				i = i + 2
			elseif d == "f" then
				out[#out + 1] = "\12"
				i = i + 2
			elseif d == "v" then
				out[#out + 1] = "\11"
				i = i + 2
			elseif d == "x" then
				local hex = s:match("^%x%x?", i + 2)
				if hex then
					out[#out + 1] = string.char(tonumber(hex, 16))
					i = i + 2 + #hex
				else
					out[#out + 1] = "\\x"
					i = i + 2
				end
			elseif not ansi_c and d == "0" then -- echo -e / printf %b: \0NNN (0 prefix + up to 3 octal)
				local oct = s:match("^[0-7]?[0-7]?[0-7]?", i + 2) or ""
				out[#out + 1] = string.char(tonumber("0" .. oct, 8) % 256)
				i = i + 2 + #oct
			elseif d:match("[0-7]") and (ansi_c or mode == "b") then -- \NNN octal ($'…' and %b, NOT echo -e)
				local oct = s:match("^[0-7][0-7]?[0-7]?", i + 1)
				out[#out + 1] = string.char(tonumber(oct, 8) % 256)
				i = i + 1 + #oct
			elseif d == "c" then
				return table.concat(out), true -- \c: stop all further output
			else
				out[#out + 1] = "\\" .. d
				i = i + 2
			end
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	return table.concat(out)
end

function Shell:echo(...)
	-- echo [-neE] ARGS: -n suppresses the trailing newline, -e interprets backslash
	-- escapes, -E disables them (bash). Same flag handling as the interp echo builtin,
	-- so compiled and interpreted echo agree.
	local n = select("#", ...)
	local nonl, esc = false, false
	-- Build the output string. Fast paths avoid the {...} pack + buf table + concat that
	-- dominate echo's cost (and GC) — the common `echo "one string"` has no -neE flag and a
	-- single (quoted) arg, so it needs neither. Only a leading -flag or multiple args pay them.
	local s
	local first = nil
	if n >= 1 then
		first = select(1, ...)
	end
	if type(first) == "string" and first:match("^%-[neE]+$") then
		local args = { ... }
		local j = 1
		while j <= n and type(args[j]) == "string" and args[j]:match("^%-[neE]+$") do
			for ch in args[j]:sub(2):gmatch(".") do
				if ch == "n" then
					nonl = true
				elseif ch == "e" then
					esc = true
				elseif ch == "E" then
					esc = false
				end
			end
			j = j + 1
		end
		s = table.concat(args, " ", j, n)
	elseif n <= 1 then
		s = first ~= nil and tostring(first) or "" -- common: one (quoted) arg — no table, no concat
	else
		local buf = { ... }
		for k = 1, n do
			buf[k] = tostring(buf[k])
		end
		s = table.concat(buf, " ")
	end
	local stopped
	if esc then
		s, stopped = M.ansi_unescape(s)
	end -- \c stops all output (incl. the newline)
	self.out(s)
	if not nonl and not stopped then
		self.out("\n")
	end
	-- bash's echo/printf flush stdout immediately (sh_chkwrite). This makes output
	-- ordering deterministic across a fork — e.g. `echo a & echo b` prints b then a,
	-- because the parent flushes b before the just-forked child is scheduled. Only
	-- when writing to the real fd (not into a $()/pipe capture buffer). A flush
	-- error (e.g. a full disk) is a write error -> status 1, like bash's sh_chkwrite.
	local werr = (self.out == io.write) and not io.flush() -- flush error (e.g. full disk) here
	if werr then
		self.write_err = true
	end
	self.status = werr and 1 or 0 -- a write error is status 1, like bash's sh_chkwrite
end

-- Builtin registry (name -> lazily-loaded module). The interpreter shares this
-- table (interp aliases rt.BUILTIN_LAZY), so there is one source of truth.
local BUILTIN_LAZY = {
	echo = "b_echo",
	compgen = "b_completion",
	complete = "b_completion",
	compopt = "b_completion",
	ulimit = "b_ulimit",
	times = "b_times",
	alias = "b_alias",
	unalias = "b_unalias",
	umask = "b_umask",
	getopts = "b_getopts",
	hash = "b_hash",
	history = "b_history",
	jobs = "b_jobs",
	trap = "b_trap",
	type = "b_type",
	printf = "b_printf",
	read = "b_read",
	mapfile = "b_mapfile",
	readarray = "b_mapfile",
	cd = "b_cd",
	unset = "b_unset",
	set = "b_set",
	export = "b_export",
	declare = "b_export",
	typeset = "b_export",
	readonly = "b_export",
	eval = "b_eval",
	source = "b_source",
	["."] = "b_source",
	wait = "b_wait",
	fc = "b_fc",
	bind = "b_bind",
	shopt = "b_shopt",
	let = "b_let",
	kill = "b_kill",
	pushd = "b_pushd",
	popd = "b_pushd",
	dirs = "b_pushd",
	builtin = "b_builtin",
	pwd = "b_pwd",
	shift = "b_shift",
	["local"] = "b_local",
	help = "b_help",
}
M.BUILTIN_LAZY = BUILTIN_LAZY
local _noop = function() end
-- Run a shell builtin natively for the compiled tier: the argv has already been
-- built by the field engine and the name is a statically-known builtin (emit gates
-- on this), so resolve its module and call it directly — the command RUNNER, not
-- statement re-interpretation. A function (possibly defined dynamically, e.g. via
-- eval/source) may shadow the builtin at runtime; that command isn't known at
-- compile time, so defer it to the bootstrap dispatcher, which decides function vs
-- (posix-)special-builtin exactly as an interpreted run would.
function M.builtin(sh, argv, hook)
	local cmd = argv[1]
	if sh.functions[cmd] then
		return require("interp").exec_simple(sh, argv, hook or _noop)
	end
	return require(BUILTIN_LAZY[cmd])(sh, cmd, argv, hook or _noop)
end

-- `VAR=val … cmd` prefix env for the COMPILED tier: apply each already-expanded scalar
-- prefix value as an EXPORTED tempenv for the duration of `runfn`, then restore — the
-- twin of interp's prefix-assign path (exec_stmt's st.assigns branch). Each binding is
-- pushed onto sh.tenv (LIFO, with the prior box + process-env value saved) so an `unset`
-- inside the command reveals the shadowed value beneath (bash dynamic scope) and a
-- `local` in a called function absorbs only its own frame's tempenv; a consumed entry is
-- skipped on restore. Values are evaluated by the caller BEFORE this runs (in the
-- pre-command environment — bash and interp agree a sibling prefix is NOT visible).
function M.run_prefix(sh, names, vals, runfn)
	local base = #sh.tenv
	for i = 1, #names do
		local name = names[i]
		local b = sh.vars[name] -- copy the box: set_str below mutates in place
		sh.vseq = sh.vseq + 1
		sh.tenv[#sh.tenv + 1] = {
			name = name,
			env = os.getenv(name),
			consumed = false,
			seq = sh.vseq,
			box = b
					and { s = b.s, n = b.n, arr = b.arr, assoc = b.assoc, order = b.order, exported = b.exported, ro = b.ro, ref = b.ref }
				or false,
		}
		sh:set_str(name, vals[i])
		C.setenv(name, sh:get(name), 1)
	end
	sh.tenv_call_base = base -- a DIRECT function call tags these with its frame (local absorption)
	local ok, err = pcall(runfn)
	sh.tenv_call_base = nil
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
		end
	end
	if not ok then
		error(err)
	end
end

-- A command word that was NOT a funcdef at compile time but resolves, at RUNTIME, to a
-- shell function (installed by eval/source or a nested def). The argv is already expanded
-- by the compiled field engine; dispatch it through exec_simple, which finds the function
-- and runs it via run_function — a COMPILED fn_x closure runs natively, an interp AST body
-- (one that eval/source defined) runs through exec_list until that definition site itself
-- compiles. No statement re-interpretation (no I.exec_stmt): only resolve+call is shared,
-- the words are compiled. xtrace mirrors the delegated path so `set -x` doesn't regress;
-- $_ / PIPESTATUS / errexit stay with the emitted wrapper around this call.
function M.call_dynamic_fn(sh, argv)
	local I = require("interp")
	if sh.opt_x then
		I.xtrace(sh, argv)
	end
	return I.exec_simple(sh, argv, _noop)
end

-- `eval CODE`: COMPILE the joined code string at runtime (fragment mode — its top-level
-- return/break/continue/exit RAISE, so they cross back to this eval's delegated cf-wrapper)
-- and run it in the CURRENT shell (shared sh: assignments, functions, $? all persist). No
-- exec_stmt tree-walk. Code that can't compile — aliases (line-at-a-time expansion), a
-- syntax error (run the valid prefix, then stop), or a construct emit still delegates —
-- falls back to the interpreter's incremental eval (b_eval), which is the oracle for those.
-- argv is the already-expanded command words {"eval", …}; run_compiled shares sh and does
-- NOT finish_run (no EXIT trap), so signals propagate to the caller untouched.
function M.eval(sh, argv)
	local a2 = argv[2]
	if a2 and a2 ~= "-" and a2 ~= "--" and a2:sub(1, 1) == "-" then
		io.stderr:write("curse: eval: " .. a2 .. ": invalid option\n")
		sh.status = 2
		return
	end
	local start = (a2 == "--") and 3 or 2
	local code = table.concat({ unpack(argv, start) }, " ")
	if not code:match("%S") then
		sh.status = 0
		return
	end
	local mod = require("tier").try_fragment(code)
	if mod then
		require("tier").run_compiled(mod, sh, nil)
	else
		require("b_eval")(sh, "eval", argv, nil, nil)
	end
end

-- `command -v NAME…` / `command -V NAME…`: a lookup query (is NAME an alias/keyword/
-- builtin/function/PATH file?) — no execution, so compile it to this rt.* dispatch instead
-- of delegating. name_type is the runtime resolver interp uses; the argv is already expanded
-- by the field engine. Mirrors interp's command -v/-V branch exactly (status 0 if ANY name
-- resolved). Combined/other flags stay with the interpreter.
function M.command_query(sh, argv)
	local I = require("interp")._int
	local verbose = argv[2] == "-V"
	local anyfound = false
	for j = 3, #argv do
		local k, p = I.name_type(sh, argv[j])
		if not k then
			if verbose then
				io.stderr:write("curse: command: " .. argv[j] .. ": not found\n")
			end
		else
			anyfound = true
			if verbose then
				if k == "alias" then
					sh:echo(argv[j] .. " is aliased to `" .. sh.aliases[argv[j]] .. "'")
				elseif k == "file" then
					sh:echo(argv[j] .. " is " .. p)
				elseif k == "function" then
					sh:echo(argv[j] .. " is a function")
					local d = I.func_body_text(sh, argv[j])
					if d then
						sh:echo(d)
					end
				elseif k == "keyword" then
					sh:echo(argv[j] .. " is a shell keyword")
				else
					sh:echo(argv[j] .. " is a shell builtin")
				end
			else
				sh:echo(k == "file" and p or argv[j])
			end
		end
	end
	sh.status = anyfound and 0 or 1
end

-- `source FILE [args]` / `. FILE [args]`: run FILE in the CURRENT shell, COMPILED as a
-- fragment (return/break/continue/exit propagate; scope shared) with $1.. set to the args.
-- Anything the compiled path can't handle — a missing/directory file, an alias or syntax
-- error or an unsupported construct in the file — defers to the interpreter's b_source, the
-- oracle (it also owns the diagnostics). A `return` ends the source (caught here); break/
-- continue/exit propagate to the caller; the RETURN trap fires after, like b_source.
function M.source(sh, argv)
	local I = require("interp")
	local Ii = I._int
	local j = 2
	if argv[j] == "--" then
		j = j + 1
	end
	local name = argv[j]
	if not name then
		return require("b_source")(sh, argv[1], argv, nil, nil) -- usage error: let b_source diagnose
	end
	local file = name
	if not name:find("/", 1, true) then
		for dir in (sh:get("PATH") .. ":"):gmatch("([^:]*):") do
			local cand = (dir == "" and "." or dir) .. "/" .. name
			if Ii.file_test("-f", cand) then
				file = cand
				break
			end
		end
	end
	if Ii.file_test("-d", file) then
		return require("b_source")(sh, argv[1], argv, nil, nil) -- directory: b_source diagnoses
	end
	local f = io.open(file, "r")
	if not f then
		return require("b_source")(sh, argv[1], argv, nil, nil) -- not found: b_source diagnoses
	end
	local code = f:read("*a")
	f:close()
	local mod = require("tier").try_fragment(code)
	if not mod then
		return require("b_source")(sh, argv[1], argv, nil, nil) -- alias / syntax error / uncompilable
	end
	-- Compiled path: swap in the file's positional params, run, restore. `return` in the
	-- file surfaces as __curse_return (fragment mode) and ends the source; exit/break/
	-- continue propagate past here to the caller's cf-wrapper, as bash's shared-context
	-- source does.
	local savep, savenp = sh.params, sh.nparams
	if #argv > j then
		sh.params, sh.nparams = {}, 0
		for k = j + 1, #argv do
			sh.nparams = sh.nparams + 1
			sh.params[sh.nparams] = argv[k]
		end
	end
	sh.sourcedepth = (sh.sourcedepth or 0) + 1 -- a `return` is valid while sourcing
	local rok, err = pcall(require("tier").run_compiled, mod, sh, nil)
	sh.sourcedepth = sh.sourcedepth - 1
	if #argv > j then
		sh.params, sh.nparams = savep, savenp
	end
	if not rok then
		if type(err) == "table" and err.__curse_return then
			sh.status = err.__curse_return
		else
			error(err) -- exit / break / continue propagate
		end
	end
	-- `.`/source fires the RETURN trap on return (any outcome but the usage error).
	local trap = sh.traps and sh.traps.RETURN
	if trap and trap ~= "" and not sh.in_return_trap then
		sh.in_return_trap = true
		local sv = sh.status
		Ii.run_trap(sh, trap)
		sh.status = sv
		sh.in_return_trap = false
	end
end

-- A DYNAMIC command word (`$cmd`/`${x}`/… — the first word resolves late, argv already
-- built by the compiled field engine) dispatched through the command runner. The command
-- is genuinely unknown at compile time (function / builtin / external), so resolution
-- bootstraps through exec_simple exactly like M.builtin does; the ARG EXPANSION is compiled.
-- Replicates interp exec_stmt's simple-command wrapper: xtrace before the run, a builtin
-- write-error -> status 1, then $_ (last arg) and PIPESTATUS. Control-flow builtins reached
-- this way (`b=break; $b`) raise __curse_break/continue/return/exit, which the caller's
-- delegate wrapper translates into the native pc jump.
function M.exec_dynamic(sh, argv, hook, hadcs, no_func)
	local n = #argv
	-- All words expanded away: an empty command takes the LAST command sub's exit status when
	-- one was performed (`$(exit 42)` -> 42, bare `false` -> 1), else 0 (bash) — matching interp.
	if n == 0 then
		sh.status = hadcs and (sh.last_cmdsub_status or 0) or 0
		return
	end
	local I = require("interp")
	sh.write_err = nil
	if sh.opt_x then
		I.xtrace(sh, argv)
	end
	-- no_func (the `command` prefix): run argv skipping SHELL FUNCTION lookup (builtin/external only).
	I.exec_simple(sh, argv, hook or _noop, no_func)
	if sh.write_err then
		sh.status = 1
	end
	sh:set_str("_", argv[n])
	sh:array_assign("PIPESTATUS", { tostring(sh.status) }, false)
end

-- Arithmetic variable reads for the compiled tier. The hot case — a variable holding
-- a plain number — is fully native (no interpreter). A non-numeric value (a stored
-- expression like x="1+2"), an unset var (set -u), or a blank value falls to the
-- interpreter's full arith_read, which recursively parses+evals the value's TEXT:
-- genuinely dynamic (the value isn't known at compile time), so it is the bootstrap.
function M.looks_numeric(s)
	return s:match("^%s*[+-]?%d+%s*$")
		or s:match("^%s*[+-]?0[xX]%x+%s*$")
		or s:match("^%s*[+-]?0[0-7]+%s*$")
		or s:match("^%s*%d+#[%w@_]+%s*$")
end
local _acache = {} -- value-string -> compiled fn(sh) | false (uncompilable; keep the seam)
function M.arith_read(sh, name)
	local s = sh:get(name)
	if s ~= nil and M.looks_numeric(s) then
		return M.arith_num(s)
	end -- native fast path
	-- Non-numeric VALUE (a stored expression like x="1+2"): COMPILE it to native ops and
	-- run — exactly what interp's arith_read -> arith_resolve -> eval does, but as genuine
	-- compiled code, not a tree-walk. Only the word-engine-free subset compiles (no
	-- $-expansion, no array subscript); $-forms/subscripts/unset/blank stay the interp
	-- bootstrap (their value/parse is dynamic, not reducible to monomorphic native ops).
	if s ~= nil and not s:match("^%s*$") and not (sh.arithfault and sh.in_arithcmd) then
		local fn = _acache[s]
		if fn == nil then
			fn = require("emit").compile_arith_value(s) or false
			_acache[s] = fn
		end
		if fn then
			-- Mirror arith_read∘arith_resolve exactly: a depth guard (bash cycle protection;
			-- 40 matches interp's arith_resolve, shared via sh.arith_depth across the seam),
			-- a nested bad value swallowed to 0, and a real matherr/experr mapped to a
			-- non-fatal $?=1 inside (( )) (sh.arithfault flag) or a line-abort in a word $((…)).
			local ok, v = pcall(function()
				sh.arith_depth = (sh.arith_depth or 0) + 1
				if sh.arith_depth > 40 then
					sh.arith_depth = sh.arith_depth - 1
					return i64(0)
				end -- cycle guard
				local ok2, r = pcall(fn, sh)
				sh.arith_depth = sh.arith_depth - 1
				if not ok2 then
					if type(r) == "table" and (r.__curse_experr or r.__curse_matherr) then
						error(r)
					end
					return i64(0) -- a nested bad value stays swallowed as 0 (matches arith_resolve)
				end
				return r ~= nil and r or i64(0)
			end)
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
	end
	return require("interp").arith_read(sh, name) -- unset/blank/$-expansion/subscript: bootstrap
end
-- Evaluate an ALREADY word-expanded string as an arithmetic expression, exactly as
-- interp's eval(P.arith(s)) — used for a `[[ … -eq … ]]` operand AND a `declare -i n=EXPR`
-- value. Empty is 0; a plain number is native; otherwise compile it (compile_arith_value
-- renders var operands as recursive rt.arith_read, so a value naming another var resolves
-- under the shared cycle guard). A subscript/$-form it can't compile defers to the interp
-- evaluator (interp.dbracket_arith = eval(P.arith(s)), empty->0), which also raises the
-- same math/syntax error the caller's codegen maps to a failing status.
function M.arith_str(sh, s)
	if s == "" then
		return i64(0)
	end
	if M.looks_numeric(s) then
		return M.arith_num(s)
	end
	local fn = _acache[s]
	if fn == nil then
		fn = require("emit").compile_arith_value(s) or false
		_acache[s] = fn
	end
	if fn then
		return fn(sh)
	end
	return require("interp").dbracket_arith(sh, s)
end

-- ${v:off:len} slice offset/length: arith-evaluate the already-expanded expression
-- string LENIENTLY — a parse/eval error falls back to tonumber(s) or 0, exactly interp's
-- arith_int (interp.lua). Returns a Lua number, or nil for empty/nil input (the caller
-- coerces nil->0 for a present operand). Shares the arith_str evaluator (native
-- compile_arith_value, interp bootstrap for the dynamic slow path — no new seam).
function M.arith_int(sh, s)
	if s == nil or s == "" then
		return nil
	end
	local ok, v = pcall(M.arith_str, sh, s)
	if ok then
		return tonumber(v)
	end
	return tonumber(s) or 0
end
-- `[[ -v NAME ]]` / `[[ -v a[i] ]]`: is the variable (or array element) set? interp's
-- var_is_set twin. `nm` is already word-expanded, so an array subscript is a plain literal
-- (no $): an ASSOC key is used verbatim, an INDEXED subscript is arith-evaluated via
-- rt.arith_str (native; a nested-subscript operand defers through arith_str's seam). A
-- bare array name tests element 0 (like bash); a digit is a positional parameter.
function M.var_is_set(sh, nm)
	local base, sub = nm:match("^([%a_][%w_]*)%[(.+)%]$")
	if base then
		local key = sh:is_assoc(base) and sub or M.to_arr_key(M.arith_str(sh, sub))
		return sh:is_elem_set(base, key)
	end
	if nm:match("^%d+$") then
		return tonumber(nm) <= sh.nparams
	end -- positional param
	local dn = sh:deref(nm)
	local b = sh.vars[dn]
	if b and b.arr then
		return sh:is_elem_set(dn, sh:is_assoc(dn) and "0" or 0)
	end -- bare array -> [0]
	-- A declared-but-VALUELESS scalar (`declare x` / `declare -i z` / `local l`) is NOT -v (bash);
	-- only a box that actually holds a value (incl. the empty string `x=`) counts as set.
	return (b ~= nil and (b.s ~= nil or b.n ~= nil)) or sh:special_get(nm) ~= ""
end

-- Set-ness for the ${x-word}/${x+word} default/alternate ops: a var is "set" only when it
-- HAS A VALUE (interp's expand_param isset), so a declared-but-valueless `local v` reads as
-- unset (unlike var_is_set / `[[ -v ]]`, which count a bare box). Scalar name only (the
-- default ops don't compile with a subscript).
function M.var_has_value(sh, name)
	local b = sh.vars[sh:deref(name)]
	local isset
	if b and b.arr then
		isset = b.arr[0] ~= nil or b.arr["0"] ~= nil
	else
		isset = b ~= nil and (b.s ~= nil or b.n ~= nil)
	end
	return isset or sh:special_get(name) ~= ""
end

-- ${x:=word}/${x=word}: assign the default to the variable (bash's assign_default for a
-- scalar/bare-array name — pexp_compilable never compiles a subscripted target), returning
-- the value. A bare name that IS an array writes element 0.
function M.assign_default(sh, name, v)
	local b = sh.vars[sh:deref(name)]
	if b and b.arr then
		sh:array_set(name, 0, v)
	else
		sh:set_str(name, v)
	end
	return v
end
-- ${x:?word}/${x?word}: the value was empty/unset — print the message and abort (exits
-- under -c/posix, else line-abort), exactly as interp's expand_param.
function M.param_error(sh, name, msg)
	io.stderr:write("curse: " .. name .. ": " .. msg .. "\n")
	error({ __curse_exit = sh.opt_c and 127 or 1, __curse_lineabort = sh.opt_i or nil })
end

-- ${a[@]OP}/${a[*]OP} per-element string-op for the compiled tier: map apply_str_op
-- over the array's element list (strip #/##/%/%%, subst /,//, case ^/^^/,/,, and the
-- @Q/@U… transforms), exactly interp's generic per-element path. `els` is the already-
-- fetched dense value list; the op + (literal) args are compile-time constants.
function M.array_op_values(sh, els, op, arg, arg2)
	local out = {}
	for i, v in ipairs(els) do
		out[i] = sh:apply_str_op(op, v, arg, arg2)
	end
	return out
end

-- ${!ref} indirect for the compiled tier: resolve + expand via interp (the target name is
-- late-bound and its scalar/array shape is genuinely dynamic — a bootstrap, like rt.builtin),
-- returning (element list, star) for the enclosing multi-segment (the field split/glob is then
-- compiled by expand_fields). `line` is the ${!ref}'s source line (compile-time constant) —
-- set sh.cur_line so a $LINENO indirect target (`ref=LINENO; ${!ref}`) reads the right line
-- (the compiled tier's cur_line is otherwise stale). An invalid-indirect error (bash line-
-- aborts) becomes the tier's __curse_lineabort so the command fails non-fatally.
function M.indirect_elems(sh, refname, refindex, iop, q, line)
	if line then
		sh.cur_line = line
	end
	-- qforced: a QUOTED multi alternate (`${!ref+"${a[@]}"}`) keeps its elements separate even
	-- when the outer ${…} is unquoted — the caller ORs it into the segment's q.
	local ok, els, star, qforced =
		pcall(require("interp").indirect_seg, sh, { name = refname, index = refindex, op = "indirect", iop = iop }, q)
	if ok then
		return els, star, qforced
	end
	local e = els -- pcall put the error here
	if type(e) == "table" and e.__curse_experr and not e.__curse_lineabort then
		error({ __curse_exit = e.__curse_exit or 1, __curse_lineabort = true })
	end
	error(e) -- fatal (set -u nounset, etc.) propagates
end

-- ${a[*]:-…} / ${*:-…} null test for the QUOTED-star form: the IFS[0]-joined string is
-- non-empty (interp multi_elems `star and p.q` branch). Empty IFS joins with no separator.
function M.ifs_join_ne(sh, els)
	local sep = sh.vars["IFS"] and sh:get("IFS"):sub(1, 1) or " "
	return table.concat(els, sep) ~= ""
end

-- ${!a[@]} / ${!a[*]}: the array's keys/indices as strings (a multi-element segment),
-- exactly interp's multi_elems indices branch.
function M.array_index_strs(sh, name)
	local ix = sh:array_indices(name)
	local t = {}
	for i = 1, #ix do
		t[i] = tostring(ix[i])
	end
	return t
end

-- ${a[@]:off:len} / ${a[*]:off:len} array slice for the compiled tier — replicates interp's
-- multi_elems sub branch exactly. `els` is the fetched value list (dense, parallel to
-- array_indices); off/len are already arith-evaluated (len nil = no length given). An
-- indexed (possibly sparse) array selects by INDEX VALUE (elements whose index >= off; a
-- negative off counts from highest index + 1); $@/$* and assoc are position-based (assoc
-- has bash's :0==:1 off-by-one). A negative length is a FATAL expansion error.
function M.array_slice_values(sh, name, els, off, len)
	off = off or 0
	if len ~= nil and len < 0 then
		io.stderr:write("curse: " .. len .. ": substring expression < 0\n")
		error({ __curse_exit = 1 })
	end
	if name ~= "@" and name ~= "*" and not sh:is_assoc(name) then
		local idx = sh:array_indices(name)
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
		return out
	end
	-- $@/$* and assoc: position-based (0-based off, negatives from the end)
	if off > 0 and sh:is_assoc(name) then
		off = off - 1
	end
	local n = #els
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

-- ${x@Q}/@U/@u/@L/@E/@K/@k transform for the compiled tier: an UNSET var yields nothing
-- (bash — the transform doesn't apply; an unquoted empty then drops as a field), matching
-- interp's expand_param (`if not isset then return "" end`). `val` is the already-read
-- value (its get_u already tripped set -u). Only the apply_str_op-handled args reach here
-- (emit gates out @P/@a).
function M.at_transform(sh, name, val, arg)
	if not M.var_is_set(sh, name) then
		return ""
	end
	return sh:apply_str_op("@", val, arg, "")
end

-- The `test`/`[` engine (shared by both tiers; the compiled tier computes the argv with
-- emit_word and calls M.do_test on the values — real code + a library call, not an AST
-- re-walk). Follows bash's test.c exactly. Every operand primitive is already a runtime
-- function (file_test, coll_lt, file_bincmp, var_is_set, SETOPT/opt_on), so this is
-- self-contained — no interpreter.
local function test_unary(sh, op, x)
	if op == "-z" then
		return x == ""
	end
	if op == "-n" then
		return x ~= ""
	end
	if op == "-o" then
		return sh and M.SETOPT[x] and M.opt_on(sh, M.SETOPT[x]) or false
	end -- shell option on
	if op == "-v" then
		return sh and M.var_is_set(sh, x) or false
	end -- variable/element is set
	return M.file_test(op, x) -- -e/-f/-d/-r/-w/-x/-s…
end
-- `test` numeric operands are plain DECIMAL integers (leading 0 is NOT octal; 0x/N#/arith
-- rejected) — an invalid one is a syntax error.
local function test_int(s)
	local d = s:match("^%s*([+-]?%d+)%s*$")
	if not d then
		error({ __test_syntax = ("%s: integer expression expected"):format(s) })
	end
	return M.str_to_i64(d) -- exact int64, base-10, like bash's test
end
local TEST_BINOPS = {
	["="] = 1,
	["=="] = 1,
	["!="] = 1,
	["<"] = 1,
	[">"] = 1,
	["-eq"] = 1,
	["-ne"] = 1,
	["-lt"] = 1,
	["-le"] = 1,
	["-gt"] = 1,
	["-ge"] = 1,
	["-ot"] = 1,
	["-nt"] = 1,
	["-ef"] = 1,
}
-- Unary primaries bash recognizes: a 2-arg test whose first token isn't one of these is
-- "unary operator expected" (status 2), not a false result.
local TEST_UNOPS = {}
for w in ("-a -b -c -d -e -f -g -h -k -p -r -s -t -u -w -x -G -L -N -O -R -S -o -v -z -n"):gmatch("%S+") do
	TEST_UNOPS[w] = 1
end
local function test_binary(x, op, y)
	if op == "=" or op == "==" then
		return x == y
	end
	if op == "!=" then
		return x ~= y
	end
	if op == "<" then
		return M.coll_lt(x, y)
	end -- string compare by LC_COLLATE (bash)
	if op == ">" then
		return M.coll_lt(y, x)
	end
	if op == "-ot" or op == "-nt" or op == "-ef" then
		return M.file_bincmp(op, x, y)
	end
	if not TEST_BINOPS[op] then
		error({ __test_syntax = ("%s: binary operator expected"):format(op) })
	end
	local nx, ny = test_int(x), test_int(y)
	if op == "-eq" then
		return nx == ny
	end
	if op == "-ne" then
		return nx ~= ny
	end
	if op == "-lt" then
		return nx < ny
	end
	if op == "-le" then
		return nx <= ny
	end
	if op == "-gt" then
		return nx > ny
	end
	if op == "-ge" then
		return nx >= ny
	end
	return false
end
-- The 0/1/2/3-arg POSIX cases WITHOUT the recursive-descent parser or its per-call
-- closures — this is the vast majority of `[ … ]`/test, and do_test's closures (7 per
-- call, mutually recursive so the JIT can't sink them) were a top allocation source.
-- An EXACT transcription of do_test's one_arg/two_args/three_args (pos threaded as a
-- plain local); test_unary/test_binary may throw __test_syntax, so the caller pcalls it.
local function test_simple(sh, args, lo, n)
	if n <= 0 then
		return false
	end
	if n == 1 then
		return args[lo] ~= ""
	end
	if n == 2 then
		if args[lo] == "!" then
			return not (args[lo + 1] ~= "")
		end
		if TEST_UNOPS[args[lo]] then
			return test_unary(sh, args[lo], args[lo + 1])
		end
		error({ __test_syntax = args[lo] .. ": unary operator expected" })
	end
	-- n == 3
	if TEST_BINOPS[args[lo + 1]] then
		return test_binary(args[lo], args[lo + 1], args[lo + 2])
	end
	if args[lo + 1] == "-a" then
		return (args[lo] ~= "") and (args[lo + 2] ~= "")
	end
	if args[lo + 1] == "-o" then
		return (args[lo] ~= "") or (args[lo + 2] ~= "")
	end
	if args[lo] == "!" then -- `! X Y` = not two_args(X, Y)
		if args[lo + 1] == "!" then
			return args[lo + 2] ~= "" -- ! ! Y  ->  Y is non-empty
		end
		if TEST_UNOPS[args[lo + 1]] then
			return not test_unary(sh, args[lo + 1], args[lo + 2])
		end
		error({ __test_syntax = args[lo + 1] .. ": unary operator expected" })
	end
	if args[lo] == "(" and args[lo + 2] == ")" then
		return args[lo + 1] ~= ""
	end
	error({ __test_syntax = args[lo + 1] .. ": binary operator expected" })
end
-- Evaluate a `test`/`[` argument list (already expanded): count-based dispatch (POSIX
-- 1/2/3-arg special cases) then a recursive-descent parser (or->and->term, `-o` lowest /
-- `-a` / `!` / `( )`), consuming terms strictly left-to-right so `-o`/`-a` can be an
-- OPERAND where one is expected.
local function do_test(sh, args)
	local lo, hi = 2, #args
	if args[1] == "[" then
		if args[hi] ~= "]" then
			sh.status = 2
			return
		end
		hi = hi - 1
	end
	local n = hi - lo + 1
	-- Fast path: 0-3 args need no recursive parser (no closures, no allocation).
	if n <= 3 then
		local ok, v = pcall(test_simple, sh, args, lo, n)
		if not ok then
			sh.status = 2
			return
		end
		sh.status = v and 0 or 1
		return
	end
	local pos = lo
	local expr_, and_, term_
	local function one_arg()
		local v = args[pos] ~= ""
		pos = pos + 1
		return v
	end
	local function two_args()
		if args[pos] == "!" then
			pos = pos + 1
			return not one_arg()
		end
		if TEST_UNOPS[args[pos]] then
			local v = test_unary(sh, args[pos], args[pos + 1])
			pos = pos + 2
			return v
		end
		error({ __test_syntax = args[pos] .. ": unary operator expected" })
	end
	local function three_args()
		if TEST_BINOPS[args[pos + 1]] then
			local v = test_binary(args[pos], args[pos + 1], args[pos + 2])
			pos = pos + 3
			return v
		end
		if args[pos + 1] == "-a" then
			local x, y = args[pos] ~= "", args[pos + 2] ~= ""
			pos = pos + 3
			return x and y
		end
		if args[pos + 1] == "-o" then
			local x, y = args[pos] ~= "", args[pos + 2] ~= ""
			pos = pos + 3
			return x or y
		end
		if args[pos] == "!" then
			pos = pos + 1
			return not two_args()
		end
		if args[pos] == "(" and args[pos + 2] == ")" then
			local v = args[pos + 1] ~= ""
			pos = pos + 3
			return v
		end
		error({ __test_syntax = args[pos + 1] .. ": binary operator expected" })
	end
	term_ = function()
		if pos > hi then
			error({ __test_syntax = "argument expected" })
		end
		if args[pos] == "!" then
			pos = pos + 1
			return not term_()
		end
		if args[pos] == "(" then
			pos = pos + 1
			local v = expr_()
			if args[pos] ~= ")" then
				error({ __test_syntax = "`)' expected" })
			end
			pos = pos + 1
			return v
		end
		if pos + 2 <= hi and TEST_BINOPS[args[pos + 1]] then
			local v = test_binary(args[pos], args[pos + 1], args[pos + 2])
			pos = pos + 3
			return v
		end
		if pos + 1 <= hi and TEST_UNOPS[args[pos]] then
			local v = test_unary(sh, args[pos], args[pos + 1])
			pos = pos + 2
			return v
		end
		return one_arg()
	end
	and_ = function()
		local v = term_()
		while pos <= hi and args[pos] == "-a" do
			pos = pos + 1
			local v2 = term_()
			v = v and v2
		end
		return v
	end
	expr_ = function()
		local v = and_()
		while pos <= hi and args[pos] == "-o" do
			pos = pos + 1
			local v2 = and_()
			v = v or v2
		end
		return v
	end
	local ok, res = pcall(function()
		if n == 0 then
			return false
		elseif n == 1 then
			return one_arg()
		elseif n == 2 then
			return two_args()
		elseif n == 3 then
			return three_args()
		else
			local v = expr_()
			if pos <= hi then
				error({ __test_syntax = "too many arguments" })
			end
			return v
		end
	end)
	if not ok then
		sh.status = 2
		return
	end
	sh.status = res and 0 or 1
end
M.test_unary, M.test_binary, M.test_int = test_unary, test_binary, test_int
M.TEST_BINOPS, M.TEST_UNOPS, M.do_test = TEST_BINOPS, TEST_UNOPS, do_test

-- Attribute-aware scalar assignment (interp's assign_scalar twin, for the EF.has_attr
-- compiled path): the RHS `value` is already word-expanded. A readonly target errors
-- (writing THROUGH a nameref is non-fatal; a direct one aborts the line, or hard-exits
-- under -c/posix); an array target assigns element [0]; an integer var arith-evaluates
-- the value (rt.arith_str — native, subscript/$-form via the interp seam); -l/-u fold
-- case; else a plain string set. `set -a` auto-exports a plain scalar. No array_key.
function M.assign_scalar(sh, name, value)
	local direct = sh.vars[name]
	-- nameref write-through (interp assign path): a cycle (ref -> … -> ref) is a non-fatal
	-- warning; a nameref whose value carries a SUBSCRIPT (declare -n ref='a[2]') writes to
	-- that element, not the base's [0] that a plain deref would give.
	if direct and direct.ref and direct.s and direct.s ~= "" then
		if sh:deref(name) == "" then
			io.stderr:write("curse: warning: " .. name .. ": circular name reference\n")
			sh.status = 1
			return
		end
		local nbase, nsub = direct.s:match("^([%a_][%w_]*)%[(.+)%]$")
		if nbase then
			local rb = sh.vars[nbase]
			if rb and rb.ro then -- through a nameref: readonly is non-fatal (bash)
				io.stderr:write("curse: " .. name .. ": readonly variable\n")
				sh.status = 1
				if sh.opt_c or sh.opt_posix then
					error({ __curse_exit = 1 })
				end
				return
			end
			-- key resolution (assoc: dequote/expand the subscript; indexed: arith) is interp's
			-- array_key — a rare-case bootstrap (a subscript-carrying nameref target).
			sh:array_set(nbase, require("interp")._int.array_key(sh, nbase, nsub), value, false)
			return
		end
	end
	local b = sh.vars[sh:deref(name)]
	if b and b.ro then
		io.stderr:write("curse: " .. name .. ": readonly variable\n")
		sh.status = 1
		if direct and direct.ref then
			return
		end -- through a nameref: non-fatal (bash)
		if sh.opt_c or sh.opt_posix then
			error({ __curse_exit = 1 })
		end
		error({ __curse_exit = 1, __curse_lineabort = true })
	end
	if b and b.arr then
		sh:array_set(name, sh:is_assoc(name) and "0" or 0, value, false) -- a=x on an array -> a[0]
	elseif b and b.int then
		sh:aset(name, M.arith_str(sh, value)) -- declare -i: RHS is arithmetic
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
-- Gate for the compiled fast-xpand path: true when the var's value binds like a
-- numeric atom (so native rendering == bash's textual substitution).
function M.arith_isnum(sh, name)
	local b = sh.vars[sh:deref(name)]
	if b and b.n ~= nil and b.s == nil and not b.arr then
		return true
	end -- i64-authoritative
	return M.looks_numeric(sh:get(name)) ~= nil
end
-- Textual substitution of a non-numeric $name value into arithmetic (bash re-parses
-- the value's TEXT). Dynamic — deferred to the interpreter bootstrap.
function M.arith_textual(sh, raw)
	return require("interp").arith_textual(sh, raw)
end

return M
