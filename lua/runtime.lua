-- curse LuaJIT runtime: the shared `sh` shell state that BOTH the interpreter
-- and the transpiled (compiled) code mutate. Because they share one table, the
-- tier handoff transfers no state — the compiled code just keeps using `sh`.
--
-- Integer arithmetic is 64-bit two's-complement via LuaJIT int64 cdata (FFI),
-- the exact analogue of curse's JS BigInt + asIntN(64): overflow wraps like
-- bash, and LuaJIT sinks the cdata boxing inside hot traces so it costs nothing.
local ffi = require("ffi")
local i64 = ffi.typeof("int64_t")

-- JIT limits: curse (interpreter + runtime + emitter, all traced in one long-lived
-- worker) outgrows LuaJIT's default 1000 traces, and hitting the cap FLUSHES EVERY
-- trace — each request then re-records the hot paths (measured ~0.6ms/request on the
-- cases corpus). Machine code is allocated as used, so a high cap costs nothing idle.
pcall(jit.opt.start, "maxtrace=8000", "maxmcode=8192")

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
local ANSIC_ESC = { [27] = "\\E", [7] = "\\a", [11] = "\\v", [8] = "\\b", [12] = "\\f", [10] = "\\n", [13] = "\\r", [9] = "\\t" }
M.ANSIC_ESC = ANSIC_ESC
-- bash's ansic_shouldquote: does S hold a byte/character that isn't printable (in the
-- locale: iswprint over its multibyte characters)? Such a value takes the $'…' form.
function M.ansic_shouldquote(s)
	if not s:find("[%z\1-\31\127-\255]") then
		return false
	end
	for _, ch in ipairs(M.mb_chars(s)) do
		if not ch.wc or ch.wc < 32 or ch.wc == 127 or M.iswprint(ch.wc) == 0 then
			return true
		end
	end
	return false
end
-- bash's sh_contains_shell_metas (shquote.c): a `#` counts only first, a `~` only first or
-- after `=`/`:` (where it would tilde-expand)
function M.shell_metas(s)
	return s:find("[ \t\n'\"\\|&;()<>!{}*%[?%]^$`]") ~= nil or s:byte(1) == 35 or s:byte(1) == 126
		or s:find("[=:]~") ~= nil
end
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
				local esc = ANSIC_ESC[b] -- (bash's ansic_quote: \E \a \v \b \f \n \r \t)
				if esc then
					out[#out + 1] = esc
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

-- A name in a diagnostic (`NAME: command not found`, `cd: NAME: …`): bash ANSI-C quotes
-- it when it holds a non-printable or invalid character (ansic_shouldquote), else as is.
function M.err_name(s)
	if not s:find("[%z\1-\31\127-\255]") then
		return s
	end
	local q = M.shell_quote(s)
	return q:sub(1, 2) == "$'" and q or s
end

local Shell = {}
Shell.__index = Shell
M.Shell = Shell

-- ---- error-message prefix ------------------------------------------------------------
-- Every shell diagnostic is written as "curse: msg". bash prefixes it with
-- `${BASH_SOURCE[0]:-$0}: line N: ` (error.c error_prolog; just `NAME: ` interactively),
-- so stderr is wrapped once and the leading "curse: " is rewritten at write time — the
-- one place that knows the shell's current source and line.
-- The compiled tier keeps its pc in a register, so the line is recovered on this (cold)
-- path from the Lua stack: every pc-dispatch function registers its pc -> line table
-- (M.pcline) and holds `pc` in local slot 2 (stripped bytecode still exposes slot values).
M.PCLINE = setmetatable({}, { __mode = "k" })
M.PCNAME = setmetatable({}, { __mode = "k" }) -- compiled fn_x -> the shell function's name
function M.pcline(f, t, name)
	M.PCLINE[f] = t
	M.PCNAME[f] = name
end
M.INTERP_FRAMES = setmetatable({}, { __mode = "k" }) -- interp functions that keep sh.cur_line
-- (second result: the innermost compiled shell function running, if any — its file
-- labels the message, as interp's run_function makes it sh.cur_source)
local function current_line(sh)
	local getinfo, getlocal = debug.getinfo, debug.getlocal
	local line
	for level = 3, 200 do
		local info = getinfo(level, "f")
		if not info then
			break
		end
		local f = info.func
		if M.INTERP_FRAMES[f] then
			break -- the interpreter is innermost: its sh.cur_line is current
		end
		local t = M.PCLINE[f]
		if t then
			if not line then
				local _, pc = getlocal(level, 2)
				local ln = t[pc]
				if ln and ln > 0 then
					line = ln
				end
			end
			if line and M.PCNAME[f] then
				return line, M.PCNAME[f]
			end
		end
	end
	return line or sh.cur_line or 0
end
M.current_line = current_line
function M.err_prefix(sh)
	if sh.opt_i then
		return (sh.shellname or "bash") .. ": "
	end
	local name = sh.cur_source or sh.argv0 or sh.shellname or "bash"
	if name == "" then
		name = sh.argv0 or "bash"
	end
	local ln, fnm = current_line(sh)
	ln = sh.force_line or ln
	local ff = fnm and sh.func_file and sh.func_file[fnm]
	if ff and ff ~= "" then
		name = ff
	end
	if sh.in_perr and sh.perr_label then -- (a syntax error in eval'd text: `NAME: eval: line N:`)
		name = name .. ": " .. sh.perr_label
	elseif sh.in_perr and sh.opt_c and not sh.cur_source then
		name = name .. ": -c"
	end
	if ln > 0 then
		return name .. ": line " .. ln .. ": "
	end
	return name .. ": "
end
do
	local real = io.stderr
	local proxy = setmetatable({}, {
		__index = function(_, k)
			local v = real[k]
			if type(v) == "function" then
				return function(self, ...)
					return v(real, ...)
				end
			end
			return v
		end,
	})
	function proxy:write(a, ...)
		if select("#", ...) > 0 then
			a = table.concat({ a, ... })
		end
		local sh = M.cur_shell
		if sh and type(a) == "string" and a:sub(1, 7) == "curse: " then
			local ok, pfx = pcall(M.err_prefix, sh)
			if ok then
				a = pfx .. a:sub(8)
			end
		end
		-- (what was echoed before a diagnostic reaches a shared fd first, as bash's does —
		-- the stdio buffer, or an in-process pipeline stage's)
		io.stdout:flush()
		if M.flush_stage_out then
			M.flush_stage_out(sh)
		end
		return real:write(a)
	end
	io.stderr = proxy
end

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
	M.cur_shell = sh -- (the error-prefix rewrite reads the live shell's source/line)
	sh:import_env()
	-- UID / EUID / PPID are real readonly integer variables in bash (set once at startup, so a
	-- subshell keeps the shell's PPID); the daemon re-points PPID at its client's parent
	for _, kv in ipairs({ { "UID", ffi.C.getuid() }, { "EUID", ffi.C.geteuid() }, { "PPID", ffi.C.getppid() } }) do
		sh.vars[kv[1]] = { s = tostring(tonumber(kv[2])), ro = true, int = true }
	end
	M.reset_locale(sh) -- adopt $LANG/$LC_* (bash calls setlocale at startup)
	-- bash (variables.c): OPTIND=1, an integer, and OPTERR=1 — whatever the environment said
	sh:set_str("OPTIND", "1")
	sh.vars.OPTIND.int = true
	sh:set_str("OPTERR", "1")
	if sh.vars["HOSTNAME"] == nil then
		sh:set_str("HOSTNAME", M.hostname())
	end
	-- curse identifies as bash (see shellname/basename); advertise a version so
	-- feature-detection (`test -n "$BASH_VERSION"`, `[[ $BASH_VERSION == 5* ]]`)
	-- works. A normal var: scripts can reassign or `unset` it (bash).
	if sh.vars["BASH_VERSION"] == nil then
		sh:set_str("BASH_VERSION", "5.2.37(1)-release")
	end
	-- BASH_VERSINFO: the readonly array form (major minor patch build release machtype)
	if sh.vars["BASH_VERSINFO"] == nil then
		sh:array_assign("BASH_VERSINFO", { "5", "2", "37", "1", "release", "x86_64-pc-linux-gnu" }, false)
		sh.vars["BASH_VERSINFO"].ro = true
	end
	sh.vars.BASH_ALIASES = M.virt_assoc(sh, "aliases")
	sh.vars.BASH_CMDS = M.virt_assoc(sh, "cmds")
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
	return self:paramsJoin(M.ifs_sep(self))
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
-- `declare -g NAME…` inside a function acts on the GLOBAL NAME even when a caller's
-- `local` shadows it. Dynamic scope keeps the global in the LOWEST frame that saved the
-- name: expose those bindings in sh.vars, and return a function that stores them back
-- and re-shadows (so the caller's locals are untouched).
function Shell:global_swap(names)
	local recs = {}
	for _, nm in ipairs(names) do
		for d = 0, self.pd or 0 do
			local sv = self.savedstack[d]
			if sv and sv[nm] ~= nil then
				recs[#recs + 1] = { sv = sv, nm = nm, cur = self.vars[nm] }
				self.vars[nm] = sv[nm].box or nil
				break
			end
		end
	end
	return function()
		for i = #recs, 1, -1 do
			local r = recs[i]
			r.sv[r.nm].box = self.vars[r.nm] or false
			self.vars[r.nm] = r.cur
		end
	end
end
-- The environment entry for `name` after its export attribute changed: bash builds a
-- child's environment from the EXPORTED variables with values, innermost first — so a
-- non-exported (or value-less) local leaves a shadowed exported global's value in place.
function Shell:env_resync(name)
	local function val(b)
		if b and b.exported and not b.arr and (b.s ~= nil or b.n ~= nil) then
			return b.s or M.i64_to_str(b.n)
		end
	end
	local v = val(self.vars[name])
	if v == nil then
		for d = self.pd or 0, 0, -1 do
			local sv = self.savedstack[d]
			if sv and sv[name] ~= nil then
				v = val(sv[name].box or nil)
				if v ~= nil or not (sv[name].box and sv[name].box.exported) then
					break
				end
			end
		end
	end
	if v ~= nil then
		ffi.C.setenv(name, v, 1)
	else
		ffi.C.unsetenv(name)
	end
end
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
			if rec.absorbed then -- (it took over a call-prefix tempenv: its env goes back too)
				if rec.env then
					ffi.C.setenv(name, rec.env, 1)
				else
					ffi.C.unsetenv(name)
				end
			elseif cur and cur.exported then
				if old and old.exported then
					ffi.C.setenv(name, self:get(name) or "", 1)
				else
					ffi.C.unsetenv(name)
				end
			end
		end
		self.savedstack[d] = false
	end
	-- `local -` in this call: the set options go back to their state at that point
	local lo = self.local_opts and self.local_opts[d]
	if lo then
		self.local_opts[d] = nil
		local set_opt = require("interp")._int.set_opt
		for f, e in pairs(lo) do
			if self[f] ~= e.v then
				set_opt(self, f, e.v)
			end
		end
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
		if te and (te.frame == self.pd or te.decl_pd == self.pd) then
			-- (absorbed: the tempenv's env entry is reverted when this local goes away)
			saved[name] = { box = te.box, seq = self.vseq, absorbed = true, env = te.env }
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
		-- a local of an EXPORTED name is exported too (bash): once it has a value, children
		-- see it (`export foo=abc; f() { local foo=x; printenv foo; }` prints x)
		local ob = saved[name].box
		if (ob and ob.exported) or te then -- (a tempenv binding is in the environment too)
			self.vars[name].exported = true
		end
		-- `local -I`: start as a copy of the outer variable — value and attributes, but
		-- not a nameref (bash)
		if (self.local_inherit or (self.shopt and self.shopt.localvar_inherit)) and ob and not ob.ref then
			local nb = self.vars[name]
			for k, v in pairs(ob) do
				nb[k] = v
			end
			if ob.arr then
				nb.arr = {}
				for k, v in pairs(ob.arr) do
					nb.arr[k] = v
				end
			end
			if ob.order then
				nb.order = { unpack(ob.order) }
			end
		end
	end
end

-- `local NAME=(…)` over a READONLY NAME: bash's compound assignment fails first, then
-- local's own error; nothing is created (status 1). True when that happened.
-- Does `local NAME` hit a readonly it may not shadow? Only a readonly GLOBAL blocks it;
-- a readonly local of an enclosing function can be shadowed (bash).
function Shell:is_global_ro(name)
	local b = self.vars[name]
	if not (b and b.ro) then
		return false
	end
	for d = self.pd or 0, 0, -1 do
		local sv = self.savedstack[d]
		if sv and sv[name] ~= nil then
			return false -- (a caller's local)
		end
	end
	return true
end
-- `local` outside any function (a compiled subshell / pipeline stage / $( ) at the top
-- level runs it natively): bash's "can only be used in a function", status 1
-- `declare ra=(…)` (not making a local) on a readonly array: bash's compound assignment
-- fails as the words expand — before the builtin — and the rest of the line is abandoned
function M.array_ro_abort(sh, name)
	local b = sh.vars[sh:deref(name)]
	if b and b.ro then
		sh:errmsg("curse: " .. name .. ": readonly variable\n")
		sh.status = 1
		error({ __curse_exit = 1, __curse_lineabort = true })
	end
end
function M.local_nofn(sh)
	if sh.pd == 0 and (sh.calldepth or 0) == 0 then
		sh:errmsg("curse: local: can only be used in a function\n")
		sh.status = 1
		return true
	end
	return false
end
function M.local_ro(sh, name, cmd)
	if sh:is_global_ro(name) then -- (the compound assignment's error names the FUNCTION: bash's
		local fnm = sh.funcstack and sh.funcstack[1] -- this_command_name still holds it)
		sh:errmsg("curse: " .. (fnm and (fnm .. ": ") or "") .. name .. ": readonly variable\n")
		sh:errmsg("curse: " .. (cmd or "local") .. ": " .. name .. ": readonly variable\n")
		sh.status = 1
		return true
	end
	return false
end
-- one `local` operand: `name`, `name=value`, or `name+=value` (value expanded).
-- `+=` appends to the value AFTER localizing (bash: appends to the new local, not
-- the shadowed outer one). Returns false (else true) when the name is READONLY: bash
-- fails that operand (message + `local` returns 1) WITHOUT shadowing it or changing
-- the value, and continues with the rest — so the caller ORs the results into $?.
function Shell:localAssign(arg, cmd)
	local nm, op, val = arg:match("^([%a_][%w_]*)(%+?=)(.*)$")
	local name = nm or arg
	-- readonly NAME: no shadow, no assignment (the readonly global stays visible in the
	-- frame) — nor for a readonly local of this same scope (`local -r x; local x=2`: bash's
	-- make_local_variable returns it, and the assignment fails). Message routes through
	-- any 2>&1 capture, exactly like interp.
	local own = self.savedstack[self.pd]
	local ob = self.vars[name]
	if self:is_global_ro(name) or (nm and ob and ob.ro and own and own[name] ~= nil) then
		self:errmsg("curse: " .. (cmd or "local") .. ": " .. name .. ": readonly variable\n")
		if nm then -- (a value for a readonly var: EX_BADASSIGN — see stage_body)
			self.badassign = true
		end
		return false
	end
	if nm then
		local again = own and own[nm] ~= nil -- (already local here: it keeps its attributes)
		self:localVar(nm, true)
		local b = again and self.vars[nm]
		if b and (b.int or b.lower or b.upper or b.cap or b.arr or b.ref) then
			-- an attributed local assigns like `name=value` / `name+=value` (declare -i
			-- arithmetic — its errors naming the builtin — case folding, element 0)
			local P = require("parser")
			local sv = P.arith_cmd
			P.arith_cmd = cmd or "local"
			local ok, e = pcall(op == "+=" and M.append_scalar or M.assign_scalar, self, nm, val)
			P.arith_cmd = sv
			if not ok then
				error(e, 0)
			end
		else
			self:set_str(nm, op == "+=" and (self:get(nm) .. val) or val)
		end
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
function M.ifs_split(ifs, s, nomark) -- (nomark: \1 is not an escape marker — read's skip_ctlesc)
	local fields, cur = {}, nil
	local function isws(c) -- IFS whitespace (subst.c ifs_whitespace): whitespace NOT in $IFS is ordinary text
		return (c == " " or c == "\t" or c == "\n") and ifs:find(c, 1, true) ~= nil
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
		if c == "\1" and i < n and not nomark then -- CTLESC: next char is literal (read backslash-escape)
			cur = (cur or "") .. s:sub(i + 1, i + 1)
			i = i + 2
		elseif inifs(c) then
			if isws(c) then
				-- (LEADING whitespace is just ignored: a `:` right after it still ends an
				-- empty first field — IFS=': ' splits " :" into one empty field)
				local leading = cur == nil and #fields == 0
				if cur ~= nil then
					brk()
				end
				i = i + 1
				while i <= n and isws(s:sub(i, i)) do
					i = i + 1
				end
				if not leading and i <= n and inifs(s:sub(i, i)) and not isws(s:sub(i, i)) then
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
  int posix_spawn_file_actions_addopen(void *fa, int fd, const char *path, int oflag, unsigned int mode);
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
  char *strerror(int errnum);
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
  /* Coroutine pipeline scheduler (asm-aliased so interp's own declarations of the
     same libc symbols never collide — LuaJIT refuses a redefinition). */
  struct curse_co_pollfd { int fd; short events; short revents; };
  struct curse_co_ts { long tv_sec; long tv_nsec; };
  int curse_co_poll(struct curse_co_pollfd *fds, unsigned long nfds, int timeout) asm("poll");
  int curse_co_pipe2(int *fds, int flags) asm("pipe2");
  int curse_co_fcntl3(int fd, int cmd, int arg) asm("fcntl");
  long curse_co_syscall(long nr, long a, long b) asm("syscall");
  int curse_co_sigaddset(void *set, int sig) asm("sigaddset");
  int curse_co_sigtimedwait(const void *set, void *info, const struct curse_co_ts *ts) asm("sigtimedwait");
  int curse_co_chdir(const char *path) asm("chdir");
  unsigned int curse_co_umask(unsigned int mask) asm("umask");
  char *curse_co_getcwd(char *buf, unsigned long size) asm("getcwd");
  void *curse_co_malloc(unsigned long n) asm("malloc");
  void curse_co_free(void *p) asm("free");
  long curse_co_write(int fd, const void *buf, unsigned long n) asm("write");
]])
local C = ffi.C

-- ---- Coroutine pipeline scheduler: blocking primitives ---------------------
-- A pipeline's SHELL-SIDE stages run as cooperative coroutines inside this one
-- process (externals stay real processes, running concurrently); stages talk over
-- real kernel pipes. Only one stage runs at a time, so process-global state is
-- swapped at context-switch time (fd 0/1/2, environ, cwd, umask — see the
-- scheduler). The one hard rule: nothing a stage does may BLOCK the process, or a
-- sibling it depends on starves and the pipeline deadlocks. So every blocking
-- point routes through these: inside a stage they YIELD to the scheduler's poll
-- loop until ready; outside one (CO == nil) they are no-ops / plain syscalls.
local CO = nil -- the active scheduler context (nil when no coroutine pipeline runs)
-- The scheduler context itself PERSISTS while any task lives (a background job outlives the
-- statement that started it): pipelines and `&` jobs share it. CO is set only while the
-- scheduler is actually running tasks.
local SCHED = nil
local function sched_get()
	if not SCHED then
		SCHED = { bycoro = {}, fds = {}, envs = {}, runnable = {} }
	end
	return SCHED
end
local function sched_live()
	return SCHED ~= nil and next(SCHED.bycoro) ~= nil
end
M.sched_live = sched_live
local SIGMARK = {} -- (a yield resumed with this: signals are pending for the task)
local CO_OUTS = setmetatable({}, { __mode = "k" }) -- stage stdout writers (fd-1 backed)
local POLLIN, POLLOUT = 1, 4
local _co_pfd = ffi.new("struct curse_co_pollfd[1]")
local function fd_would_block(fd, ev)
	_co_pfd[0].fd, _co_pfd[0].events, _co_pfd[0].revents = fd, ev, 0
	return C.curse_co_poll(_co_pfd, 1, 0) == 0 -- nothing ready (POLLHUP/POLLERR count as ready)
end
-- The running stage task, or nil (main thread, a forked child, or no scheduler).
local function co_task()
	if not CO then
		return nil
	end
	local co = coroutine.running()
	return co and CO.bycoro[co] or nil
end
M.co_task = co_task
-- Save a copy of `fd` for a later restore — the way bash does: close-on-exec (a
-- spawned child must never inherit the shell's saved copy; e.g. a saved dup of a
-- pipe's write end would keep that pipe's reader from ever seeing EOF) and at fd >= FD_BASE
-- (so it can't collide with any fd a script redirects or allocates). -1 if `fd` isn't open.
--
-- WHERE: far above anything a script names. bash keeps its own fds near 255 and hands
-- out `{var}` fds from 10 up, and a script may redirect any number it likes — so the
-- shell's plumbing starts at FD_BASE (4096; under a small RLIMIT_NOFILE, 256 below the
-- soft limit). Not higher: fork/spawn copies the fd table up to the highest OPEN fd, so a
-- six-digit fd would tax every external. If a script's `ulimit -n` puts FD_BASE out of
-- reach (EINVAL), fall back to >= 10, then to any fd.
local FD_BASE = 4096
do
	ffi.cdef("struct curse_rt_rlimit { unsigned long cur, max; };"
		.. "int curse_rt_getrlimit(int res, struct curse_rt_rlimit *r) asm(\"getrlimit\");")
	local rl = ffi.new("struct curse_rt_rlimit")
	if C.curse_rt_getrlimit(7, rl) == 0 and rl.cur < FD_BASE + 256 then -- RLIMIT_NOFILE
		FD_BASE = math.max(10, tonumber(rl.cur) - 256)
	end
end
M.FD_BASE = FD_BASE
local function dup_hi(fd)
	local d = C.curse_co_fcntl3(fd, 1030, FD_BASE) -- F_DUPFD_CLOEXEC
	if d < 0 and fd >= 0 and ffi.errno() ~= 9 then -- not EBADF: the base is out of reach
		d = C.curse_co_fcntl3(fd, 1030, 10)
		if d < 0 and ffi.errno() ~= 9 then
			d = C.curse_co_fcntl3(fd, 1030, 0)
		end
	end
	return d
end
M.dup_hi = dup_hi
function M.save_fd(fd)
	return dup_hi(fd)
end
-- Move an internal fd out of the user range: a CLOEXEC copy at FD_BASE+, original closed.
local function fd_hi(fd)
	if fd < 0 or fd >= FD_BASE then
		return fd
	end
	local d = dup_hi(fd)
	C.close(fd)
	return d
end
-- pipe() for the shell's OWN plumbing (capture pipes, stage pipes): both ends at
-- >= FD_BASE and close-on-exec, like bash — so they can't be clobbered by (or clobber) a
-- user redirect of fds 3-9, never leak into a spawned external (a leaked write end
-- starves its reader of EOF), and survive a pipeline stage's per-switch fd swap.
-- A child that needs one dup2s it onto 0/1, which clears CLOEXEC there.
local _hi_pipe = ffi.new("int[2]")
function M.pipe_hi(fds)
	if C.curse_co_pipe2(_hi_pipe, 0x80000) ~= 0 then
		return -1
	end
	fds[0], fds[1] = fd_hi(_hi_pipe[0]), fd_hi(_hi_pipe[1])
	return 0
end
local task_flush -- forward: flush a task's buffered stdout (defined with the scheduler)
local task_signals -- forward: deliver a task's pending signals (see M.vkill)
local real_flush = io.flush
-- Park-safety before a yield: nothing buffered may be left in stdio or the task's
-- stdout buffer, because while parked fd 1 belongs to some OTHER stage.
local function pre_yield(t)
	if not t.flushing then
		task_flush(t)
	end
	real_flush()
end
-- Preemption of a background job that computes without blocking (lib_cursesig.c): while
-- one runs, a CPU-time slice is armed; when it runs out the flag is raised, and the job
-- yields at its next loop head (the interpreter's and compiled code's loops check it) —
-- so `while :; do :; done &` can't starve the shell. Only at loop heads: mid-statement,
-- shared scratch state (match buffers, …) could be in use.
pcall(ffi.cdef, "int *curse_preempt_flagp(void); int curse_preempt_arm(long usec);")
local PREEMPT, preempt_arm
do
	local ok, p = pcall(function()
		return C.curse_preempt_flagp()
	end)
	if ok and p ~= nil then
		PREEMPT, preempt_arm = p, C.curse_preempt_arm
	else -- (a VM without curse's C additions: no slices)
		PREEMPT, preempt_arm = ffi.new("int[1]"), function()
			return -1
		end
	end
end
M.preempt_flag = PREEMPT
local PREEMPT_USEC = 10000
function M.preempt()
	PREEMPT[0] = 0
	local t = co_task()
	if t then
		pre_yield(t)
		if coroutine.yield() == SIGMARK then -- (no values: co_resume queues it as runnable again)
			task_signals(t)
		end
	end
end
-- Wait until `fd` is ready for `ev` (POLLIN/POLLOUT). A no-op outside a stage.
function M.co_block(fd, ev)
	local t = co_task()
	if not t then
		if sched_live() and fd_would_block(fd, ev) then
			M.sched_pump({ fd = fd, ev = ev }) -- (background jobs run while the shell waits)
		end
		return
	end
	while fd_would_block(fd, ev) do
		pre_yield(t)
		if coroutine.yield(fd, ev) == SIGMARK then
			task_signals(t)
		end
	end
end
-- waitpid that yields inside a stage (via a pollable pidfd) instead of stalling
-- every sibling. `flags` other than 0 (WNOHANG, …) are passed straight through.
-- `intr` (the shell, from the `wait` builtin): a trapped signal's trap sets intr.wait_sig,
-- which ends the wait early with -1 (bash's wait_intr_buf) — else an EINTR is retried.
function M.wait_child(pid, stbuf, flags, intr)
	flags = flags or 0
	local t = flags == 0 and co_task() or nil
	if t or (flags == 0 and sched_live()) then
		local pfd = tonumber(C.curse_co_syscall(434, pid, 0)) -- pidfd_open
		if pfd and pfd >= 0 then
			pfd = fd_hi(pfd) -- out of the user fd range: it lives across a yield
		end
		if pfd and pfd >= 0 then
			if not t then -- the shell itself waits: background jobs run meanwhile
				if fd_would_block(pfd, POLLIN) then
					M.sched_pump({ fd = pfd, ev = POLLIN, untilf = intr and function()
						return intr.wait_sig ~= nil
					end })
				end
				C.close(pfd)
				if intr and intr.wait_sig then
					return -1
				end
				return C.waitpid(pid, stbuf, flags)
			end
			t.child_pid = pid -- (`kill` of a simple-command job reaches this child: see task_kill)
			while fd_would_block(pfd, POLLIN) do
				pre_yield(t)
				if coroutine.yield(pfd, POLLIN) == SIGMARK then
					local ok, err = pcall(task_signals, t)
					if not ok then -- (the task dies: its child lives on, reaped as an orphan)
						C.close(pfd)
						t.child_pid = nil
						M.internal_pids[pid] = true
						error(err, 0)
					end
				end
			end
			t.child_pid = nil
			C.close(pfd)
		elseif t then -- no pidfd (old kernel): poll WNOHANG on a scheduler tick
			while C.waitpid(pid, stbuf, 1) == 0 do
				pre_yield(t)
				if coroutine.yield(-1, 0) == SIGMARK then
					task_signals(t)
				end
			end
			return pid
		end
	end
	if intr then
		while true do
			local r = C.waitpid(pid, stbuf, flags)
			if r >= 0 or ffi.errno() ~= 4 or intr.wait_sig then -- (EINTR: the trap has run)
				return r
			end
		end
	end
	return C.waitpid(pid, stbuf, flags)
end
-- fork() for every shell-side fork site. Inside a stage it first flushes that
-- stage's stdout (ordering), and the CHILD leaves the scheduler: it drops every
-- pipe/save fd the scheduler holds (a stray copy of a write end would starve a
-- reader of EOF), unblocks SIGPIPE, and forgets CO — so it never yields and runs
-- to its own _exit like any forked child.
-- $$ is the MAIN shell's pid in every subshell: fixed before the first fork, so a child
-- never computes its own (Shell:pid)
local pid_cache
-- $BASH_SUBSHELL = the forks between here and the main shell (M.fork_depth, a late fork
-- excepted: it continues an already-counted context) + the in-process subshell contexts
-- this shell object is inside (sh.subdepth: subshell_run, capture_inproc, stage clones)
M.fork_depth = 0
function M.fork()
	local t = co_task()
	if t then
		pre_yield(t)
	end
	pid_cache = pid_cache or tonumber(C.getpid())
	local pid = C.fork()
	if pid == 0 then
		-- every forked child is a subshell: it doesn't run the EXIT trap it inherited
		-- (bash) — only one it sets itself (`trap … EXIT` clears this; see child_exit)
		M.exit_trap_inherited = true
		M.fork_depth = M.fork_depth + 1 -- ($BASH_SUBSHELL)
	end
	if pid == 0 and (CO or SCHED) then
		for fd in pairs((CO or SCHED).fds) do
			C.close(fd)
		end
		if CO then
			C.sigprocmask(2, CO.oldmask, nil) -- SIG_SETMASK: SIGPIPE back to the pre-pipeline mask
		end
		CO, SCHED = nil, nil -- (the child runs no tasks: they are the parent's)
	end
	return pid
end
-- io.flush is the shell's universal "about to move/hand off fd 1" hook (redirect
-- apply/restore, spawn, fork all call it), so extend it to also drain the running
-- stage's stdout buffer — keeping builtin output correctly ordered around
-- redirects without touching every call site.
io.flush = function(...)
	local t = CO and co_task()
	if t and not t.flushing then
		task_flush(t)
	end
	return real_flush(...)
end

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
local re_locale_changed = function() end -- (defined with the regex cache below)
M.locale_gen = 0 -- bumped per reset: an in-process subshell that changed it re-applies on exit
local re_lockey, lk = "", {}
function M.reset_locale(sh)
	M.locale_gen = M.locale_gen + 1
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
				if cat == 0 or cat == 3 then
					lk[cat] = v
				end
				break
			end
		end
	end
	local k = lk[0] .. "\0" .. lk[3]
	if k ~= re_lockey then
		re_lockey = k
		re_locale_changed()
	end
	lc_mb_cur_max = tonumber(C.__ctype_get_mb_cur_max()) or 1
end
M.LC_CATEGORIES = LC_CATEGORIES
-- The LC_NUMERIC decimal point (reset_locale applies the category) — LuaJIT's own number
-- formatting always writes ".", so printf's float conversions substitute this.
ffi.cdef("struct curse_lconv { char *decimal_point; }; struct curse_lconv *localeconv(void);")
function M.decimal_point()
	local lc = C.localeconv()
	local dp = lc ~= nil and lc.decimal_point ~= nil and ffi.string(lc.decimal_point) or "."
	return dp ~= "" and dp or "."
end

-- Count CHARACTERS (codepoints) in a byte string using the current LC_CTYPE, the
-- way bash's MB_STRLEN does: single-byte locale -> byte length; else walk with
-- mbrtowc, counting an invalid/incomplete byte as one char and resyncing by one.
local _mb_wc = ffi.new("int[1]")
local _mb_st = ffi.new("curse_mbstate_t")
function M.mb_strlen(s)
	if lc_mb_cur_max <= 1 or not s:find("[\128-\255]") then -- (ASCII: a char per byte)
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
	if lc_mb_cur_max <= 1 or not s:find("[\128-\255]") then -- (ASCII: a char per byte)
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
			ffi.fill(_mb_st, ffi.sizeof(_mb_st)) -- (an incomplete sequence leaves the state mid-char)
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
-- is the current LC_CTYPE UTF-8? (cached per locale generation)
local _utf8_gen, _utf8 = -1, false
function M.lc_utf8()
	if _utf8_gen ~= M.locale_gen then
		_utf8_gen = M.locale_gen
		_utf8 = false
		if lc_mb_cur_max > 1 then
			ffi.fill(_mb_st, ffi.sizeof(_mb_st))
			_utf8 = tonumber(C.wcrtomb(_mb_buf, 0xE9, _mb_st)) == 2 and ffi.string(_mb_buf, 2) == "\195\169"
		end
	end
	return _utf8
end
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
function M.subshell_exit(status, sh)
	M.child_exit(sh, status)
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
-- open() for a redirection target. Opening a FIFO blocks until its other end opens — and
-- with that other end in THIS process (a background job, a pipeline stage) it never
-- would: open non-blocking and wait by running the scheduler instead. A reader waits for
-- data or its writer's hangup (so its first read isn't a spurious EOF); a writer retries
-- until a reader is there (ENXIO until then).
local _ropen_st = ffi.new("char[144]")
-- Low fds the shell hands out by NUMBER (a process substitution's /dev/fd/63) are open in
-- the one process every in-process subshell shares: an external spawned by a DIFFERENT
-- shell (a background job, a stage) must not inherit one — `tee >(wc -c)`: wc would hold a
-- writer on its own input. fd -> the shell it belongs to; foreign_fa closes the others'.
M.fd_owner = {}
function M.foreign_fa(self, fa)
	for fd, owner in pairs(M.fd_owner) do
		if owner ~= self and C.fcntl(fd, 1) >= 0 then
			if not fa then
				fa = ffi.new("uint8_t[1024]")
				C.posix_spawn_file_actions_init(fa)
			end
			C.posix_spawn_file_actions_addclose(fa, fd)
		end
	end
	return fa
end
ffi.cdef("int curse_rt_fstat(int fd, void *buf) asm(\"fstat\");")
-- An open fd's file identity ("dev:ino"), or nil.
function M.fd_ident(fd)
	if C.curse_rt_fstat(fd, _ropen_st) ~= 0 then
		return nil
	end
	local u = ffi.cast("uint64_t *", _ropen_st)
	return tostring(u[0]) .. ":" .. tostring(u[1])
end
-- `read`'s fast paths: a regular file may be read in chunks and rewound to just past
-- the line (bash's lseek-back); from a pipe/socket/tty it must go a byte at a time, but
-- FIONREAD says how many bytes are already there — those reads can't block.
ffi.cdef([[
  long curse_rt_lseek(int fd, long off, int whence) asm("lseek");
  int curse_rt_ioctl_int(int fd, unsigned long req, int *out) asm("ioctl");
]])
-- "reg" (regular file), "fifo" (pipe), or nil (anything else / not open)
function M.fd_kind(fd) -- (+ its dev, ino)
	if C.curse_rt_fstat(fd, _ropen_st) ~= 0 then
		return nil
	end
	local m = bit.band(ffi.cast("uint32_t *", _ropen_st + 24)[0], 0xF000)
	local u = ffi.cast("uint64_t *", _ropen_st)
	return m == 0x8000 and "reg" or m == 0x1000 and "fifo" or nil, tonumber(u[0]), tonumber(u[1])
end
-- What `read` peeked from a pipe but hasn't consumed yet is still at the pipe's head —
-- unless something else read from it since. So the peek is kept (one pipe at a time) and
-- the next line is read straight from it, while M.rd_gen is unchanged: it is bumped by
-- every external spawn and every other read of an input fd in this shell. A mismatch
-- (a concurrent reader raced us) leaves what was read in `pb`: ours, delivered first.
M.rd_gen = 0
local PCACHE = { data = "", pos = 1, pb = "" }
function M.pipe_cache(dev, ino)
	local c = PCACHE
	if c.dev ~= dev or c.ino ~= ino or c.epoch ~= M.path_epoch then
		c.dev, c.ino, c.epoch, c.pb = dev, ino, M.path_epoch, ""
		c.data, c.pos, c.gen = "", 1, M.rd_gen
	elseif c.gen ~= M.rd_gen then
		c.data, c.pos, c.gen = "", 1, M.rd_gen
	end
	return c
end
-- One read of up to `n` bytes (retrying EINTR only: never waits for more), as a string.
function M.read_n(fd, buf, n)
	while true do
		local r = tonumber(C.read(fd, buf, n))
		if r >= 0 then
			return ffi.string(buf, r)
		elseif ffi.errno() ~= 4 then
			return ""
		end
	end
end
-- Peek at what's waiting in pipe `fd` WITHOUT consuming it: tee(2) duplicates up to
-- `max` bytes into a private pipe, drained into `buf`. So `read` finds the line end in
-- one call, then reads exactly the line (bash reads a pipe a byte at a time). Returns
-- the bytes; "" at EOF; nil when the pipe is empty for now; false if it can't peek.
-- The private pipe is made per daemon request (the scrub closes the shell's fds).
ffi.cdef("long curse_rt_tee(int fdin, int fdout, size_t len, unsigned int flags) asm(\"tee\");")
local peek_r, peek_w, peek_epoch = -1, -1, nil
local _peek_p = ffi.new("int[2]")
function M.pipe_peek(fd, buf, max)
	if peek_epoch ~= M.path_epoch or peek_r < 0 then
		if M.pipe_hi(_peek_p) ~= 0 then
			return false
		end
		peek_r, peek_w, peek_epoch = _peek_p[0], _peek_p[1], M.path_epoch
	end
	local n = tonumber(C.curse_rt_tee(fd, peek_w, max, 2)) -- SPLICE_F_NONBLOCK
	if n == 0 then
		return ""
	elseif n < 0 then
		return ffi.errno() == 11 and nil or false -- (EAGAIN: empty; else: not peekable)
	end
	local got = 0
	while got < n do
		local r = tonumber(C.read(peek_r, buf + got, n - got))
		if r <= 0 then
			if r < 0 and ffi.errno() == 4 then -- EINTR
				r = 0
			else
				return false
			end
		end
		got = got + r
	end
	return ffi.string(buf, n)
end
-- Consume exactly `n` bytes from `fd` (just peeked, so they're there).
function M.read_exact(fd, buf, n)
	while n > 0 do
		local r = tonumber(C.read(fd, buf, n))
		if r <= 0 then
			if not (r < 0 and ffi.errno() == 4) then
				return false
			end
		else
			n = n - r
		end
	end
	return true
end
local _avail = ffi.new("int[1]")
function M.fd_avail(fd)
	if C.curse_rt_ioctl_int(fd, 0x541B, _avail) ~= 0 then -- FIONREAD
		return 0
	end
	return _avail[0]
end
function M.fd_rewind(fd, n)
	return C.curse_rt_lseek(fd, -n, 1) -- SEEK_CUR
end
-- A file the shell itself reads whole (`source`, `$(< file)`): like io.open(path, "r"),
-- but a FIFO whose writer may be in this process is read through M.ropen + M.co_block.
function M.open_read(path)
	M.rd_gen = M.rd_gen + 1 -- (`source /dev/stdin`, `$(< /dev/stdin)`: reads a shared input)
	if not (CO or sched_live()) or C.curse_rt_stat(path, _ropen_st) ~= 0
		or bit.band(ffi.cast("uint32_t *", _ropen_st + 24)[0], 0xF000) ~= 0x1000 then
		return io.open(path, "r")
	end
	local fd = M.ropen(path, 0, 0)
	if fd < 0 then
		return nil
	end
	local chunks, buf = {}, ffi.new("char[8192]")
	while true do
		M.co_block(fd, POLLIN)
		local n = tonumber(C.read(fd, buf, 8192))
		if not n or n <= 0 then
			break
		end
		chunks[#chunks + 1] = ffi.string(buf, n)
	end
	C.close(fd)
	local text = table.concat(chunks)
	return { read = function() return text end, close = function() end }
end
function M.ropen(path, flags, mode)
	if not (CO or sched_live()) or C.curse_rt_stat(path, _ropen_st) ~= 0
		or bit.band(ffi.cast("uint32_t *", _ropen_st + 24)[0], 0xF000) ~= 0x1000 then -- S_IFIFO
		return C.open(path, flags, mode)
	end
	local acc = bit.band(flags, 3)
	if acc == 2 then -- O_RDWR never blocks
		return C.open(path, flags, mode)
	end
	local t = co_task()
	local function tick()
		if t then
			pre_yield(t)
			if coroutine.yield(-1, 0) == SIGMARK then
				task_signals(t)
			end
		else
			M.sched_pump({ deadline = M.wall_secs() + 0.01 })
		end
	end
	local fd
	while true do
		fd = C.open(path, bit.bor(flags, 2048), mode) -- O_NONBLOCK
		if fd >= 0 or acc == 0 or ffi.errno() ~= 6 then -- (ENXIO: no reader yet)
			break
		end
		tick()
	end
	if fd < 0 then
		return fd
	end
	C.fcntl(fd, 4, ffi.cast("int", bit.band(C.fcntl(fd, 3), bit.bnot(2048)))) -- F_SETFL: blocking again
	if acc == 0 then
		M.co_block(fd, POLLIN) -- (a task yields on it; the shell runs the scheduler until it's ready)
	end
	return fd
end
local _temp_fd
do
local _hd_pipe = ffi.new("int[2]")
_temp_fd = function(content) -- the body on an O_RDONLY fd
	-- (like bash 5.2: a body that fits the pipe buffer goes through a pipe — no temp file;
	-- a larger one would block the write, so it takes a temp file)
	if #content < 65536 and C.pipe(_hd_pipe) == 0 then
		local r, w = _hd_pipe[0], _hd_pipe[1]
		local off, n = 0, #content
		while off < n do
			local k = tonumber(C.curse_co_write(w, ffi.cast("const char *", content) + off, n - off))
			if k <= 0 then
				if not (k < 0 and ffi.errno() == 4) then
					break
				end
			else
				off = off + k
			end
		end
		C.close(w)
		return r
	end
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
end
function M.body_fd(content) -- (the interpreter's here-docs too)
	return _temp_fd(content)
end
-- A redirection's open failed: bash's message, from errno (read right after the open).
-- noclobber's O_EXCL miss on a regular file is "cannot overwrite existing file".
function M.open_fail(sh, path)
	local e = ffi.errno()
	local msg = (e == 17 and sh.opt_C) and "cannot overwrite existing file" or ffi.string(C.strerror(e))
	io.stderr:write("curse: " .. path .. ": " .. msg .. "\n")
end
-- An all-digit `>&WORD` as a fd: legal_number + (int)lfd == lfd (redir.c), else -1 (EBADF) —
-- a huge number must not wrap onto a real fd.
function M.fd_number(s)
	local d = s:gsub("^0+", "")
	local n = #d < 11 and (tonumber(d) or 0) or -1
	return n > 2147483647 and -1 or n
end
function M.redir_apply(sh, op, fd, target, saves)
	io.flush() -- flush buffered stdout before moving fds (else it lands in the new target)
	-- In a pipeline stage, builtins write the redirected fd 1 directly while it's moved (as
	-- the interpreter does): the stage's buffer would reach it only at restore, too late
	-- for a write error (`echo x >/dev/full | …`) to be seen and reported by the command.
	if (fd == 1 or op == "outboth" or op == "appboth") and not saves.out_sh and CO_OUTS[sh.out] then
		saves.out_sh, saves.out = sh, sh.out
		sh.out = io.write
	end
	local function backup(f)
		saves[#saves + 1] = { fd = f, saved = M.save_fd(f) }
	end
	local function open_out(path) -- honor noclobber (set -C) for a truncating '>'
		if not sh.opt_C then
			return M.ropen(path, 577, 438)
		end -- O_WRONLY|O_CREAT|O_TRUNC
		local h = M.ropen(path, 705, 438) -- + O_EXCL
		if h >= 0 then
			return h
		end
		local e = ffi.errno() -- (for open_fail: a dangling symlink's stat miss is still EEXIST)
		if
			C.curse_rt_stat(path, _redir_stat) == 0
			and bit.band(ffi.cast("uint32_t *", _redir_stat + 24)[0], 0xF000) ~= 0x8000
		then
			return M.ropen(path, 1, 438) -- existing NON-regular (e.g. /dev/null): plain O_WRONLY
		end
		ffi.errno(e)
		return -1
	end
	if op == "out" or op == "clobber" then
		backup(fd)
		local h = (op == "out") and open_out(target) or M.ropen(target, 577, 438)
		if h < 0 then
			M.open_fail(sh, target)
			return false
		end
		if h ~= fd then
			C.dup2(h, fd)
			C.close(h)
		end
	elseif op == "app" then
		backup(fd)
		local h = M.ropen(target, 1089, 438) -- O_WRONLY|O_CREAT|O_APPEND
		if h < 0 then
			M.open_fail(sh, target)
			return false
		end
		if h ~= fd then
			C.dup2(h, fd)
			C.close(h)
		end
	elseif op == "in" then
		backup(fd)
		local h = M.ropen(target, 0, 0) -- O_RDONLY
		if h < 0 then
			M.open_fail(sh, target)
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
			M.open_fail(sh, target)
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
			local tf = M.fd_number(target) -- (emit hands only all-digit targets here)
			if tf == fd then -- `N>&N`: nothing to do, even on a closed N (redir.c)
				return true
			end
			if C.fcntl(tf, 1) == -1 then -- F_GETFD: target fd not open -> bash fails
				io.stderr:write("curse: " .. target .. ": Bad file descriptor\n")
				return false
			end
			backup(fd)
			C.dup2(tf, fd)
		end
	elseif op == "outboth" or op == "appboth" then -- &> / &>>
		backup(1)
		backup(2)
		local h = (op == "appboth") and M.ropen(target, 1089, 438) or open_out(target)
		if h < 0 then
			M.open_fail(sh, target)
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
-- `exec REDIRS`: the redirections persist, so the saved originals are just dropped (a kept
-- copy of a pipe's write end would hold its reader's EOF off forever)
function M.redir_discard(saves)
	if saves.out_sh then
		io.flush()
		saves.out_sh.out, saves.out_sh = saves.out, nil
	end
	for i = #saves, 1, -1 do
		if saves[i].saved >= 0 then
			C.close(saves[i].saved)
		end
		saves[i] = nil
	end
end
function M.redir_restore(saves)
	io.flush()
	if saves.out_sh then
		saves.out_sh.out, saves.out_sh = saves.out, nil
	end
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
-- A posix-mode non-interactive shell doesn't glob a redirection target (bash).
function M.redir_noglob(sh, f, ...)
	if not (sh.opt_posix and not sh.opt_i) or sh.opt_f then
		return pcall(f, ...)
	end
	sh.opt_f = true
	local ok, fs = pcall(f, ...)
	sh.opt_f = false
	return ok, fs
end
-- rt.redir_ext's catch (cx.redir_ext): the redirect conditions' pcall results
function M.redir_ext(sh, name, ok, res)
	if ok then
		return res
	end
	if type(res) ~= "table" or not res.__curse_exit or sh.functions[name]
		or (require("interp").BUILTINS[name] and not (sh.disabled_builtins and sh.disabled_builtins[name])) then
		error(res, 0) -- (a function or builtin runs in the shell itself: fatal)
	end
	return false
end
function M.redir_apply_expand(sh, op, fd, segs, raw, saves)
	local ok, fs
	if sh.opt_posix and not sh.opt_i then
		-- posix: no word splitting (redir.c: W_NOSPLIT) nor globbing — one string, $@ joined
		-- on a space; only an unquoted word expanding to nothing is ambiguous
		local t, q = {}, false
		for i, seg in ipairs(segs) do
			if seg.multi then
				t[i], q = table.concat(seg.elems, " "), q or seg.q
			else
				t[i], q = seg.s, q or not (seg.split or seg.unq)
			end
		end
		local w = table.concat(t)
		ok, fs = true, (w ~= "" or q) and { w } or {}
	else
		ok, fs = M.redir_noglob(sh, M.expand_fields, sh, segs)
	end
	if not ok then
		if type(fs) == "table" and fs.__curse_exit then -- (failglob: fatal like set -u —
			error(fs, 0) -- unless an external's rt.redir_ext absorbs it)
		end
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


-- A no-shebang script runs as a FRESH shell would (bash's reinitialized child: only the
-- exported environment, its own vars/functions/traps) — in-process: a new Shell, run
-- inside an isolation context of ours (its stack shared) so the process-global state the
-- script changes (cwd, umask, environ, fds, traps, rlimits) is put back when it ends.
-- `out`: where its stdout goes (a capture's sink), else fd 1.
function Shell:run_script_inproc(path, args, n, out)
	M.rd_gen = M.rd_gen + 1 -- (the script may be a shared input, /dev/stdin)
	local f = io.open(path, "r")
	local src = f and f:read("*a") or ""
	if f then
		f:close()
	end
	local child = Shell.new()
	-- (`exec`'s script: $0 is its -a NAME, else the full pathname — shell_execve)
	child.argv0, child.out = self.exec_builtin and (self.exec_script_a0 or path) or args[1], out or io.write
	child.capturing = out and true or nil
	child.shopt.globskipdots = self.shopt.globskipdots -- (reset_shopt_options keeps it)
	M.startup_ignored(child) -- a new shell: what's ignored now stays ignored
	if child.fimports then
		M.import_functions(child)
	end
	for k = 2, n do
		child.nparams = child.nparams + 1
		child.params[child.nparams] = args[k]
	end
	local csh = M.cur_shell
	local nous = M.env_drop_us -- (`exec`'s: the script's own commands get their `_`)
	M.env_drop_us = false
	self:subshell_run(function()
		child.iso_ctx = self.iso_ctx -- (its process-state saves land in our context)
		child.subdepth = self.subdepth
		M.cur_shell = child
		pcall(require("interp").run_lazy, child, src)
		M.cur_shell = csh
		io.flush()
	end)
	M.env_drop_us = nous
	M.cur_shell = csh
	self.status = child.status or 0
end
function Shell:run_noexec(path, args, n)
	self:run_script_inproc(path, args, n)
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
	if not (self.sigtraps and next(self.sigtraps)) and not CO then -- CO: SIGPIPE is blocked
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

-- An async command without job control runs with SIGINT/SIGQUIT ignored (bash's
-- setup_async_signals): a forked child just sets that.
-- `kill -SIG $$` from the shell itself: bash takes the signal after the builtin has
-- finished (its trap sees kill's status 0), so hold it blocked across the send; release
-- restores the previous mask, which delivers it. (Only SIG is touched: the scheduler
-- keeps SIGPIPE blocked meanwhile.)
do
	local set, old, held, hsig = ffi.new("uint8_t[1024]"), ffi.new("uint8_t[1024]"), false, 0
	local zero_ts = ffi.new("struct curse_co_ts", 0, 0)
	function M.self_sig_hold(sig)
		if held then
			return
		end
		C.sigemptyset(set)
		C.curse_co_sigaddset(set, sig)
		C.sigprocmask(0, set, old) -- SIG_BLOCK
		held, hsig = true, sig
	end
	-- Inside a trap handler the async delivery can't run another trap until the handler is
	-- done (the VM hook doesn't nest), but bash runs it right away, nested — even the same
	-- signal's own. So there, take the pending signal off the queue and run its trap here.
	function M.self_sig_release(sh)
		if held then
			held = false
			local h = sh and (sh.in_trap or 0) > 0 and sh.traps
				and sh.traps["SIG" .. (require("interp")._int.NUMSIG[hsig] or "")]
			local take = h and h ~= "" and C.curse_co_sigtimedwait(set, nil, zero_ts) == hsig
			C.sigprocmask(2, old, nil) -- SIG_SETMASK
			if take then
				require("interp").run_signal(sh, hsig, false, true)
			end
		end
	end
end
function M.async_child_signals(sh)
	if not sh.opt_m then
		C.curse_sig_ignore(2)
		C.curse_sig_ignore(3)
	end
end
-- A spawned one inherits it: the parent ignores both across the spawn, with them blocked
-- so none is lost meanwhile (a pending one is delivered to the restored disposition).
local _aq_set, _aq_old = ffi.new("uint8_t[1024]"), ffi.new("uint8_t[1024]")
local _aq_sa2, _aq_sa3 = ffi.new("uint8_t[256]"), ffi.new("uint8_t[256]")
C.sigemptyset(_aq_set)
C.curse_co_sigaddset(_aq_set, 2)
C.curse_co_sigaddset(_aq_set, 3)
local function async_spawn_hold(attr)
	C.sigprocmask(0, _aq_set, _aq_old) -- SIG_BLOCK
	C.curse_rt_sigaction(2, nil, _aq_sa2)
	C.curse_rt_sigaction(3, nil, _aq_sa3)
	C.curse_sig_ignore(2)
	C.curse_sig_ignore(3)
	if not attr then -- (the child's mask: the one from before the block)
		attr = ffi.new("uint8_t[1024]")
		if C.posix_spawnattr_init(attr) ~= 0 then
			return nil
		end
		C.posix_spawnattr_setsigmask(attr, _aq_old)
		C.posix_spawnattr_setflags(attr, SPAWN_SETSIGMASK)
	end
	return attr
end
local function async_spawn_release()
	C.curse_rt_sigaction(2, _aq_sa2, nil)
	C.curse_rt_sigaction(3, _aq_sa3, nil)
	C.sigprocmask(2, _aq_old, nil) -- SIG_SETMASK
end
ffi.cdef("int curse_rt_execve(const char *path, char *const argv[], char *const envp[]) asm(\"execve\");")
local _exec_emptyset = ffi.new("uint8_t[1024]")
C.sigemptyset(_exec_emptyset)
function Shell:exec(...)
	local args = { ... }
	local n = #args
	if n == 0 then
		self.status = 127
		return
	end
	if args[1] == "" then -- (`''` names no file: bash's ": command not found")
		self:errmsg("curse: " .. (self.exec_builtin and "exec: " or "") .. (self.exec_builtin and ": not found\n" or ": command not found\n"))
		self.status = 127
		return
	end
	-- Resolve a bare name to its (cached) $PATH location, but keep argv[0] = the
	-- name as typed. A command with a `/` is exec'd directly.
	local execpath = args[1]
	if self.opt_r and execpath:find("/", 1, true) then
		self:errmsg("curse: " .. execpath .. ": restricted: cannot specify `/' in command names\n")
		self.status = 1
		return
	end
	if not args[1]:find("/", 1, true) then
		execpath = self:resolve_cmd(args[1])
		if not execpath then
			-- bash: a defined command_not_found_handle runs instead, in a separate execution
			-- environment, with the command and its arguments; its status is the command's
			if not self.exec_builtin and self.functions.command_not_found_handle and not self.in_cnf_handle then
				self.in_cnf_handle = true -- (a miss inside the handler itself is just reported)
				local ok, err = pcall(self.subshell_run, self, function(sh)
					require("interp")._int.exec_simple(sh, { "command_not_found_handle", unpack(args, 1, n) }, function() end)
				end)
				self.in_cnf_handle = nil
				if not ok then
					error(err, 0)
				end
				return
			end
			-- (an unset/empty PATH searches only the cwd: bash then tries the bare name
			-- as a file, which is "No such file or directory")
			self:errmsg("curse: " .. (self.exec_builtin and "exec: " or "") .. M.err_name(args[1])
				.. (self.exec_builtin and ": not found\n" or self:get("PATH") == "" and ": No such file or directory\n"
					or ": command not found\n"))
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
	if not self.exec_noenv then
		C.setenv("_", execpath, 1) -- a program sees `_` = its own path (bash), not the shell's $_
	end
	if self.exec_argv0 then
		anchor.a0 = tostring(self.exec_argv0)
		argv[0] = anchor.a0
	end -- exec -a NAME
	-- Not capturing (self.out is the real fd 1, e.g. a top-level command or a
	-- pipeline stage): let the child write STRAIGHT to fd 1 (inherit fds) instead
	-- of buffering all its output — so an unbounded producer (`cat /dev/zero | …`)
	-- streams and SIGPIPE propagates, and there's no 2x-memory capture.
	if self.out == io.write or CO_OUTS[self.out] then
		io.flush() -- our own buffered stdout (and a pipeline stage's) must reach fd 1 first
		-- exec_tail: this external is the LAST thing a forked child does (`cmd &`), so replace
		-- the child with it — one process, like bash — instead of spawning a grandchild and
		-- waiting. Same signal state a spawned child gets (clean mask; caught handlers reset
		-- by execve itself). Returns only on failure.
		if self.exec_tail and self.exec_tail == C.getpid() then -- armed by THIS process only
			self.exec_tail = nil
			C.sigprocmask(2, _exec_emptyset, nil) -- SIG_SETMASK
			C.curse_rt_execve(execpath, ffi.cast("char *const *", argv), M.child_env())
			local e = ffi.errno()
			if e == 8 then -- ENOEXEC: no-shebang script — run it through our interpreter
				return self:run_noexec(execpath, args, n)
			end
			self:errmsg("curse: " .. (self.exec_builtin and "exec: " or "") .. M.err_name(tostring(args[1])) .. (e == 2 and (self.exec_builtin and ": not found\n" or ": command not found\n") or ": Permission denied\n"))
			self.status = (e == 2) and 127 or 126
			return
		end
		local pidp = ffi.new("curse_pid_t[1]")
		local attr = child_spawnattr(self)
		local fa = M.foreign_fa(self, nil)
		M.rd_gen = M.rd_gen + 1 -- (a new process may read our input: see M.pipe_cache)
		local cenv = M.child_env() -- (bash's order; kept alive across the call)
		local rc = C.posix_spawnp(pidp, execpath, fa, attr, ffi.cast("char *const *", argv), cenv)
		if fa then
			C.posix_spawn_file_actions_destroy(fa)
		end
		if attr then
			C.posix_spawnattr_destroy(attr)
		end
		if rc == 8 then
			return self:run_noexec(execpath, args, n)
		end -- no shebang: run as a script
		if rc ~= 0 then
			self:errmsg(M.spawn_errmsg(self, args[1], execpath, rc))
			self.status = (rc == 2) and 127 or 126
			return
		end
		local st = ffi.new("int[1]")
		M.wait_child(pidp[0], st, 0)
		self.status = M.wexit(st[0])
		return
	end
	local fds = ffi.new("int[2]")
	if M.pipe_hi(fds) ~= 0 then
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
	M.foreign_fa(self, fa)
	local pidp = ffi.new("curse_pid_t[1]")
	local attr = child_spawnattr(self)
	M.rd_gen = M.rd_gen + 1 -- (a new process may read our input: see M.pipe_cache)
	local cenv = M.child_env() -- (bash's order; kept alive across the call)
	local rc = C.posix_spawnp(pidp, execpath, fa, attr, ffi.cast("char *const *", argv), cenv)
	if attr then
		C.posix_spawnattr_destroy(attr)
	end
	C.posix_spawn_file_actions_destroy(fa)
	local pid = pidp[0]
	if rc == 8 then -- ENOEXEC: no-shebang script — our interpreter runs it, into the capture
		C.close(wfd)
		C.close(rfd)
		self:run_script_inproc(execpath, args, n, self.out)
		return
	end
	C.close(wfd)
	if rc ~= 0 and rc ~= 8 then -- ENOENT -> "command not found" (127); else can't-execute (126)
		C.close(rfd)
		self:errmsg(M.spawn_errmsg(self, args[1], execpath, rc))
		self.status = (rc == 2) and 127 or 126
		return
	end
	local buf = ffi.new("char[65536]")
	local chunks = {}
	while true do
		M.co_block(rfd, POLLIN)
		local nr = C.read(rfd, buf, 65536)
		if nr <= 0 then
			break
		end
		chunks[#chunks + 1] = ffi.string(buf, nr)
	end
	C.close(rfd)
	local st = ffi.new("int[1]")
	M.wait_child(pid, st, 0)
	self.status = M.wexit(st[0])
	local out = table.concat(chunks)
	if out ~= "" then
		self.out(out)
	end
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

function Shell:capture_src(src, backtick, noalias)
	local P = require("parser")
	local I = require("interp")
	-- A SYNTAX error in the body: bash makes `$(…)` fatal to the whole containing
	-- command, but a backtick `…` only PRINTS the error and yields "" (non-fatal —
	-- `echo A``echo "``B` prints "AB" and exits 0). Backticks are parsed lazily at
	-- expansion time, so a throw here (e.g. an unterminated quote) is contained.
	-- self: $()/`` expand aliases from the live table (unless already expanded as read)
	local pok, parsed = pcall(P.parse, src, self, nil, noalias, nil, self.cur_cline or self.cur_line)
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
			-- (the file word expands like a redirection target: globbed, except in posix
			-- mode, and it must name exactly one file)
			self.ncs = (self.ncs or 0) + 1 -- (a substitution performed: see capture_inproc)
			local raw = st.redirs[1].src or st.redirs[1].target or "" -- (as written: quotes kept)
			local eok, fs = M.redir_noglob(self, I.expand_to_fields, self, P.parse_word(raw))
			if not eok then
				self.status, self.last_cmdsub_status = 1, 1
				return ""
			end
			if #fs ~= 1 then
				io.stderr:write("curse: " .. raw .. ": ambiguous redirect\n")
				self.status, self.last_cmdsub_status = 1, 1
				return ""
			end
			local path = fs[1]
			local f = path ~= "" and M.open_read(path)
			if f then
				local c = f:read("*a") or ""
				f:close()
				self.status, self.last_cmdsub_status = 0, 0
				return (M.cmdsub_nul(c):gsub("\n+$", ""))
			end
			io.stderr:write("curse: " .. path .. ": No such file or directory\n")
			self.status, self.last_cmdsub_status = 1, 1
			return ""
		end
	end
	-- Full subshell isolation (checkpoint/restore, in-process) UNLESS the body is provably
	-- pure — a pure body has no shell-state side effects to leak, so it runs with just the
	-- light $() state (the common `$(cmd)`/`$(echo …)` case). $BASHPID/$RANDOM are
	-- per-subshell, so a body reading them is isolated too.
	local iso = src:find("BASHPID", 1, true) ~= nil or src:find("RANDOM", 1, true) ~= nil
	local has_perr = false
	for _, st in ipairs(ast.stmts) do
		if st.t == "parse_error" then
			has_perr = true
		end
		if not capture_pure(self, st) then
			iso = true
		end
	end
	-- (a SYNTAX error in the body is fatal to the CONTAINING command — bash — which the
	-- light path propagates via __curse_parseerr)
	if iso and not has_perr then
		return self:capture_compiled_iso(function(self)
			local Iq = require("interp")
			return Iq.exec_list(self, ast.stmts, Iq.SUBHOOK, true)
		end, backtick)
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
-- `capfd`: capture at the FD level — point fd 1 at a temp file so a builtin's stdout
-- (via sh.out=io.write), an external's stdout (inherited fd 1), AND a redirect like
-- `2>&1` (kernel dup of fd 2 onto fd 1) all land in the SAME sink, in order — exactly
-- like a forked child, but without the fork. The default (buffer) is faster and is used
-- for pure bodies (no stderr/2>&1 to worry about); the fd path is for isolated mutating
-- $() where a builtin may redirect its diagnostics into the capture. A temp file (not a
-- pipe) means no self-deadlock when the body out-writes the pipe buffer in one process.
local deferred_sigs, cap_depth, cap_pid, flush_deferred, cap_enter -- (the signal hold: see M.defer_signal)
function Shell:capture_inproc(backtick, runner, capfd, ctx)
	local buf, tmp, save1
	if capfd then
		io.flush()
		tmp = os.tmpname()
		local tfd = C.open(tmp, 577, 384) -- O_WRONLY|O_CREAT|O_TRUNC, 0600
		if tfd < 0 then
			capfd = false
		else
			save1 = M.save_fd(1)
			C.dup2(tfd, 1)
			C.close(tfd)
		end
	end
	local sv_sink = self.cap_sink
	self.cap_sink = capfd and M.fd_ident(1) or nil
	local saved = self.out
	local saved_cap = self.capturing
	if capfd then
		self.out = io.write -- builtins write to fd 1 (= temp file); externals inherit it
		self.capturing = nil -- fd 1 IS the sink, so don't also drain into a Lua buffer
	else
		buf = {}
		self.out = function(x)
			buf[#buf + 1] = x
		end
		self.capturing = true -- last pipeline stage drains into buf
	end
	self.in_subprogram = (self.in_subprogram or 0) + 1 -- $(...) is a subprogram: ERR trap suppressed
	local saved_ld = self.loopdepth -- ($(…) inside a loop knows it: a break/continue there
	-- ends the substitution, as it ends a `( … )` — bash)
	local savede = self.opt_e
	if not (self.opt_posix or (self.shopt and self.shopt.inherit_errexit)) then
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
	local sv_xd, sv_depth = self.xdepth, self.subdepth
	self.xdepth = (sv_xd or 0) + 1 -- xtrace: PS4's first char repeats per $(…) level
	self.subdepth = (sv_depth or 0) + 1
	local sv_cj = self.cap_jobs
	self.cap_jobs = {}
	cap_enter()
	local ok, err = pcall(runner, self)
	if #self.cap_jobs > 0 then
		M.wait_groups(self.cap_jobs)
	end
	self.cap_jobs, self.cap_sink = sv_cj, sv_sink
	if cap_pid == C.getpid() then
		cap_depth = cap_depth - 1 -- (a held signal is raised once the capture is done, below)
	end
	self.xdepth, self.subdepth = sv_xd, sv_depth
	if ctx and ctx.pid == C.getpid() then
		if not ok and type(err) == "table" and err.__curse_vsig == ctx then
			err = { __curse_exit = 128 + err.sig } -- (`kill $BASHPID`: the substitution dies)
		end
		local cst = ok and self.status or (type(err) == "table" and (err.__curse_exit or err.__curse_return))
		if cst then -- its own EXIT trap runs last, still captured
			local nst = M.iso_exit_trap(self, ctx, cst, err)
			if nst ~= cst then
				ok, err = false, { __curse_exit = nst }
			end
		end
		M.iso_restore_fds(ctx) -- (`exec 4>&1` in the body: undone while fd 1 is still the capture)
	end
	self.aliases = saved_aliases -- discard aliases defined inside $()
	self.cur_line = saved_line
	self.opt_e = savede
	self.loopdepth = saved_ld
	self.in_subprogram = self.in_subprogram - 1
	self.capturing = saved_cap
	self.out = saved
	if capfd then
		io.flush()
		C.dup2(save1, 1)
		C.close(save1) -- put the real fd 1 back before reading the temp file
	end
	local function readcap() -- the captured bytes, from the buffer or the temp file
		if not capfd then
			return table.concat(buf)
		end
		local f = io.open(tmp, "r")
		local c = f and f:read("*a") or ""
		if f then
			f:close()
		end
		os.remove(tmp)
		return c
	end
	if not ok then
		if type(err) == "table" and err.__curse_parseerr then
			if backtick then
				self.status = 1
				readcap()
				return ""
			end -- backtick: contained (non-fatal)
			readcap() -- drop the temp file, then propagate
			error(err) -- a SYNTAX error inside $(…) is fatal to the whole containing command (bash)
		elseif type(err) == "table" and (err.__curse_exit or err.__curse_return) then
			self.status = err.__curse_exit or err.__curse_return
		elseif type(err) == "table" and (err.__curse_break or err.__curse_continue) then
			self.status = err.__curse_status or 0 -- (it just ends the substitution)
		else
			readcap()
			error(err)
		end
	end
	self.last_cmdsub_status = self.status -- for a command whose argv is empty after expansion
	self.ncs = (self.ncs or 0) + 1 -- (substitutions performed: an assignment's status is the last one's)
	-- bash strips NUL bytes from command-substitution output ("ignored null byte")
	local r = M.cmdsub_nul(readcap()):gsub("\n+$", "")
	flush_deferred(self)
	return r
end

-- Deep-copy a variable box (every attribute flag + fresh array/order tables) so an
-- in-process subshell mutates its OWN copy, never the parent's box. The parent boxes
-- stay pristine, so a `local`/tempenv shadow that still references one is valid after
-- the subshell restores.
local function copybox(b)
	if rawget(b, "virt") then
		return b -- (a view of the alias/hash tables, which are checkpointed themselves)
	end
	local nb = {
		s = b.s, n = b.n, assoc = b.assoc, exported = b.exported, ref = b.ref,
		lower = b.lower, upper = b.upper, cap = b.cap, ro = b.ro, int = b.int, empty_decl = b.empty_decl, trace = b.trace,
	}
	if b.arr then
		local a = {}
		for k, v in pairs(b.arr) do a[k] = v end
		nb.arr = a
	end
	if b.order then
		local o = {}
		for k, v in pairs(b.order) do o[k] = v end
		nb.order = o
	end
	return nb
end
-- getopts' in-argument position lives per OPTIND BOX (so a function-local OPTIND has its
-- own and the caller's comes back on return, as in bash). Re-key it onto copied boxes.
function M.getopts_remap(st, from, to)
	if not st then
		return nil
	end
	local r = setmetatable({}, { __mode = "k" })
	for name, b in pairs(from) do
		if st[b] and to[name] then
			r[to[name]] = st[b]
		end
	end
	return r
end
local function shallowcopy(t)
	if t == nil then return nil end
	local c = {}
	for k, v in pairs(t) do c[k] = v end
	return c
end

-- CHECKPOINT the process/shell state a forked subprogram (`( … )` or `$(…)`) isolates
-- for free but an in-process run would leak: variables (DEEP-copied boxes — the copy is
-- the WORKING table, the ORIGINAL boxes stay pristine so any local/tempenv box reference
-- stays valid), positional params, shopt, functions, dirstack, hashcache, getopts state,
-- cwd + umask (via real syscalls). Returns a token for sub_restore. NOT here (each caller
-- differs): out, opt_e, in_subprogram, loopdepth, noerr, aliases, cur_line, and the
-- process environ — which sub_restore re-syncs for exported names.
-- Every `set` option field (set -e/-u/-x/-o pipefail/…): a subshell's `set` changes only
-- these (plus params, checkpointed too), so snapshotting them lets `set` run in-process.
local OPT_FIELDS
local function opt_fields()
	if not OPT_FIELDS then
		local seen = {}
		OPT_FIELDS = {}
		for _, f in pairs(M.SETOPT) do
			if not seen[f] then seen[f] = true; OPT_FIELDS[#OPT_FIELDS + 1] = f end
		end
		for _, f in pairs(M.SETFLAG) do
			if not seen[f] then seen[f] = true; OPT_FIELDS[#OPT_FIELDS + 1] = f end
		end
	end
	return OPT_FIELDS
end
M.opt_fields = opt_fields
local iso_push, iso_pop
local function sub_checkpoint(self)
	local orig_vars = self.vars
	local copy = {}
	for k, b in pairs(orig_vars) do copy[k] = copybox(b) end
	self.vars = copy
	local exset = {}
	for name, b in pairs(orig_vars) do
		if b.exported then exset[name] = true end
	end
	local pcopy = {}
	for i = 1, self.nparams do pcopy[i] = self.params[i] end
	local cp = {
		orig_vars = orig_vars, copy = copy, exset = exset,
		params = self.params, nparams = self.nparams,
		shopt = self.shopt, functions = self.functions,
		locale_gen = M.locale_gen, dirstack = self.dirstack, hashcache = self.hashcache, getopts = self.getopts_state,
		cwd = self:phys_cwd(), tcwd = self.tcwd, um = C.umask(0), disabled = self.disabled_builtins,
		fn_ro = self.fn_ro, unset_specials = self.unset_specials, random_plain = self.random_plain,
		shellopts_exported = self.shellopts_exported,
	}
	self.fn_ro, self.unset_specials = shallowcopy(self.fn_ro), shallowcopy(self.unset_specials)
	self.disabled_builtins = shallowcopy(self.disabled_builtins)
	C.umask(cp.um)
	local of, ov = opt_fields(), {}
	for i = 1, #of do ov[i] = self[of[i]] end
	cp.opts = ov
	-- The dynamic-scope layers behind the visible vars — `local` shadow records and
	-- tempenv bindings — are mutated by `unset` (which REVEALS the next layer: drops the
	-- record / marks the tempenv consumed and installs its box). Give the body private
	-- copies (records AND the shadowed boxes they hold) so neither escapes.
	cp.savedstack, cp.tenv = self.savedstack, self.tenv
	local ss = {}
	for d, rec in pairs(self.savedstack) do
		if rec then
			local r2 = {}
			for name, e in pairs(rec) do
				local e2 = shallowcopy(e)
				if e2.box then e2.box = copybox(e2.box) end
				r2[name] = e2
			end
			ss[d] = r2
		else
			ss[d] = rec
		end
	end
	self.savedstack = ss
	local te = {}
	for k = 1, #self.tenv do
		local e2 = shallowcopy(self.tenv[k])
		if e2.box then e2.box = copybox(e2.box) end
		te[k] = e2
	end
	self.tenv = te
	self.params = pcopy
	self.shopt = shallowcopy(self.shopt) or {}
	self.functions = shallowcopy(self.functions) or {}
	self.getopts_state = M.getopts_remap(self.getopts_state, orig_vars, copy)
	self.dirstack = shallowcopy(self.dirstack)
	self.hashcache = shallowcopy(self.hashcache)
	return cp
end
local function sub_restore(self, cp)
	self.vars = cp.orig_vars
	if cp.locale_gen ~= M.locale_gen then -- (`(LANG=C; …)`: setlocale is process-wide)
		M.reset_locale(self)
	end
	self.params, self.nparams = cp.params, cp.nparams
	self.shopt, self.functions = cp.shopt, cp.functions
	self.dirstack, self.hashcache, self.getopts_state = cp.dirstack, cp.hashcache, cp.getopts
	local of, ov = opt_fields(), cp.opts
	for i = 1, #of do self[of[i]] = ov[i] end
	self.savedstack, self.tenv = cp.savedstack, cp.tenv
	self.disabled_builtins = cp.disabled
	self.fn_ro, self.unset_specials, self.random_plain = cp.fn_ro, cp.unset_specials, cp.random_plain
	self.shellopts_exported = cp.shellopts_exported
	if cp.cwd ~= "" then C.chdir(cp.cwd) end
	self.tcwd = cp.tcwd
	C.umask(cp.um)
	-- Re-sync the process environ: drop names the body newly exported, then restore
	-- every name exported at entry to its parent value (covers changed + unset-in-sub).
	for name, b in pairs(cp.copy) do
		if b.exported and not cp.exset[name] then C.unsetenv(name) end
	end
	for name in pairs(cp.exset) do
		C.setenv(name, self:get(name) or "", 1)
	end
end

-- Run a subshell body `runner(sh)` IN-PROCESS (no fork) — the compiled tier's fork-free
-- `( … )`. sub_checkpoint/restore reproduce a fork's isolation; a subshell keeps errexit
-- (unlike $()), writes to the live stdout, and its own applied redirects (`saves`) are
-- restored here too. exit/return/div0 in the body become the subshell's status. The emit
-- gate keeps genuinely-forking bodies (trap/exec/&/set/ulimit/$BASHPID/…) on the fork path.
-- LATE FORK. An in-process subshell/$(…) runs optimistically in this process; the first
-- operation that genuinely needs its own process (exec, ulimit, trap, enable, wait, `&`,
-- a dynamic $BASHPID/$RANDOM read — see need_process) forks RIGHT THERE: everything so far
-- happened inside the checkpoint, i.e. exactly the state a real subshell has at this point,
-- so the child simply continues (it IS the subshell now) and _exits at the boundary; the
-- parent waits, unwinds to the boundary with the child's status and restores. iso_ctx is
-- the stack of active in-process isolation contexts (innermost last).
iso_push = function(sh)
	-- the pid that runs this context in-process: a process forked later (a real subshell /
	-- $(…) / stage / job) inherits the stack but is ALREADY its own process
	local ctx = { pid = C.getpid() }
	local st = sh.iso_ctx
	if not st then
		st = {}
		sh.iso_ctx = st
	end
	st[#st + 1] = ctx
	return ctx
end
-- The in-process context this process is running right now (innermost), or nil.
local function iso_cur(sh)
	local st = sh.iso_ctx
	local ctx = st and st[#st]
	if ctx and ctx.pid == C.getpid() then
		return ctx
	end
end
M.iso_cur = iso_cur

-- PROCESS-GLOBAL state an in-process subshell changes is saved the first time the body
-- touches it and put back when the context ends (iso_undo): fds 0-9 (`exec` redirections),
-- the whole environ (`exec -c`, exec's prefix bindings), signal traps + dispositions,
-- resource limits, the $RANDOM stream.
function M.iso_save_fds(sh)
	local ctx = iso_cur(sh)
	if not ctx or ctx.fds or ctx.task_fds then -- (a task's fds are its own: nothing to restore)
		return
	end
	io.flush()
	local sv = {}
	for fd = 0, 9 do
		sv[fd] = dup_hi(fd) -- (-1: closed)
	end
	ctx.fds = sv
end
function M.iso_save_env(sh)
	local ctx = iso_cur(sh)
	if not ctx or ctx.env then
		return
	end
	local t, e, i = {}, C.environ, 0
	while e ~= nil and e[i] ~= nil do
		t[#t + 1] = ffi.string(e[i])
		i = i + 1
	end
	ctx.env = t
end
-- A subshell's traps: caught signals revert to the default (still listed by `trap -p`
-- until changed), ignored ones stay ignored, the EXIT trap isn't its own. The real
-- handlers stay installed — the process is still the parent's, and a signal sent to it
-- is the parent's (deferred: see M.defer_signal).
function M.iso_save_traps(sh)
	local ctx = iso_cur(sh)
	if not ctx or ctx.traps then
		return
	end
	ctx.traps = {
		owner = sh, -- (whose tables these are: a no-#! script's fresh shell shares our context)
		traps = sh.traps, sigtraps = sh.sigtraps, inh = M.exit_trap_inherited,
		esp = sh.err_trap_sp, dsp = sh.dbg_trap_sp, rsp = sh.ret_trap_sp,
		run = rawget(_G, "__curse_sigrun"), inexit = sh.in_exit_trap,
	}
	sh.traps = shallowcopy(sh.traps) or {}
	local kept
	for canon in pairs(sh.sigtraps or {}) do
		if sh.traps[canon] == "" then
			kept = kept or {}
			kept[canon] = true
		end
	end
	sh.sigtraps = kept
	M.exit_trap_inherited = true
	ctx.traps.fresh = true
end
-- Is the EXIT trap in sh.traps this (sub)shell's own — one it set — rather than one it
-- inherited (a forked child's, or an in-process subshell's before its first `trap`)?
function M.exit_trap_own(sh)
	if M.exit_trap_inherited then
		return false
	end
	local ctx = iso_cur(sh)
	return not ctx or ctx.traps ~= nil
end
-- The first trap a subshell sets or resets drops the inherited trap strings `trap -p` still
-- listed (bash): all but the ignored signals'.
function M.iso_trap_changed(sh)
	local ctx = iso_cur(sh)
	if ctx and ctx.traps and ctx.traps.fresh then
		ctx.traps.fresh = nil
		for canon, v in pairs(sh.traps) do
			if v ~= "" then
				sh.traps[canon] = nil
			end
		end
	end
end
for _, d in ipairs({ "int curse_sig_catch(int signum);", "int curse_sig_default(int signum);",
	"int curse_sig_ignore(int signum);", "int kill(int pid, int sig);", "int clearenv(void);" }) do
	pcall(ffi.cdef, d) -- (interp declares these too, when loaded)
end
ffi.cdef([[
  struct curse_iso_rlimit { unsigned long cur, max; };
  int curse_iso_getrlimit(int res, struct curse_iso_rlimit *r) asm("getrlimit");
  int curse_iso_setrlimit(int res, const struct curse_iso_rlimit *r) asm("setrlimit");
]])
function M.iso_save_rlimits(sh)
	local ctx = iso_cur(sh)
	if not ctx or ctx.rlim then
		return ctx
	end
	local sv = {}
	for r = 0, 15 do
		local rl = ffi.new("struct curse_iso_rlimit")
		if C.curse_iso_getrlimit(r, rl) == 0 then
			sv[r] = rl
		end
	end
	ctx.rlim, ctx.vhard = sv, {}
	return ctx
end
-- The hard limit a subshell set (kept virtual: lowering a real hard limit can't be undone)
function M.iso_vhard(sh, res)
	local st = sh.iso_ctx
	for i = st and #st or 0, 1, -1 do
		local v = st[i].vhard and st[i].vhard[res]
		if v then
			return v
		end
	end
	return sh.iso_vhard_base and sh.iso_vhard_base[res] -- (a stage: its subshell's, stage_clone)
end

-- Virtual pids: $BASHPID of an in-process subshell. Above the kernel's pid_max, so no
-- real process ever has one; `kill` recognizes them (M.vkill).
local vpid_next
M.vpid_ctx = setmetatable({}, { __mode = "v" })
function M.alloc_vpid()
	if not vpid_next then
		local f = io.open("/proc/sys/kernel/pid_max", "r")
		local m = f and tonumber(f:read("*l"))
		if f then
			f:close()
		end
		vpid_next = (m or 4194304) + 1
	end
	local v = vpid_next
	vpid_next = v + 1
	return v
end
function Shell:bashpid()
	local ctx = iso_cur(self)
	if ctx then
		if not ctx.vpid then
			ctx.vpid = M.alloc_vpid()
			M.vpid_ctx[ctx.vpid] = ctx
		end
		return ctx.vpid
	end
	if self.stage_pid and self.stage_pid == C.getpid() then -- an in-process pipeline stage
		self.vpid = self.vpid or M.alloc_vpid()
		return self.vpid
	end
	return tonumber(C.getpid())
end

-- A real signal arriving while an in-process subshell runs was sent to the PARENT (the
-- subshell has no pid of its own): hold it and raise it again once the last in-process
-- context has ended, so the parent's trap (or default action) handles it — after the
-- subshell, as a parent waiting on a real child would.
cap_depth = 0 -- in-process $(…) bodies running (any path), in process cap_pid
function M.defer_signal(sh, sig)
	if not (iso_cur(sh) or (cap_depth > 0 and cap_pid == C.getpid())) then
		return false
	end
	deferred_sigs = deferred_sigs or {}
	deferred_sigs[sig] = true
	return true
end
flush_deferred = function(sh)
	if deferred_sigs and not iso_cur(sh) and not (cap_depth > 0 and cap_pid == C.getpid()) then
		local d = deferred_sigs
		deferred_sigs = nil
		for sig in pairs(d) do
			C.kill(C.getpid(), sig)
		end
	end
end
cap_enter = function()
	local pid = C.getpid()
	if cap_pid ~= pid then -- (a forked child starts its own count)
		cap_pid, cap_depth = pid, 0
	end
	cap_depth = cap_depth + 1
end


-- (a $(…) puts its fds back BEFORE its capture restores fd 1 — see capture_inproc)
function M.iso_restore_fds(ctx)
	local sv = ctx.fds
	if sv then
		ctx.fds = nil
		io.flush()
		for fd = 0, 9 do
			local d = sv[fd]
			if d >= 0 then
				C.dup2(d, fd)
				C.close(d)
			else
				C.close(fd)
			end
		end
	end
end
local function iso_undo(sh, ctx)
	if ctx.traps then
		local sv = ctx.traps
		local o = sv.owner or sh
		local I = package.loaded.interp
		local SIGNUM = I and I._int.SIGNUM or {}
		local seen = {}
		for canon in pairs(o.sigtraps or {}) do
			seen[canon] = true
		end
		for canon in pairs(sv.sigtraps or {}) do
			seen[canon] = true
		end
		for canon in pairs(seen) do
			local num = SIGNUM[canon:match("^SIG(.+)$") or ""]
			if num then
				if sv.sigtraps and sv.sigtraps[canon] then
					if sv.traps[canon] == "" then
						C.curse_sig_ignore(num)
					else
						C.curse_sig_catch(num)
					end
				else
					C.curse_sig_default(num)
				end
			end
		end
		o.traps, o.sigtraps = sv.traps, sv.sigtraps
		M.exit_trap_inherited, o.err_trap_sp, o.in_exit_trap = sv.inh, sv.esp, sv.inexit
		o.dbg_trap_sp, o.ret_trap_sp = sv.dsp, sv.rsp
		_G.__curse_sigrun = sv.run
	end
	M.iso_restore_fds(ctx)
	if ctx.env then
		C.clearenv()
		for _, kv in ipairs(ctx.env) do
			local k, v = kv:match("^([^=]*)=(.*)$")
			if k then
				C.setenv(k, v, 1)
			end
		end
	end
	if ctx.rlim then
		for r, rl in pairs(ctx.rlim) do
			local cur = ffi.new("struct curse_iso_rlimit")
			if C.curse_iso_getrlimit(r, cur) == 0 then
				rl.max = cur.max -- (a hard limit can't be raised back; it was never lowered)
				if rl.cur > rl.max then
					rl.cur = rl.max
				end
				C.curse_iso_setrlimit(r, rl)
			end
		end
	end
	if ctx.rand then
		sh.rseed, sh.rlast, sh.rpid = ctx.rand[1], ctx.rand[2], ctx.rand[3]
	end
	if ctx.vpid then
		M.vpid_ctx[ctx.vpid] = nil
	end
end

iso_pop = function(sh, ctx)
	local st = sh.iso_ctx
	if st and st[#st] == ctx then
		st[#st] = nil
	end
	if ctx.pid == C.getpid() then
		iso_undo(sh, ctx)
		flush_deferred(sh)
	end
end

-- The EXIT trap a subshell set itself runs when it ends (never an inherited one, nor
-- after `exec CMD`); `exit N` inside it sets the status. Returns the status.
function M.iso_exit_trap(sh, ctx, status, err)
	if not (ctx and ctx.traps) or (ctx.traps.owner or sh) ~= sh or M.exit_trap_inherited
		or (type(err) == "table" and err.__curse_noexittrap) then
		return status
	end
	local h = sh.traps and sh.traps.EXIT
	if not h or h == "" or sh.in_exit_trap then
		return status
	end
	sh.in_exit_trap = true
	sh.status = status
	local sl = sh.cur_line
	sh.cur_line = 1 -- (bash: the EXIT trap's $LINENO counts from 1)
	local ok, r = pcall(require("interp").run_trap_str, sh, h)
	sh.cur_line = sl
	sh.in_exit_trap = nil
	if ok and r then
		status = sh.status -- `exit N` in the trap wins
	elseif not ok and type(r) == "table" and r.__curse_exit then
		status = r.__curse_exit
	end
	return status
end

-- `kill` aimed at a virtual pid: the in-process subshell gets the signal. Returns false
-- when no such (live) subshell exists.
M.vpid_tasks = setmetatable({}, { __mode = "v" })
function M.vkill(sh, pid, sig)
	local ctx = M.vpid_ctx[pid]
	local bt = (ctx and ctx.task) or M.vpid_tasks[pid]
	if bt then -- a background job
		return M.task_kill(bt, sig)
	end
	local st = sh.iso_ctx
	local at
	for i = st and #st or 0, 1, -1 do
		if st[i] == ctx then
			at = i
		end
	end
	if not at or ctx.pid ~= C.getpid() then
		return false
	end
	if sig == 0 then
		return true
	end
	if at ~= #st then -- an enclosing subshell: it takes the signal when it resumes
		ctx.pending = ctx.pending or {}
		ctx.pending[#ctx.pending + 1] = sig
		return true
	end
	M.iso_signal(sh, ctx, sig)
	return true
end
local SIG_DEFAULT_IGNORE = { [17] = true, [18] = true, [23] = true, [28] = true } -- CHLD CONT URG WINCH
local SIG_STOP = { [19] = true, [20] = true, [21] = true, [22] = true }
function M.iso_signal(sh, ctx, sig)
	local I = require("interp")
	local canon = "SIG" .. (I._int.NUMSIG[sig] or "")
	local disp = "default"
	if sig ~= 9 and sh.sigtraps and sh.sigtraps[canon] then
		if sh.traps[canon] == "" then
			disp = "ignore"
		elseif ctx.traps then -- (the subshell's own trap; an inherited one reads as default)
			disp = "trap"
		end
	elseif sig == 2 and ctx.igint then -- (an async job's, even once reset: its original)
		disp = "ignore"
	end
	if disp == "ignore" or (disp == "default" and (SIG_DEFAULT_IGNORE[sig] or SIG_STOP[sig])) then
		return
	end
	if disp == "trap" then
		return I.run_signal(sh, sig, true)
	end
	error({ __curse_vsig = ctx, sig = sig }, 0) -- the default action: the subshell dies
end
-- A forked subshell child ends: run an EXIT trap the SUBSHELL set (never the inherited
-- parent one), with $? = its status, then _exit.
-- Signals IGNORED when the shell starts can't be trapped or reset (bash), and `trap` lists
-- them as `trap -- '' SIGx`. `mask` (bit n-1 = signal n) comes from the daemon client (the
-- caller's dispositions, which a resident worker doesn't share); without it, read this
-- process's own (a direct run, or a no-shebang script's forked child).
ffi.cdef("int curse_rt_sigaction(int sig, const void *act, void *old) asm(\"sigaction\");")
local _sa_buf = ffi.new("uint8_t[256]") -- struct sigaction (sa_handler first)
-- This process's ignored signals as a mask (bit n-1 = signal n).
function M.sig_ign_mask()
	local mask = 0
	for n = 1, 31 do
		if n ~= 9 and n ~= 19 and C.curse_rt_sigaction(n, nil, _sa_buf) == 0
			and ffi.cast("intptr_t *", _sa_buf)[0] == 1 then -- SIG_IGN
			mask = bit.bor(mask, bit.lshift(1, n - 1))
		end
	end
	return mask
end
-- Set every catchable signal's disposition to exactly `mask`: ignored or default.
function M.sig_apply_mask(mask)
	for n = 1, 31 do
		if n ~= 9 and n ~= 19 then
			if bit.band(mask, bit.lshift(1, n - 1)) ~= 0 then
				C.curse_sig_ignore(n)
			else
				C.curse_sig_default(n)
			end
		end
	end
end
function M.startup_ignored(sh, mask)
	mask = mask or M.sig_ign_mask()
	if mask == 0 then
		return
	end
	local NUMSIG = require("interp")._int.NUMSIG
	for n = 1, 31 do
		if bit.band(mask, bit.lshift(1, n - 1)) ~= 0 and NUMSIG[n] then
			local canon = "SIG" .. NUMSIG[n]
			sh.sig_ign_start = sh.sig_ign_start or {}
			sh.sig_ign_start[canon] = true
			sh.traps[canon] = ""
		end
	end
end
-- DEBUG trap across a function call (bash execute_function): a function that is neither
-- traced (`declare -ft`) nor under functrace does NOT inherit the DEBUG trap — it's cleared
-- for the call and put back on return, unless the body set its own (which then persists).
-- So a trap set INSIDE the function fires for the rest of it. Returns the saved handler.
-- A function without functrace (`set -T` / `declare -ft`) doesn't inherit the DEBUG
-- and RETURN traps: they're hidden for its body (bash's execute_function) and restored on
-- the way out. Returns what debug_leave puts back.
function M.debug_enter(sh, name)
	local d, r, e = sh.traps.DEBUG, sh.traps.RETURN, sh.traps.ERR
	sh.err_skip = nil
	if d == nil and r == nil and e == nil then
		return nil
	end
	-- In a subshell/$( ) the ones it inherited aren't TRAPPED (only listed), so there's
	-- nothing to hide — execute_function's TRAP_STRING is NULL for them. (Also: the table
	-- may still be the parent's, not yet copied — iso_save_traps.)
	local e0 = e
	if (sh.in_subprogram or 0) > 0 then
		if d ~= nil and not M.pseudo_trapped(sh, "DEBUG") then
			d = nil
		end
		if r ~= nil and not M.pseudo_trapped(sh, "RETURN") then
			r = nil
		end
		if e ~= nil and not M.pseudo_trapped(sh, "ERR") then
			e = nil
		end
	end
	-- ERR likewise, unless errtrace (`set -E`) — and bash samples it BEFORE a command runs,
	-- so one the call itself sets doesn't fire for the call (e0: it existed before)
	local saved = { e0 = e0 }
	if e ~= nil and not sh.opt_errtrace then
		sh.traps.ERR, saved.e = nil, e
	end
	if sh.opt_functrace or (sh.fn_trace and sh.fn_trace[name]) then
		-- inherited: it also fires once on ENTRY, at the definition's line (bash)
		if d ~= nil then
			require("interp").run_debug(sh, sh.func_bline and sh.func_bline[name] or nil)
		end
		return saved
	end
	if d ~= nil then
		sh.traps.DEBUG = nil
	end
	if r ~= nil then
		sh.traps.RETURN = nil
	end
	saved.d, saved.r = d, r
	return saved
end
-- Is the DEBUG/RETURN/ERR trap live here? A subshell or $( ) inherits their strings (listed
-- by `trap`) but not the trapping — unless functrace (DEBUG, RETURN) / errtrace (ERR) is on
-- — so only one set at this subshell level is (trap.c reset_or_restore_signal_handlers).
function M.pseudo_trapped(sh, name)
	local sp = sh.in_subprogram or 0
	if sp == 0 then
		return true
	end
	if name == "ERR" then
		return sh.opt_errtrace or sp == sh.err_trap_sp
	end
	return sh.opt_functrace or sp == (name == "DEBUG" and sh.dbg_trap_sp or sh.ret_trap_sp)
end
function M.debug_leave(sh, saved)
	if saved ~= nil then
		if saved.d ~= nil and sh.traps.DEBUG == nil then
			sh.traps.DEBUG = saved.d
		end
		if saved.r ~= nil and sh.traps.RETURN == nil then
			sh.traps.RETURN = saved.r
		end
		if saved.e ~= nil and sh.traps.ERR == nil then
			sh.traps.ERR = saved.e
		end
	end
	if not (saved and saved.e0) and sh.traps.ERR and sh.status ~= 0 and sh.noerr == 0 then
		sh.err_skip = true -- (set during this call: no ERR for the call's own failure)
	end
end
function M.child_exit(sh, status)
	local h = sh and sh.traps and sh.traps.EXIT
	if h and h ~= "" and not M.exit_trap_inherited and not sh.in_exit_trap then
		sh.in_exit_trap = true
		sh.status = status
		sh.cur_line = 1 -- (bash: the EXIT trap's $LINENO counts from 1)
		local ok, r = pcall(require("interp").run_trap_str, sh, h)
		if ok and r then
			status = sh.status -- `exit N` in the trap wins
		elseif not ok and type(r) == "table" and r.__curse_exit then
			status = r.__curse_exit
		end
	end
	io.flush()
	C._exit(status or 0)
end

function Shell:subshell_run(runner, saves, paren)
	local cp = sub_checkpoint(self)
	local sv_out, sv_line = self.out, self.cur_line
	local sv_ld, sv_ne, sv_alias = self.loopdepth, self.noerr, self.aliases
	self.aliases = shallowcopy(self.aliases) or {}
	self.in_subprogram = (self.in_subprogram or 0) + 1
	local sv_psp = self.paren_sp -- (a `( … )`: the subprogram level that is one — exec.def's SUBSHELL_PAREN)
	if paren then
		self.paren_sp = self.in_subprogram
	end
	self.loopdepth = 0
	local sv_depth, sv_jobs, sv_cur, sv_prev = self.subdepth, self.jobs, self.job_cur, self.job_prev
	self.subdepth = (sv_depth or 0) + 1
	self.jobs = {} -- (a subshell has no jobs of the parent's; its own are numbered from 1)
	self.job_cur, self.job_prev = nil, nil

	local ctx = iso_push(self)
	local ok, err = pcall(runner, self)
	local status = self.status
	local rethrow
	if not ok then
		if type(err) == "table" and err.__curse_badusage and paren and not self.opt_e then
			status = 2 -- (a failed ${x:=w} discards the `( )` child's line: EX_BADUSAGE; a $(…) says 1)
		elseif type(err) == "table" and (err.__curse_exit or err.__curse_return) then
			status = err.__curse_exit or err.__curse_return
		elseif type(err) == "table" and err.__curse_lineabort then
			status = 1
		elseif type(err) == "table" and err.__curse_vsig == ctx then
			status = 128 + err.sig -- killed: reported as bash reports a dead foreground child
			local I = package.loaded.interp
			local d = err.sig ~= 2 and err.sig ~= 13 and I and I._int.SIGDESC[err.sig]
			if d then
				io.stderr:write(d .. "\n")
			end
		else
			rethrow = err
		end
	end
	if not rethrow and ctx.pid == C.getpid() then
		status = M.iso_exit_trap(self, ctx, status, err)
	end
	iso_pop(self, ctx)
	for _, j in ipairs(self.jobs) do -- its unfinished jobs are orphans now: never the parent's
		if not j.done and j.pid and j.pid > 0 then
			M.internal_pids[j.pid] = true
		end
	end
	self.jobs, self.job_cur, self.job_prev = sv_jobs, sv_cur, sv_prev
	if C.getpid() ~= ctx.pid then
		-- a process forked deeper inside (a nested subshell's child) unwound out to here:
		-- it ends now, never resuming the script as a copy of the shell
		M.child_exit(self, status or 0)
	end

	if saves then M.redir_restore(saves) end
	self.out, self.cur_line = sv_out, sv_line
	self.loopdepth, self.noerr, self.aliases = sv_ld, sv_ne, sv_alias
	self.in_subprogram = self.in_subprogram - 1
	self.paren_sp = sv_psp
	self.subdepth = sv_depth
	sub_restore(self, cp)
	if rethrow then error(rethrow) end
	self.status = status
end

-- Compiled `$(…)` whose body MUTATES shell state but needs no real child: run it
-- in-process with FULL isolation (sub_checkpoint/restore) instead of forking the fat
-- worker. capture_inproc supplies the $()-specific light state (stdout→buffer, errexit
-- OFF unless inherit_errexit, aliases, in_subprogram, cur_line, trailing-newline/NUL
-- strip, exit/return→status); the heavy checkpoint wraps it. The emit gate keeps a body
-- that forks a real child (exec/&/$BASHPID/set/ulimit/…) or would desync a lifted upvalue
-- (a lifted-touching function — no swap is possible in this expression context) on the
-- fork path. Returns the captured string.
-- $BASH_SUBSHELL for a pipeline stage (bash): a `( … )` stage counts once (its own
-- subshell), and a simple command that runs no shell code (not a function, eval, source, …)
-- expands its words at the pipeline's own level. `isfn(name)`: is it a function?
local STAGE_CODE_BUILTINS = { eval = 1, source = 1, ["."] = 1 }
-- A pipeline stage's marker for run_pipeline: "flat" (not counted in $BASH_SUBSHELL, see
-- stage_flat) or true — and for a SIMPLE command "sflat" / "simple": it keeps the loop
-- level (bash forks it straight from execute_simple_command, where only execute_in_subshell
-- — `( … )`, a compound stage — resets loop_level: `break | cat` in a loop is silent).
function M.stage_kind(st, isfn)
	local flat = M.stage_flat(st, isfn)
	if st.t == "simple" then
		return flat and "sflat" or "simple"
	end
	return flat and "flat" or true
end
function M.stage_flat(st, isfn)
	if st.t == "subshell" then
		return true
	end
	if st.t ~= "simple" then
		return false
	end
	local k = 1
	while true do
		local w = st.words and st.words[k]
		local c = w and w.parts and #w.parts == 1 and w.parts[1].lit
		if not c then
			return false -- (a dynamic word could name anything)
		end
		if c ~= "command" and c ~= "builtin" then
			return not STAGE_CODE_BUILTINS[c] and not isfn(c)
		end
		k = k + 1 -- (`command`/`builtin NAME`: what NAME is; options can't be judged)
		local nw = st.words[k]
		local nc = nw and nw.parts and #nw.parts == 1 and nw.parts[1].lit
		if nc and nc:sub(1, 1) == "-" then
			return false
		end
		if c == "builtin" and nc then
			return not STAGE_CODE_BUILTINS[nc]
		end
	end
end
-- The pids of sh's jobs, as seen from a subshell that lists them (a pipeline stage, $(…))
-- but can't wait on them: they aren't its children.
function M.foreign_jobs(sh)
	local f = {}
	for pid in pairs(sh.foreign_pids or {}) do
		f[pid] = true
	end
	for _, j in ipairs(sh.jobs or {}) do
		if j.pid then
			f[j.pid] = true
		end
	end
	return f
end
function Shell:capture_compiled_iso(cs_fn, backtick)
	local sv_foreign = self.foreign_pids
	self.foreign_pids = M.foreign_jobs(self)
	local cp = sub_checkpoint(self)
	local ctx = iso_push(self)
	local ok, out = pcall(self.capture_inproc, self, backtick, cs_fn, true, ctx) -- fd-level capture
	if C.getpid() ~= ctx.pid then -- (a forked descendant unwound out: it ends here)
		M.child_status(self, ok, out)
		M.child_exit(self, self.status or 0)
	end
	iso_pop(self, ctx)
	sub_restore(self, cp)
	self.foreign_pids = sv_foreign
	if not ok then
		error(out, 0)
	end
	return out
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
-- bash drops NUL bytes from a substitution's output, warning once per substitution
-- (subst.c read_comsub)
function M.cmdsub_nul(c)
	if c:find("%z") then
		io.stderr:write("curse: warning: command substitution: ignored null byte in input\n")
		return (c:gsub("%z", ""))
	end
	return c
end
function Shell:capture_file(path)
	local f = path ~= "" and M.open_read(path)
	if f then
		local c = f:read("*a") or ""
		f:close()
		self.status = 0
		self.last_cmdsub_status, self.ncs = 0, (self.ncs or 0) + 1
		return (M.cmdsub_nul(c):gsub("\n+$", ""))
	end
	io.stderr:write("curse: " .. path .. ": No such file or directory\n")
	self.status = 1
	self.last_cmdsub_status, self.ncs = 1, (self.ncs or 0) + 1
	return ""
end

function Shell:capture_compiled(cs_fn, _, backtick) -- (2nd arg: a retired fork flag)
	return self:capture_inproc(backtick, cs_fn)
end

-- In a forked child (subshell/background/pipeline stage), translate an exit/return
-- thrown as a control table into $? so the child _exits with the right status.
function M.child_status(sh, ok, err)
	if not ok and type(err) == "table" then
		sh.status = err.__curse_exit or err.__curse_return or sh.status
	end
end

-- Is a field (value `s`, quote mask `q`: "1" = quoted byte) a pattern — a glob
-- metacharacter at an unquoted position? bash's glob_pattern_p: `*`/`?`/extglob always;
-- `[` only with a closing `]` (and no `/` between); an unquoted `\` from an expansion
-- escapes the next char (bash 5.2: `a\?` from a variable isn't a pattern).
function M.field_glob_active(f)
	local s, q = f.s, f.q
	local open, esc = false, false
	for i = 1, #s do
		if esc then
			esc = false
		elseif not q or q:sub(i, i) == "0" then
			local c = s:sub(i, i)
			if c == "\\" then
				esc = true
			elseif c == "*" or c == "?" then
				return true
			elseif c == "[" then
				open = true
			elseif c == "/" then
				open = false
			elseif c == "]" then
				if open then
					return true
				end
			elseif (c == "+" or c == "@" or c == "!") and s:sub(i + 1, i + 1) == "("
				and (not q or q:sub(i + 1, i + 1) == "0") then
				return true
			end
		end
	end
	return false
end
-- Does a redirection list redirect standard input?
function M.redirs_stdin(rd)
	for _, r in ipairs(rd) do
		local op = r.op
		if (r.fd or 0) == 0 and (op == "in" or op == "heredoc" or op == "herestring" or op == "dupin" or op == "rw") then
			return true
		end
	end
	return false
end
-- `for NAME in …` with NAME readonly: bash reports it, status 1, and runs no iteration
-- `for NAME in …` assigns each word; a NAMEREF loop variable is instead re-pointed at
-- each word in turn (bash: the words name the variables to reference). false = the
-- assignment failed, which ends the loop (status 1) as in bash.
function M.for_assign(sh, name, v)
	local b = sh.vars[name]
	if b and b.ref then
		if not M.ref_target_ok(v) then
			M.bad_ref_target(v)
			sh.status = 1
			return false
		end
		b.s = v
		return true
	end
	-- (the loop variable is bound like an assignment: declare -i evaluates, -l/-u fold)
	if b and (b.int or b.lower or b.upper) and not b.arr then
		M.assign_scalar(sh, name, v)
		return true
	end
	return sh:set_str(name, v) ~= false
end
function M.for_var_ro(sh, name)
	local b = sh.vars[name] -- (a nameref loop var re-points itself: ITS readonly-ness counts)
	if not (b and b.ref) then
		b = sh.vars[sh:deref(name)]
	end
	if b and b.ro then
		io.stderr:write("curse: " .. name .. ": readonly variable\n")
		sh.status = 1
		return true
	end
	return false
end
-- write all of `s` to a raw fd; false if the fd isn't writable (EBADF…)
function M.fd_write(fd, s)
	local off = 0
	while off < #s do
		local n = tonumber(C.curse_co_write(fd, ffi.cast("const char *", s) + off, #s - off))
		if not n or n < 0 then
			return false
		end
		off = off + n
	end
	return true
end
-- ---- coprocesses (`coproc [NAME] cmd`) -------------------------------------------
-- The shell keeps one end of each of the two pipes: NAME=(read-fd write-fd), NAME_PID.
-- Like bash, each pipe end first moves to the highest FREE fd below 64 (move_to_high_fd),
-- so a lone coproc is `63 60` (the read pipe takes 63/62, the write pipe 61/60).
function M.fd_below(fd, lim)
	for t = lim - 1, 10, -1 do
		if C.curse_co_fcntl3(t, 1, 0) < 0 and C.dup2(fd, t) == t then -- F_GETFD fails: free
			C.close(fd)
			return t
		end
	end
	return fd
end
-- NAME=(read-fd write-fd) and NAME_PID, as bash's coproc_setvars: a readonly NAME (through
-- a nameref, its target) is reported and nothing is set; a readonly NAME_PID is reported.
function M.coproc_setvars(sh, name, r, w, pid)
	local et = sh.vars[name] and sh.vars[name].ref and sh:deref_elem(name)
	if et then -- (a nameref to an ELEMENT can't hold the fd array)
		io.stderr:write("curse: `" .. et .. "': not a valid identifier\n")
		return
	end
	local dn = sh:deref(name)
	local b = sh.vars[dn]
	if b and b.ro then
		io.stderr:write("curse: " .. dn .. ": readonly variable\n")
		return
	end
	sh:array_assign(name, { tostring(r), tostring(w) }, false)
	local pn = name .. "_PID"
	local pdn = sh:deref(pn)
	local pb = sh.vars[pdn]
	if pb and pb.ro then
		io.stderr:write("curse: " .. pdn .. ": readonly variable\n")
	else
		sh:set_str(pn, tostring(pid))
	end
end
-- The coproc `pid` was reaped: bash closes the shell's ends and unsets NAME (through a
-- nameref; a readonly one is reported and kept) and NAME_PID (itself, readonly or not).
function M.coproc_dispose(sh, pid)
	local cp = sh.coprocs and sh.coprocs[pid]
	if not cp then
		return
	end
	sh.coprocs[pid] = nil
	for _, fd in ipairs({ cp.r, cp.w }) do
		if fd >= 0 then
			C.close(fd)
		end
	end
	local dn = sh:deref(cp.name)
	if sh.vars[dn] and sh.vars[dn].ro then
		io.stderr:write("curse: " .. dn .. ": cannot unset: readonly variable\n")
	else
		sh.vars[dn] = nil
	end
	sh.vars[cp.name .. "_PID"] = nil
end
-- bash reaps a finished coproc as soon as SIGCHLD arrives, closing its fds and unsetting
-- NAME; the interpreter polls for that between commands while any coproc exists.
function M.coproc_poll(sh)
	local sb = ffi.new("int[1]")
	for pid, cp in pairs(sh.coprocs) do
		if cp.g then -- (in-process)
			if cp.g.done then
				for _, j in ipairs(sh.jobs or {}) do
					if j.pid == pid and not j.done then
						j.done, j.status = true, cp.g.status[1] or 0
					end
				end
				M.coproc_dispose(sh, pid)
			end
		elseif C.waitpid(pid, sb, 1) == pid then -- WNOHANG
			for _, j in ipairs(sh.jobs or {}) do
				if j.pid == pid and not j.done then
					j.done, j.status = true, M.wexit(sb[0])
				end
			end
			M.coproc_dispose(sh, pid)
		end
	end
end
-- After the shell rewires its fds (exec redirections): an end the coproc no longer has
-- open in the shell (closed, or moved away with `N<&fd-`) reads as -1 in NAME (bash).
function M.coproc_fdcheck(sh)
	for _, cp in pairs(sh.coprocs) do
		local r = (cp.r >= 0 and C.curse_co_fcntl3(cp.r, 1, 0) < 0) and -1 or cp.r
		local w = (cp.w >= 0 and C.curse_co_fcntl3(cp.w, 1, 0) < 0) and -1 or cp.w
		if r ~= cp.r or w ~= cp.w then
			cp.r, cp.w = r, w
			sh:array_assign(cp.name, { tostring(r), tostring(w) }, false)
		end
	end
end

-- ---- exported functions (`export -f`) ------------------------------------------------
-- A function travels in the environment as BASH_FUNC_name%%=() { … } (bash's layout);
-- the variable is rewritten whenever the definition or the export attribute changes.
function M.fexport_sync(sh, name)
	local key = "BASH_FUNC_" .. name .. "%%"
	local txt
	if sh.fexport and sh.fexport[name] and sh.functions[name] then
		txt = require("interp")._int.func_export_text(sh, name)
	end
	if txt then
		C.setenv(key, txt, 1)
	else
		C.unsetenv(key)
	end
end
-- A new shell imports each BASH_FUNC_name%% whose value is EXACTLY one definition of
-- `name` — anything trailing it (`() { :; }; echo BAD`, CVE-2014-6271 and kin) or a
-- malformed body is rejected (bash: "error importing function definition").
function M.import_functions(sh)
	local list = sh.fimports
	sh.fimports = nil
	if not list then
		return
	end
	local P = require("parser")
	for _, f in ipairs(list) do
		local name, val = f[1], f[2]
		local src = name .. " " .. val
		local ok, ast = false, nil
		-- (a path-like name is never imported: `/bin/echo` must stay the program)
		if val:sub(1, 4) == "() {" and not name:find("/", 1, true) then
			ok, ast = pcall(P.parse, src)
		end
		-- (exactly ONE statement: anything after the definition — `; echo BAD` — is a second
		-- statement, and a word glued after the body is a syntax error)
		local st = ok and type(ast) == "table" and not ast.perr and #ast.stmts == 1 and ast.stmts[1]
		if st and st.t == "funcdef" and st.name == name then
			sh.functions[name] = st.body
			sh.func_redirs = sh.func_redirs or {}
			sh.func_redirs[name] = st.redirs
			sh.func_src = sh.func_src or {}
			sh.func_src[name] = nil
			sh.func_def = sh.func_def or {}
			sh.func_def[name] = st
			sh.fexport = sh.fexport or {}
			sh.fexport[name] = true
		else
			io.stderr:write("curse: error importing function definition for `" .. name .. "'\n")
		end
	end
end

-- bash's job table (jobs.c): a job holds its slot [N] from `&` until it is DELETED — waited
-- for, or listed by `jobs` once it has ended (a script is never notified otherwise) — so a
-- finished job is still %N / %+ and `kill`able. A deleted job is marked j.gone but stays in
-- sh.jobs: `wait $pid` still answers with its status (bash's bgpids list).
function M.job_running(j)
	return not j.done and not (j.g and j.g.done)
end
-- reset_current + set_current_job (jobs.c; nothing here is ever stopped): the current job
-- (%+) is the newest running one, the previous (%-) the newest running one older than it,
-- else the current one again. Neither changes when a job merely ends — only on `&` and
-- when the current or previous job is deleted.
function M.job_reset_current(sh)
	local cur, prev
	for _, j in ipairs(sh.jobs or {}) do
		if not j.gone and M.job_running(j) and (not cur or j.id > cur.id) then
			cur = j
		end
	end
	if cur then
		for _, j in ipairs(sh.jobs) do
			if not j.gone and M.job_running(j) and j.id < cur.id and (not prev or j.id > prev.id) then
				prev = j
			end
		end
	end
	sh.job_cur, sh.job_prev = cur, prev or cur
end
-- delete_job: the job leaves the table (its slot number is free again)
function M.job_delete(sh, j)
	if not j.gone then
		j.gone = true
		if j == sh.job_cur or j == sh.job_prev then
			M.job_reset_current(sh)
		end
	end
end
-- Register a background job (for `jobs`/`wait %spec`/`wait -n`) and set $!: the slot after
-- the highest one in use, and it becomes the current job.
function M.job_add(sh, pid, cmdstr)
	sh.jobs = sh.jobs or {}
	local maxid = 0
	for _, j in ipairs(sh.jobs) do
		if not j.gone and j.id > maxid then
			maxid = j.id
		end
	end
	local job = { id = maxid + 1, pid = pid, cmd = cmdstr or "", done = false, nojc = not sh.opt_m or nil }
	sh.jobs[#sh.jobs + 1] = job
	sh.last_bg_pid = tostring(pid)
	M.job_reset_current(sh)
	return job
end

-- `cmd &`: fork; the child runs the COMPILED command fragment cmd_fn(sh) with stdin
-- redirected to /dev/null (async, can't steal the terminal) as a subprogram (ERR
-- suppressed); the parent records $! + the job and returns status 0. Compiled tier
-- only, gated by emit to trap-free programs (so the child needs no signal reset).
-- `ext args… &` where the args are side-effect-free: the parent already built argv, so
-- SPAWN the job directly (vfork-fast, stdin </dev/null) — no fork of this (large)
-- process at all. Returns false (caller forks instead) when it can't reproduce the
-- forked child exactly: unresolvable name (the child prints the error), a no-shebang
-- script, or xtrace (the child traces).
-- The shell's OWN helper processes (the tiered driver's background transpiler): spawned
-- directly (never through /bin/sh), output to /dev/null, and marked so `wait`/`wait -n`
-- — which reap with waitpid(-1) — skip them rather than mistake one for a job.
M.internal_pids = {}
function M.spawn_internal(argv_t)
	local n = #argv_t
	local argv = ffi.new("const char*[?]", n + 1)
	for i = 1, n do
		argv[i - 1] = argv_t[i]
	end
	argv[n] = nil
	local fa = ffi.new("uint8_t[1024]")
	C.posix_spawn_file_actions_init(fa)
	C.posix_spawn_file_actions_addopen(fa, 0, "/dev/null", 0, 0)
	C.posix_spawn_file_actions_addopen(fa, 1, "/dev/null", 1, 0)
	C.posix_spawn_file_actions_addopen(fa, 2, "/dev/null", 1, 0)
	local pidp = ffi.new("curse_pid_t[1]")
	M.rd_gen = M.rd_gen + 1
	local rc = C.posix_spawnp(pidp, argv_t[1], fa, nil, ffi.cast("char *const *", argv), C.environ)
	C.posix_spawn_file_actions_destroy(fa)
	if rc ~= 0 then
		return nil
	end
	local pid = tonumber(pidp[0])
	M.internal_pids[pid] = true
	return pid
end
-- reap an internal helper if it has finished (never blocks)
function M.reap_internal(pid)
	if pid and M.internal_pids[pid] and C.waitpid(pid, nil, 1) == pid then -- (WNOHANG)
		M.internal_pids[pid] = nil
	end
end

function Shell:spawn_bg(args, cmdstr)
	local n = #args
	if n == 0 or args[1] == "" or self.opt_x or self.exec_argv0 then
		return false
	end
	-- a (dynamic) word that names a function/builtin/alias runs shell code: fork for it
	local I = package.loaded.interp
	if self.functions[args[1]] or (I and I.BUILTINS[args[1]]) or (self.aliases and self.aliases[args[1]]) then
		return false
	end
	local execpath = args[1]
	if not execpath:find("/", 1, true) then
		execpath = self:resolve_cmd(execpath)
		if not execpath then
			return false
		end
	end
	local argv = ffi.new("const char*[?]", n + 1)
	local anchor = {}
	for i = 1, n do
		anchor[i] = tostring(args[i])
		argv[i - 1] = anchor[i]
	end
	argv[n] = nil
	io.flush()
	local fa = ffi.new("uint8_t[1024]")
	C.posix_spawn_file_actions_init(fa)
	if (self.stdin_redir or 0) == 0 then -- async job: stdin </dev/null (unless redirected around it)
		C.posix_spawn_file_actions_addopen(fa, 0, "/dev/null", 0, 0)
	end
	M.foreign_fa(self, fa)
	C.setenv("_", execpath, 1) -- (the program's `_` is its path, as in Shell:exec)
	local pidp = ffi.new("curse_pid_t[1]")
	local attr = child_spawnattr(self)
	local hold = not self.opt_m
	if hold then
		attr = async_spawn_hold(attr)
	end
	M.rd_gen = M.rd_gen + 1 -- (a new process may read our input: see M.pipe_cache)
	local cenv = M.child_env() -- (bash's order; kept alive across the call)
	local rc = C.posix_spawnp(pidp, execpath, fa, attr, ffi.cast("char *const *", argv), cenv)
	if hold then
		async_spawn_release()
	end
	if attr then
		C.posix_spawnattr_destroy(attr)
	end
	C.posix_spawn_file_actions_destroy(fa)
	if rc ~= 0 then
		return false
	end
	local pid = tonumber(pidp[0])
	M.job_add(self, pid, cmdstr)
	self.bg_pids = self.bg_pids or {}
	self.bg_pids[#self.bg_pids + 1] = pid
	self.status = 0
	return true
end

function Shell:run_background(cmd_fn, cmdstr, exec_tail, flat, simple, pipe)
	-- (in-process: a background task — see Shell:bg_launch)
	local job = self:bg_launch(cmd_fn, cmdstr, flat, simple)
	if pipe and job and job.g then
		job.g.pipe = true -- (a pipeline job: `kill %N` reaches its every stage)
	end
	self.status = 0
end

-- `a | b | c`: fork a child per stage wired by pipes, running each COMPILED stage
-- fragment; the last stage's exit is the pipeline's (or the rightmost non-zero under
-- pipefail). The last stage's stdout goes to fd 1, or the capture buffer inside $(…),
-- or runs in the current shell under `shopt -s lastpipe`. Sets $PIPESTATUS and applies
-- `!` negation. Compiled tier only (gated by emit to no trap/DEBUG/ERR — so no signal
-- reset or per-stage trap firing is needed here). `stage_fns` are cs_N fragments.
-- ---- Coroutine pipeline scheduler -------------------------------------------
-- `a | b | c` with NO fork per shell-side stage: each stage is a coroutine running
-- its compiled fragment on its own cloned shell, externals stay real processes
-- running concurrently, and stages are connected by real kernel pipes. Only one
-- stage runs at a time, so the process-global state a forked stage would own —
-- fd 0/1/2, environ, cwd, umask — is INSTALLED on resume and SAVED on yield (the
-- swap game at context-switch granularity); between resumes everything is
-- PARKED on the parent's values, which also guarantees no stale fd-1 copy keeps a
-- reader from seeing EOF. A stage that would block (pipe full/empty, child not
-- exited) yields to a poll() loop — see M.co_block / M.wait_child / M.fork.
M.CO_OUTS = CO_OUTS
local _co_sigpipe = ffi.new("uint8_t[128]") -- sigset_t {SIGPIPE}
C.sigemptyset(_co_sigpipe)
C.curse_co_sigaddset(_co_sigpipe, 13)
local _co_zero_ts = ffi.new("struct curse_co_ts", 0, 0)

-- Drain a stage's buffered stdout to its fd 1 (whatever fd 1 is right now — a
-- redirect inside the stage included). Writes are <= 4096 after POLLOUT, so a
-- write never blocks on a pipe (a free slot always fits a PIPE_BUF write). SIGPIPE
-- is blocked for the scheduler's lifetime, so a vanished reader surfaces as EPIPE:
-- consume the pending signal and end the stage the way SIGPIPE ends a forked one.
task_flush = function(t)
	if t.nbuf == 0 then
		return
	end
	local data = table.concat(t.buf, "", 1, t.nbuf)
	t.buf, t.nbuf, t.nbytes = {}, 0, 0
	t.flushing = true
	local p, off, len = ffi.cast("const char *", data), 0, #data
	while off < len do
		M.co_block(1, POLLOUT)
		local chunk = len - off
		if chunk > 4096 then
			chunk = 4096
		end
		local w = tonumber(C.curse_co_write(1, p + off, chunk))
		if w >= 0 then
			off = off + w
		else
			local e = ffi.errno()
			if e == 32 then -- EPIPE
				C.curse_co_sigtimedwait(_co_sigpipe, nil, _co_zero_ts)
				t.flushing = false
				error({ __curse_sigpipe = true })
			elseif e ~= 4 and e ~= 11 then -- not EINTR/EAGAIN: drop (like a failed io.write)
				break
			end
		end
	end
	t.flushing = false
end
local function make_out(t)
	local f = function(...)
		local k = t.nbuf
		for i = 1, select("#", ...) do
			local s = tostring((select(i, ...)))
			k = k + 1
			t.buf[k] = s
			t.nbytes = t.nbytes + #s
		end
		t.nbuf = k
		if t.nbytes >= 4096 then
			task_flush(t)
		end
	end
	CO_OUTS[f] = t -- (its task: a diagnostic flushes what's buffered first)
	return f
end
-- Before a diagnostic: push out what the current pipeline stage has buffered (so both
-- reach a shared fd in the order they were made, as bash's unbuffered output does).
function M.flush_stage_out(sh)
	local t = sh and CO_OUTS[sh.out] or co_task()
	if type(t) == "table" and t.nbuf > 0 and not t.flushing then
		task_flush(t)
	end
end
-- A stage's private shell: a subshell's worth of isolation for the Lua-side state
-- (process-global state is swapped by the scheduler instead). Every table field is
-- shallow-copied so container mutations stay local; variable boxes are mutated in
-- place, so they're deep-copied; the per-depth param pools are reused in place by
-- pushParams, so a stage gets fresh ones.
function Shell:stage_clone()
	local c = setmetatable({}, getmetatable(self))
	for k, v in pairs(self) do
		c[k] = type(v) == "table" and shallowcopy(v) or v
	end
	c.subdepth = (self.subdepth or 0) + 1 -- (a stage is a subshell)
	c.iso_ctx, c.stage_pid, c.vpid, c.rpid = {}, tonumber(C.getpid()), nil, nil
	if self.iso_ctx and #self.iso_ctx > 0 then -- (a subshell's virtual hard limits stay in force in its stages)
		local vb = self.iso_vhard_base and shallowcopy(self.iso_vhard_base) or {}
		for _, ctx in ipairs(self.iso_ctx) do
			for res, v in pairs(ctx.vhard or {}) do
				vb[res] = v
			end
		end
		c.iso_vhard_base = next(vb) and vb or nil
	end
	c.foreign_pids = M.foreign_jobs(self) -- (`jobs` lists the parent's; `wait` can't wait on them)
	local vars = {}
	for k, b in pairs(self.vars) do
		vars[k] = copybox(b)
	end
	c.vars = vars
	c.getopts_state = M.getopts_remap(self.getopts_state, self.vars, vars)
	for d, rec in pairs(c.savedstack) do
		if type(rec) == "table" then
			c.savedstack[d] = shallowcopy(rec)
		end
	end
	for k = 1, #c.tenv do
		c.tenv[k] = shallowcopy(c.tenv[k])
	end
	c.argpool = {}
	-- (jobs stays a COPY of the parent's table: bash lets a pipeline stage SEE the
	-- parent's jobs — `jobs | wc -l` — as a forked stage's copy-on-write view did.)
	c.in_pipestage = (self.in_pipestage or 0) + 1
	c.paren_sp = nil -- (a stage is a subshell of its own, not the `( … )` it may sit in)
	c.loopdepth = 0
	c.capturing = nil
	return c
end
local function env_copy(envp)
	local n = 0
	while envp[n] ~= nil do
		n = n + 1
	end
	local a = ffi.cast("char **", C.curse_co_malloc((n + 1) * 8))
	for i = 0, n do
		a[i] = envp[i]
	end
	return a
end
local _co_cwdbuf = ffi.new("char[4096]")
local function cwd_str()
	local p = C.curse_co_getcwd(_co_cwdbuf, 4096)
	return p ~= nil and ffi.string(p) or nil
end
local function env_same(a, b) -- same entries, pointer for pointer?
	local i = 0
	while true do
		if a[i] ~= b[i] then
			return false
		end
		if a[i] == nil then
			return true
		end
		i = i + 1
	end
end
local function co_cx(ctx, fd) -- CLOEXEC dup >= FD_BASE, tracked so a forked child can drop it
	local d = dup_hi(fd)
	if d >= 0 then
		ctx.fds[d] = true
	end
	return d
end
local function co_cl(ctx, fd)
	if fd and fd >= 0 and ctx.fds[fd] then
		ctx.fds[fd] = nil
		C.close(fd)
	end
end

-- Launch one pipeline invocation as a GROUP of tasks in scheduler `ctx`. `base` is the
-- state the pipeline starts from (fds 0-9, environ, cwd, umask, lifted upvalues): the
-- parent shell's for a top-level pipeline, the running stage's for a nested one. Each
-- task starts from a copy of it; stage i's fd 0/1 are rewired to the stage pipes.
local function co_launch(ctx, self, stage_fns, inproc, base, lastpipe, upv)
	local n = #stage_fns
	local g = { n = n, alive = 0, status = {}, base = base, upv = upv }
	local ins, outs = { base.fd[0] }, {}
	local pst = ffi.new("int[2]")
	local made = {}
	local function fail()
		for _, fd in ipairs(made) do
			co_cl(ctx, fd)
		end
		return nil
	end
	for i = 1, n - 1 do
		if M.pipe_hi(pst) ~= 0 then
			return fail()
		end
		ctx.fds[pst[0]], ctx.fds[pst[1]] = true, true
		made[#made + 1], made[#made + 2] = pst[0], pst[1]
		outs[i], ins[i + 1] = pst[1], pst[0]
	end
	-- Output captured into a Lua buffer (a buffered `$()`): the last stage writes a pipe
	-- that a DRAIN task empties into the capture as the data arrives.
	-- (a lastpipe last stage IS the shell: it writes the capture directly, as the shell does —
	-- its fds are adopted at the end, so a drain pipe on its fd 1 would never see EOF)
	local drain_r, drain_out
	local bufcap = self.capturing and self.out ~= io.write and not CO_OUTS[self.out]
	if bufcap and not lastpipe then
		if M.pipe_hi(pst) ~= 0 then
			return fail()
		end
		ctx.fds[pst[0]], ctx.fds[pst[1]] = true, true
		made[#made + 1], made[#made + 2] = pst[0], pst[1]
		drain_r, drain_out, outs[n] = pst[0], self.out, pst[1]
	else
		outs[n] = base.fd[1]
	end
	local function newtask(i, fd0, fd1)
		local t = { i = i, g = g, fd = {}, sv = {}, own = {}, cwd = base.cwd, um = base.um, buf = {}, nbuf = 0, nbytes = 0 }
		for k = 0, 9 do
			t.fd[k] = base.fd[k]
		end
		t.fd[0], t.fd[1] = fd0, fd1
		t.env = env_copy(base.env)
		ctx.envs[#ctx.envs + 1] = t.env
		if upv then
			t.upv = { unpack(base.upv, 1, upv.n) }
		end
		return t
	end
	local function add(t, body)
		t.co = coroutine.create(body)
		ctx.bycoro[t.co] = t
		ctx.runnable[#ctx.runnable + 1] = t
		g.alive = g.alive + 1
	end
	local function stage_body(fn, sh, t, islp)
		return function()
			local mypid = C.getpid()
			local ctx = not islp and iso_push(sh) -- (a stage is an in-process subshell)
			if ctx then
				ctx.task_fds = true
			end
			if ctx and g.bg then -- (a background job: $BASHPID = its $!, and `kill $!` finds it)
				ctx.vpid, ctx.task = g.vpid, t
				M.vpid_ctx[g.vpid] = ctx
				-- without job control an async compound command starts with SIGINT ignored
				-- (execute_in_subshell's setup_async_signals), which `trap` then lists
				if not (g.simple or g.pipe or sh.opt_m) then
					M.iso_save_traps(sh)
					sh.traps.SIGINT, ctx.igint = "", true
				end
			end
			sh.badassign = nil
			local ok, err = pcall(fn, sh)
			if C.getpid() ~= mypid then
				-- a process FORKED inside this stage (a subshell's child, `( exec … )`) unwound
				-- out of it: it must end here, never resume this pipeline as a copy of the shell
				M.child_status(sh, ok, err)
				M.child_exit(sh, sh.status or 0)
			end
			if ctx then
				if not ok and type(err) == "table" and err.__curse_vsig == ctx then
					err = { __curse_exit = 128 + err.sig }
					g.killed = true
				end
				local cst = ok and sh.status or (type(err) == "table" and (err.__curse_exit or err.__curse_return))
				if cst then
					local nst = M.iso_exit_trap(sh, ctx, cst, err)
					if nst ~= cst then
						ok, err = false, { __curse_exit = nst }
					end
				end
				iso_pop(sh, ctx)
			end
			if not ok and type(err) == "table" and err.__curse_sigpipe then
				return 141
			end
			-- the lastpipe stage IS the shell: its `exit`/`return` leaves the shell/function
			-- (re-raised once the pipeline finishes)
			if islp and not ok and type(err) == "table" and (err.__curse_exit or err.__curse_return) then
				g.lp_raise = err
			end
			M.child_status(sh, ok, err)
			local fok, ferr = pcall(task_flush, t)
			if not fok and type(ferr) == "table" and ferr.__curse_sigpipe then
				return 141
			end
			-- a declaration builtin's assignment error returns EX_BADASSIGN (260), which the
			-- shell maps to 1 — except as a forked simple command's exit status: 260 & 255 = 4
			-- (an "sflat" stage runs no shell code of its own: the flag is the builtin's)
			if t.simple and ok and sh.status == 1 and sh.badassign then
				return 4
			end
			return sh.status or 0
		end
	end
	for i = 1, n do
		local t = newtask(i, ins[i], outs[i])
		if ins[i] ~= base.fd[0] then
			t.own[#t.own + 1] = ins[i]
		end
		if outs[i] ~= base.fd[1] then
			t.own[#t.own + 1] = outs[i]
		end
		local fn = stage_fns[i]
		if lastpipe and i == n then
			-- `shopt -s lastpipe`: the last stage runs IN the shell itself (its side effects
			-- persist). Its clones-to-be were all taken above, so rebinding out is safe.
			g.lp, g.lp_out = t, self.out
			if not bufcap then
				self.out = make_out(t)
			end
			add(t, stage_body(fn, self, t, true))
		else -- (every stage runs in-process: a task with its own isolated shell)
			local sh = self:stage_clone()
			local kind = inproc[i]
			if kind == "flat" or kind == "sflat" then -- ($BASH_SUBSHELL: a `( … )` stage counts
				sh.subdepth = sh.subdepth - 1 -- once; a simple command running no shell code, not at all)
			end
			if kind == "sflat" or kind == "simple" then
				sh.loopdepth = self.loopdepth -- (see stage_kind)
			end
			sh.out = make_out(t)
			t.sh = sh
			t.simple = kind == "sflat"
			add(t, stage_body(fn, sh, t))
		end
	end
	if drain_r then
		local t = newtask(0, base.fd[0], base.fd[1])
		t.own[1], t.drain = drain_r, true
		add(t, function()
			local rbuf = ffi.new("char[65536]")
			while true do
				M.co_block(drain_r, POLLIN)
				local nr = tonumber(C.read(drain_r, rbuf, 65536))
				if not nr or nr <= 0 then
					break
				end
				drain_out(ffi.string(rbuf, nr))
			end
			return 0
		end)
	end
	return g
end

-- Resume one task with its process state installed; afterwards save its state and park
-- the process on the top-level parent's (P) — so between resumes no stale copy of any
-- stage's pipe end is live on fds 0-9, and the parent's view is intact.
local function co_resume(ctx, t)
	local P = ctx.P
	for fd = 0, 9 do -- install the stage's fds 0-9 (-1: it had closed it)
		if t.fd[fd] >= 0 then
			C.dup2(t.fd[fd], fd)
		else
			C.close(fd)
		end
	end
	C.environ = t.env
	if t.cwd ~= ctx.cur_cwd then
		C.curse_co_chdir(t.cwd)
		ctx.cur_cwd = t.cwd
	end
	C.curse_co_umask(t.um)
	local g = t.g
	if g.upv then
		g.upv.set(unpack(t.upv, 1, g.upv.n))
	end
	local rok, a, b
	if t.pending and not t.started then -- (signalled before it ever ran: default action,
		local sig -- unless the shell ignores that signal — then so does the job)
		local sh = t.sh
		for _, sg in ipairs(t.pending) do
			local nm = package.loaded.interp and package.loaded.interp._int.NUMSIG[sg]
			local c = nm and ("SIG" .. nm)
			if not (sh and c and sh.sigtraps and sh.sigtraps[c] and sh.traps[c] == "") and sg ~= 0
				and not (sg >= 17 and sg <= 23) and sg ~= 28 then
				sig = sig or sg
			end
		end
		t.pending = nil
		if sig then
			t.started = true
			ctx.bycoro[t.co] = nil
			t.co = coroutine.create(function()
				return 128 + sig
			end)
			ctx.bycoro[t.co] = t
			t.g.killed = true
			if t.g.vpid then
				M.vpid_tasks[t.g.vpid] = nil
			end
		end
	end
	local csh = M.cur_shell -- (its diagnostics carry ITS line: see M.err_prefix)
	if t.sh then
		M.cur_shell = t.sh
	end
	local armed = g.bg and preempt_arm(PREEMPT_USEC) == 0
	if t.pending and t.started then
		rok, a, b = coroutine.resume(t.co, SIGMARK)
	else
		t.started = true
		rok, a, b = coroutine.resume(t.co)
	end
	if armed then
		preempt_arm(0)
		PREEMPT[0] = 0
	end
	M.cur_shell = csh
	if g.bg and not g.base_closed then
		-- (a background job's starting copies were only needed to start it: from here its
		-- own saved state holds what it uses, and no stale copy keeps a pipe open)
		g.base_closed = true
		for k = 0, 9 do
			co_cl(ctx, g.base.fd[k])
			g.base.fd[k] = -1
		end
	end
	-- save the stage's process state
	t.env = C.environ
	t.um = C.curse_co_umask(P.um)
	C.environ = P.env
	t.cwd = cwd_str() or ctx.cur_cwd
	ctx.cur_cwd = t.cwd
	if g.upv then
		t.upv = { g.upv.get() }
	end
	local dead = coroutine.status(t.co) == "dead"
	if not dead or t == g.lp then -- its CURRENT fds 0-9 (a redirect may be active; lastpipe keeps them)
		for fd = 0, 9 do
			co_cl(ctx, t.sv[fd])
			local d = co_cx(ctx, fd)
			t.sv[fd], t.fd[fd] = d, d
		end
	end
	for fd = 0, 9 do -- park on the parent's fds
		if P.fd[fd] >= 0 then
			C.dup2(P.fd[fd], fd)
		else
			C.close(fd)
		end
	end
	if ctx.cur_cwd ~= P.cwd then
		C.curse_co_chdir(P.cwd)
		ctx.cur_cwd = P.cwd
	end
	if dead then
		if not rok then -- an internal error escaped the stage's own pcall
			io.stderr:write("curse: pipeline stage: " .. tostring(a) .. "\n")
		end
		if not t.drain then
			g.status[t.i] = rok and (a or 0) or 1
		end
		t.done, t.wait = true, nil
		ctx.bycoro[t.co] = nil
		if t ~= g.lp then
			for fd = 0, 9 do
				co_cl(ctx, t.sv[fd])
			end
		else -- (only its fds 3-9 are adopted: its stdin/out/err go now — `yes | head` with
			-- lastpipe must EPIPE yes once head is done, not at the pipeline's end)
			for fd = 0, 2 do
				co_cl(ctx, t.sv[fd])
			end
		end
		for _, fd in ipairs(t.own) do -- release its pipe ends: EOF downstream, EPIPE upstream
			co_cl(ctx, fd)
		end
		g.alive = g.alive - 1
		if g.alive == 0 and g.bg then -- a background job ended: its starting fds go too
			for k = 0, 9 do
				co_cl(ctx, g.base.fd[k])
			end
			g.done = true
			if g.on_done then -- (a coproc: disposed as it dies — bash's SIGCHLD reaping)
				pcall(g.on_done, g)
			end
		end
		if g.alive == 0 and g.waiter then -- a stage waiting on this nested pipeline
			ctx.runnable[#ctx.runnable + 1] = g.waiter
			g.waiter.wait = nil
		end
	elseif type(a) == "table" then -- waiting on a nested pipeline group
		t.wait = a
	elseif a == nil then -- preempted (M.preempt): runnable again, after the others
		t.wait = nil
		ctx.runnable[#ctx.runnable + 1] = t
		ctx.npre = true
	else
		t.wait, t.wev = a, b
	end
end

-- Finish a group: adopt a lastpipe stage's state into the (now current) shell, set
-- $PIPESTATUS/$?.
local function co_finish(ctx, self, g)
	local lp = g.lp
	if lp then
		self.out = g.lp_out
		for k = 3, 9 do -- fds the last stage opened/closed persist, like the shell's own
			if lp.fd[k] >= 0 then
				C.dup2(lp.fd[k], k)
			else
				C.close(k)
			end
		end
		for k = 0, 9 do
			co_cl(ctx, lp.sv[k])
		end
		C.environ = env_same(lp.env, g.base.env) and g.base.env or lp.env
		local cw = cwd_str()
		if lp.cwd ~= cw then
			C.curse_co_chdir(lp.cwd)
		end
		ctx.cur_cwd = lp.cwd
		C.curse_co_umask(lp.um)
		if g.upv then
			g.upv.set(unpack(lp.upv, 1, g.upv.n))
		end
	end
	local last, pipe, pstat = 0, 0, {}
	for k = 1, g.n do
		local est = g.status[k] or 0
		pstat[k] = tostring(est)
		if k == g.n then
			last = est
		end
		if est ~= 0 then
			pipe = est
		end
	end
	self:array_assign("PIPESTATUS", pstat, false)
	self.status = self.opt_pipefail and pipe or last
	self.last_stage_status = last -- (the ERR quirk for a failing `( … )` last stage)
end

-- The shell leaves the scheduler: its snapshot's fd copies go; with no task left alive the
-- whole context is released (every tracked fd, the environ copies).
local function sched_release(ctx, P)
	for k = 0, 9 do
		co_cl(ctx, P.fd[k])
	end
	C.curse_co_sigtimedwait(_co_sigpipe, nil, _co_zero_ts) -- drop a SIGPIPE still pending
	C.sigprocmask(2, ctx.oldmask, nil)
	if next(ctx.bycoro) == nil and ctx == SCHED then
		for fd in pairs(ctx.fds) do
			C.close(fd)
		end
		for _, e in ipairs(ctx.envs) do
			if e ~= C.environ then -- (a lastpipe stage's environ may now BE the shell's)
				C.curse_co_free(e)
			end
		end
		SCHED = nil
	end
end
-- Run the pipeline under the scheduler. `inproc[i]` (compile time): run stage i
-- in-process; otherwise it forks (a stage that needs a real child — exec, ulimit,
-- set, eval, … see EF.sub_unsafe_fn), scheduled uniformly. `upv_get/upv_set` (when the
-- module has lifted upvalues) let the scheduler swap them per stage like fds. A
-- pipeline nested inside a running stage joins the SAME scheduler as a new group and
-- that stage waits on it. Returns nil (caller falls back to forking) on setup failure.
function Shell:run_pipeline_co(stage_fns, inproc, lastpipe, upv_get, upv_set)
	local upv
	if upv_get then
		upv = { get = upv_get, set = upv_set, n = select("#", upv_get()) }
	end
	if CO then -- nested: the running stage launches a group and waits on it
		local T = co_task()
		if not T then
			return nil
		end
		local ctx = CO
		pre_yield(T) -- T's buffered output must precede its sub-stages'
		local base = { fd = {}, env = C.environ, cwd = cwd_str() or ctx.cur_cwd }
		for k = 0, 9 do
			base.fd[k] = co_cx(ctx, k)
		end
		base.um = C.curse_co_umask(0)
		C.curse_co_umask(base.um)
		if upv then
			base.upv = { upv_get() }
		end
		local g = co_launch(ctx, self, stage_fns, inproc, base, lastpipe, upv)
		if g and g.alive > 0 then
			g.waiter = T
			coroutine.yield(g)
		end
		for k = 0, 9 do
			co_cl(ctx, base.fd[k])
		end
		if not g then
			return nil
		end
		co_finish(ctx, self, g)
		if g.lp_raise then -- the lastpipe stage exited/returned: so does the shell/function
			error(g.lp_raise, 0)
		end
		return true
	end

	real_flush()
	local ctx = sched_get() -- (shared with any live background jobs)
	local P = { fd = {}, env = C.environ, cwd = self:phys_cwd() }
	for k = 0, 9 do
		P.fd[k] = co_cx(ctx, k)
	end
	P.um = C.curse_co_umask(0)
	C.curse_co_umask(P.um)
	if upv then
		P.upv = { upv_get() }
	end
	ctx.P, ctx.cur_cwd = P, P.cwd
	ctx.oldmask = ffi.new("uint8_t[128]")
	C.sigprocmask(0, _co_sigpipe, ctx.oldmask) -- SIG_BLOCK: a dead reader is EPIPE, not our death
	CO = ctx
	local g
	local ok_all, err_all = pcall(function()
		g = co_launch(ctx, self, stage_fns, inproc, P, lastpipe, upv)
		if not g then
			return
		end
		local pf, pfn = nil, 0
		while g.alive > 0 do
			local runnable = ctx.runnable
			ctx.runnable = {}
			for _, t in ipairs(runnable) do
				co_resume(ctx, t)
			end
			if g.alive == 0 then
				break
			end
			if #ctx.runnable == 0 then -- nothing ready to run: wait in poll
				local waiting, tick = {}, false
				for _, t in pairs(ctx.bycoro) do
					if not t.done and t.wait ~= nil and type(t.wait) ~= "table" then
						if t.wait == -1 then
							tick = true
						end
						waiting[#waiting + 1] = t
					end
				end
				if #waiting > pfn then
					pfn = #waiting * 2
					pf = ffi.new("struct curse_co_pollfd[?]", pfn)
				end
				local cnt = 0
				for _, t in ipairs(waiting) do
					if t.wait ~= -1 then
						local w = t.wait
						if w <= 9 then
							w = t.fd[w] -- a user-range fd: poll the stage's own saved copy
						end
						pf[cnt].fd, pf[cnt].events, pf[cnt].revents = w, t.wev, 0
						cnt = cnt + 1
					end
				end
				local r = C.curse_co_poll(pf, cnt, tick and 10 or -1)
				local k = 0
				for _, t in ipairs(waiting) do
					if t.wait == -1 then
						if tick then
							t.wait = nil
							ctx.runnable[#ctx.runnable + 1] = t
						end
					else
						if r > 0 and pf[k].revents ~= 0 then
							t.wait = nil
							ctx.runnable[#ctx.runnable + 1] = t
						end
						k = k + 1
					end
				end
			end
		end
	end)
	CO = nil
	for fd = 0, 9 do -- the parent's fds back (a lastpipe stage's 3-9 are adopted below)
		if P.fd[fd] >= 0 then
			C.dup2(P.fd[fd], fd)
		else
			C.close(fd)
		end
	end
	C.environ = P.env
	C.curse_co_umask(P.um)
	if cwd_str() ~= P.cwd then
		C.curse_co_chdir(P.cwd)
	end
	ctx.cur_cwd = P.cwd
	if ok_all and g then
		co_finish(ctx, self, g)
		if g.lp_raise then -- the lastpipe stage exited/returned: so does the shell/function
			error(g.lp_raise, 0)
		end
		if upv and not g.lp then
			upv.set(unpack(P.upv, 1, upv.n)) -- stages swapped them; the parent's are back
		end
	elseif upv then
		upv.set(unpack(P.upv, 1, upv.n))
	end
	sched_release(ctx, P)
	if not ok_all then
		error(err_all)
	end
	return g ~= nil or nil
end

-- ---- Background jobs, in-process -------------------------------------------
-- `cmd &` is a one-stage task group in the persistent scheduler, started from the
-- launcher's current fds/environ/cwd/umask (stdin </dev/null without job control) and
-- NOT waited for. Its tasks run whenever the shell would block — M.co_block,
-- M.wait_child, M.fd_wait, `wait`, the script's end (M.sched_drain) — and alongside any
-- pipeline. $! is a virtual pid (also the job's $BASHPID); `kill $!` delivers to it.
--
-- The shell (not itself a task) runs the scheduler until `w` holds: w.fd ready for w.ev,
-- w.deadline passed, w.until() true — or, with none given, until nothing can run now.
-- Returns true when w.fd became ready.
function M.sched_pump(w)
	local ctx = SCHED
	if CO or not ctx or next(ctx.bycoro) == nil then
		return false
	end
	real_flush()
	local P = { fd = {}, env = C.environ, cwd = cwd_str() or "." }
	for k = 0, 9 do
		P.fd[k] = co_cx(ctx, k)
	end
	P.um = C.curse_co_umask(0)
	C.curse_co_umask(P.um)
	ctx.P, ctx.cur_cwd = P, P.cwd
	ctx.oldmask = ffi.new("uint8_t[128]")
	C.sigprocmask(0, _co_sigpipe, ctx.oldmask)
	CO = ctx
	local ready = false
	local ok, err = pcall(function()
		local pf, pfn = nil, 0
		while true do
			local runnable = ctx.runnable
			ctx.runnable = {}
			for _, t in ipairs(runnable) do
				co_resume(ctx, t)
			end
			if w.untilf and w.untilf() then
				return
			end
			-- a job preempted this round is runnable again at once; still poll (without
			-- blocking) so the waiter's fd, its deadline, and jobs waiting on I/O get their
			-- turn — a computing job must not starve them
			local busy = #ctx.runnable > 0
			if not busy or ctx.npre then
				ctx.npre = nil
				local waiting, tick = {}, false
				for _, t in pairs(ctx.bycoro) do
					if not t.done and t.wait ~= nil and type(t.wait) ~= "table" then
						if t.wait == -1 then
							tick = true
						end
						waiting[#waiting + 1] = t
					end
				end
				local blocking = w.fd or w.untilf or w.deadline
				if not blocking and (#waiting == 0 or busy) then
					return -- (a plain pump: only what could run right now)
				end
				if #waiting + 1 > pfn then
					pfn = (#waiting + 1) * 2
					pf = ffi.new("struct curse_co_pollfd[?]", pfn)
				end
				local cnt = 0
				if w.fd then
					local f = w.fd
					if f <= 9 then
						f = P.fd[f] -- (the shell's own fd, parked meanwhile)
					end
					pf[0].fd, pf[0].events, pf[0].revents = f, w.ev or POLLIN, 0
					cnt = 1
				end
				local base = cnt
				for _, t in ipairs(waiting) do
					if t.wait ~= -1 then
						local wf = t.wait
						if wf <= 9 then
							wf = t.fd[wf]
						end
						pf[cnt].fd, pf[cnt].events, pf[cnt].revents = wf, t.wev, 0
						cnt = cnt + 1
					end
				end
				local tmo = -1
				if not blocking or busy then
					tmo = 0
				elseif tick then
					tmo = 10
				end
				if w.deadline then
					local left = math.max(0, math.ceil((w.deadline - M.wall_secs()) * 1000))
					tmo = (tmo < 0 or left < tmo) and left or tmo
				end
				if cnt == 0 and tmo < 0 then
					return -- (nothing to wait on: never block forever)
				end
				local r = C.curse_co_poll(pf, cnt, tmo)
				if w.fd and r > 0 and pf[0].revents ~= 0 then
					ready = true
					return
				end
				local k = base
				for _, t in ipairs(waiting) do
					if t.wait == -1 then
						if tick then
							t.wait = nil
							ctx.runnable[#ctx.runnable + 1] = t
						end
					else
						if r > 0 and pf[k].revents ~= 0 then
							t.wait = nil
							ctx.runnable[#ctx.runnable + 1] = t
						end
						k = k + 1
					end
				end
				if w.deadline and M.wall_secs() >= w.deadline then
					return
				end
				if not blocking and #ctx.runnable == 0 then
					return
				end
			end
		end
	end)
	CO = nil
	for fd = 0, 9 do -- the shell's own state back
		if P.fd[fd] >= 0 then
			C.dup2(P.fd[fd], fd)
		else
			C.close(fd)
		end
	end
	C.environ = P.env
	C.curse_co_umask(P.um)
	if cwd_str() ~= P.cwd then
		C.curse_co_chdir(P.cwd)
	end
	ctx.cur_cwd = P.cwd
	sched_release(ctx, P)
	if not ok then
		error(err, 0)
	end
	return ready
end
-- Wait until every task group in `gs` has ended: inside a task, by yielding on each (the
-- scheduler requeues a group's waiter when it ends); from the shell, by pumping.
function M.wait_groups(gs, intr) -- (intr: as wait_child's)
	local t = co_task()
	for _, g in ipairs(gs) do
		while not g.done and not (intr and intr.wait_sig) do
			if t then
				g.waiter = t
				pre_yield(t)
				if coroutine.yield(g) == SIGMARK then
					task_signals(t)
				end
			else
				M.sched_pump({ untilf = function()
					return g.done or (intr and intr.wait_sig ~= nil)
				end })
				if not g.done and not sched_live() then
					break
				end
			end
		end
	end
end
-- Run every background job to its end (the script is over; bash would leave them
-- running — in-process they must finish before this process can).
function M.sched_drain()
	if sched_live() and not CO then
		-- the shell is done with its stdin/out/err: let go of them first, so a caller
		-- reading our output sees EOF unless a job itself still holds it (as with bash,
		-- whose exited shell holds nothing) — jobs install their own copies to run
		real_flush()
		local dn = C.open("/dev/null", 2, 0)
		if dn >= 0 then
			for fd = 0, 2 do
				C.dup2(dn, fd)
			end
			C.close(dn)
		end
		for fd = 3, 9 do -- (and whatever else it had open for itself)
			C.close(fd)
		end
		-- …and its ends of the coproc pipes (kept at 10+): an exited bash holds none, so the
		-- coproc sees EOF and ends — else `coproc cat` waits on us and we on it, forever
		local sh = M.cur_shell
		for _, cp in pairs(sh and sh.coprocs or {}) do
			if cp.r and cp.r >= 0 then
				C.close(cp.r)
			end
			if cp.w and cp.w >= 0 then
				C.close(cp.w)
			end
			cp.r, cp.w = -1, -1
		end
	end
	while sched_live() and not CO do
		M.sched_pump({ untilf = function()
			return next(SCHED.bycoro) == nil
		end })
	end
end

-- A simple-command job with redirections applies them as `exec` would (no saved originals
-- to hold a pipe open while it runs — the job ends with the command, like bash's child
-- that execs it): `exec REDIRS && CMD`. Returns cmd itself when it has none.
function M.bg_tail_stmt(cmd)
	if cmd.t ~= "simple" or not cmd.redirs or #cmd.redirs == 0 or not cmd.words or #cmd.words == 0 then
		return cmd
	end
	local bare = {}
	for k, v in pairs(cmd) do
		bare[k] = v
	end
	bare.redirs = nil
	local ex = { t = "simple", line = cmd.line, redirs = cmd.redirs,
		words = { { k = "word", parts = { { lit = "exec", q = false } }, src = "exec" } } }
	return { t = "andor", line = cmd.line, items = { { cmd = ex }, { op = "&&", cmd = bare } } }
end
-- opts (optional): fds = { [k] = fd } starts it with fd k = a dup of fd (a process
-- substitution's pipe end); keepstdin (no </dev/null); nojob (not in the job table).
function Shell:bg_launch(fn, cmdstr, flat, simple, upv_get, upv_set, opts)
	local ctx = sched_get()
	local upv
	if upv_get then
		upv = { get = upv_get, set = upv_set, n = select("#", upv_get()) }
	end
	local t0 = co_task()
	if t0 then
		pre_yield(t0)
	else
		real_flush()
	end
	-- its starting state: the launcher's current one (inside a task, fds 0-9 ARE that task's)
	local base = { fd = {}, env = C.environ, cwd = cwd_str() or "." }
	for k = 0, 9 do
		base.fd[k] = co_cx(ctx, k)
	end
	local piped = t0 and t0.i and t0.i > 1 -- (in a later pipeline stage: stdin is that pipe)
	opts = opts or {}
	for k, fd in pairs(opts.fds or {}) do
		co_cl(ctx, base.fd[k])
		base.fd[k] = co_cx(ctx, fd)
	end
	if not self.opt_m and (self.stdin_redir or 0) == 0 and not piped and not opts.keepstdin
		and not (opts.fds and opts.fds[0]) then -- (async: stdin </dev/null)
		co_cl(ctx, base.fd[0])
		local dn = C.open("/dev/null", 0, 0)
		base.fd[0] = dn >= 0 and co_cx(ctx, dn) or -1
		if dn >= 0 then
			C.close(dn)
		end
	end
	base.um = C.curse_co_umask(0)
	C.curse_co_umask(base.um)
	if upv then
		base.upv = { upv_get() }
	end
	local vpid = M.alloc_vpid()
	local g = co_launch(ctx, self, { fn }, { flat and "flat" or true }, base, false, upv)
	if not g then
		for k = 0, 9 do
			co_cl(ctx, base.fd[k])
		end
		return nil
	end
	g.bg, g.vpid, g.simple = true, vpid, simple
	for _, t in pairs(ctx.bycoro) do
		if t.g == g then
			M.vpid_tasks[vpid] = t -- (`kill $!` before it has even run)
		end
	end
	local bufcap = self.capturing and self.out ~= io.write and not CO_OUTS[self.out]
	for _, t in pairs(ctx.bycoro) do
		if t.g == g and t.sh then
			t.sh.in_pipestage = (t.sh.in_pipestage or 1) - 1 -- (not a pipeline stage: an async list)
			t.sh.in_subprogram = (t.sh.in_subprogram or 0) + 1
			t.sh.loopdepth = g.simple and self.loopdepth or 0 -- (a simple job keeps it: stage_kind)
			if bufcap then -- inside a buffered $(…): its output is the substitution's too
				t.sh.out, t.sh.capturing = self.out, true
			end
		end
	end
	-- (a $(…) ends only when the jobs HOLDING its output have — it reads to EOF, as bash's
	-- pipe does; a job whose fds don't include the capture isn't waited for)
	local holds = bufcap
	if not holds and self.cap_sink then
		for k = 0, 9 do
			if base.fd[k] >= 0 and M.fd_ident(base.fd[k]) == self.cap_sink then
				holds = true
			end
		end
	end
	if self.cap_jobs and holds then
		self.cap_jobs[#self.cap_jobs + 1] = g
	end
	if opts.nojob then
		self.last_bg_pid = tostring(vpid)
		return { pid = vpid, g = g }
	end
	local job = M.job_add(self, vpid, cmdstr)
	job.g = g
	self.bg_pids = self.bg_pids or {}
	self.bg_pids[#self.bg_pids + 1] = vpid
	self.status = 0
	return job
end

-- Signals `kill` aimed at a background job's virtual pid: delivered when the task
-- resumes (its yield returns SIGMARK): its own trap runs, an ignored one does nothing, the
-- default action ends the job (128+sig) via the iso context's unwinding.
task_signals = function(t)
	local sigs = t.pending
	t.pending = nil
	local ctx = t.sh and t.sh.iso_ctx and t.sh.iso_ctx[1]
	for _, sig in ipairs(sigs or {}) do
		if ctx then
			M.iso_signal(t.sh, ctx, sig)
		end
	end
end
function M.task_kill(t, sig)
	if t.done then
		return false
	end
	if sig == 0 then
		return true
	end
	-- a simple command's job IS its command (bash execs it in the job's process): a
	-- running external takes the signal itself, and the job ends with its status
	if t.g.simple and t.child_pid then
		t.g.killed = true -- (for `wait`'s report, should the command die of it)
		return C.kill(t.child_pid, sig) == 0
	end
	t.pending = t.pending or {}
	t.pending[#t.pending + 1] = sig
	if t.wait ~= nil and type(t.wait) ~= "table" then -- wake it
		t.wait = nil
		local ctx = SCHED
		if ctx then
			ctx.runnable[#ctx.runnable + 1] = t
		end
	end
	return true
end

-- kill_pid for a whole job (`kill %N`, jobs.c): bash signals each of the job's processes —
-- for a pipeline job, every stage (a simple command stage IS its external command) — so
-- the stages of the pipeline its task is waiting on get it too, then the task itself.
function M.task_kill_job(t, sig)
	local pg = t.g.pipe and type(t.wait) == "table" and t.wait
	if pg and SCHED and sig ~= 0 then
		for _, st in pairs(SCHED.bycoro) do
			if st.g == pg and not st.done then
				if st.simple and st.child_pid then
					C.kill(st.child_pid, sig)
				else
					M.task_kill(st, sig)
				end
			end
		end
	end
	return M.task_kill(t, sig)
end

local run_pipeline_body
-- `! pipeline` with errexit ON: errexit is ignored for everything it runs — a called
-- function, an eval, a subshell (bash adds CMD_IGNORE_RETURN, like a condition) — so run
-- it with noerr raised, restored on unwind. (With errexit OFF bash doesn't: a `set -e`
-- inside a called function then takes effect.)
function Shell:run_pipeline(stage_fns, negate, inproc, upv_get, upv_set)
	if not (negate and self.opt_e) then
		return run_pipeline_body(self, stage_fns, negate, inproc, upv_get, upv_set)
	end
	self.noerr = self.noerr + 1
	local ok, err = pcall(run_pipeline_body, self, stage_fns, negate, inproc, upv_get, upv_set)
	self.noerr = self.noerr - 1
	if not ok then
		error(err, 0)
	end
end
run_pipeline_body = function(self, stage_fns, negate, inproc, upv_get, upv_set)
	local nst = #stage_fns
	if nst == 1 then -- defensive: a single stage (emit delegates `! cmd` for exact errexit)
		stage_fns[1](self)
	elseif
		inproc
		and self:run_pipeline_co(stage_fns, inproc, self.shopt.lastpipe and not self.opt_i, upv_get, upv_set)
	then -- ran under the coroutine scheduler (status/PIPESTATUS set)
	else
		io.flush() -- flush parent stdio so forked stages don't duplicate buffered output
		local lastpipe = self.shopt.lastpipe and not self.opt_i and nst >= 2
		local pids, prev_read, inline_status = {}, -1, nil
		for k = 1, nst do
			local rd, wr = -1, -1
			if k < nst then
				local p = ffi.new("int[2]")
				M.pipe_hi(p)
				rd, wr = p[0], p[1]
			end
			if k == nst and lastpipe then -- last stage runs in the current shell (side effects persist)
				local save0 = M.save_fd(0)
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
				M.pipe_hi(cp)
				local pid = M.fork()
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
					M.child_exit(self, self.status or 0)
				end
				pids[k] = pid
				if prev_read >= 0 then
					C.close(prev_read)
					prev_read = -1
				end
				C.close(cp[1])
				local chunks, rbuf = {}, ffi.new("char[65536]")
				while true do
					M.co_block(cp[0], POLLIN)
					local n = tonumber(C.read(cp[0], rbuf, 65536))
					if n <= 0 then
						break
					end
					chunks[#chunks + 1] = ffi.string(rbuf, n)
				end
				C.close(cp[0])
				self.out(table.concat(chunks))
			else
				local pid = M.fork()
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
					M.child_exit(self, self.status or 0)
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
				M.wait_child(pids[k], stbuf, 0)
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
		self.last_stage_status = last
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
-- A plain short decimal (1-15 digits, nothing else): exact as a double. A byte loop,
-- not a pattern — LuaJIT compiles it (it doesn't compile string patterns).
local function short_digits(s)
	local n = #s
	if n == 0 or n > 15 then
		return false
	end
	for k = 1, n do
		local c = s:byte(k)
		if c < 48 or c > 57 then
			return false
		end
	end
	return true
end
M.short_digits = short_digits
local function str_to_i64(s)
	if s == nil or s == "" then
		return i64(0)
	end
	if short_digits(s) then
		return i64(tonumber(s))
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
-- bash's legal_number (general.c) as a double (counts, fds, …): see M.legal_i64 for the
-- acceptance rules (`0x10`, `1e2`, junk and intmax overflow are not numbers). Or nil.
function M.legal_number(s)
	local n = M.legal_i64(s)
	return n and tonumber(n)
end
-- bash's sh_invalidnum wording for a bad number S (builtins/common.c)
function M.invalidnum_msg(s)
	if s:match("^0%d") then
		return "invalid octal number"
	elseif s:match("^0x") then
		return "invalid hex number"
	end
	return "invalid number"
end
-- legal_number returning the EXACT int64 (test's -eq/-lt…, -v N, -t N compare past 2^53),
-- or nil: the same acceptance (isspace lead, sign, digits, blank tail, no ERANGE).
function M.legal_i64(s)
	if type(s) ~= "string" then
		return nil
	end
	local sign, digits, rest = s:match("^[ \t\n\v\f\r]*([+-]?)(%d+)(.*)$")
	if not digits or (rest ~= "" and not rest:match("^[ \t]*$")) then
		return nil
	end
	local d = digits:match("^0*(%d-)$")
	if #d > 19 or (#d == 19 and d > (sign == "-" and "9223372036854775808" or "9223372036854775807")) then
		return nil -- (ERANGE)
	end
	local n = i64(0) -- (accumulated negative: -2^63 has no positive twin)
	for i = 1, #d do
		n = n * 10LL - i64(d:byte(i) - 48)
	end
	return sign == "-" and n or -n
end

-- `return [n]` status: no arg -> current $?; a numeric arg -> n mod 256; a
-- non-numeric arg -> 2 + diagnostic (bash). A pure runtime primitive the compiled
-- tier calls directly (no interp).
function M.return_status(sh, value, name)
	if value == nil then
		return name == "exit" and M.exit_default(sh) or M.return_default(sh)
	end
	local n = M.legal_i64(value) -- (get_exitstat: legal_number, then & 255)
	if not n then
		io.stderr:write("curse: " .. (name or "return") .. ": " .. value .. ": numeric argument required\n")
		return 2
	end
	return tonumber(bit.band(n, 255))
end
-- A bare `return` in a trap handler (not DEBUG) — or in a function it calls — gives the
-- status from before the trap ran; a bare `exit` does so only in the EXIT trap (bash's
-- trap_saved_exit_value, builtins/common.c get_exitstat / exit.def).
function M.return_default(sh)
	if (sh.in_trap or 0) > 0 and not sh.in_debug and sh.trap_saved ~= nil then
		return sh.trap_saved
	end
	return sh.status
end
function M.exit_default(sh)
	if sh.in_exit_trap and sh.trap_saved ~= nil then
		return sh.trap_saved
	end
	return sh.status
end
-- A compiled function (fn_x) in a program with traps: a trap handler's `return N` raised
-- while its body runs natively ends this call with status N (interp's run_function and the
-- delegated-statement wrappers catch it the same way). bash: execute_function's return_catch.
function M.catch_return(f)
	return function(sh, pc)
		local ok, e = pcall(f, sh, pc)
		if not ok then
			if type(e) == "table" and e.__curse_return ~= nil then
				sh.status = e.__curse_return
			else
				error(e, 0)
			end
		end
	end
end
-- `return` where no function or sourced script is running: reported, status 2 (bash) —
-- also in a trap handler that runs at the top level (return.def: no return_catch_flag)
function M.return_outside(sh)
	if (sh.calldepth or 0) == 0 and (sh.sourcedepth or 0) == 0 then
		io.stderr:write("curse: return: can only `return' from a function or sourced script\n")
		sh.status = 2
		if sh.opt_posix and not sh.opt_i then -- a special builtin's error ends a posix shell
			error({ __curse_exit = 2 })
		end
		return true
	end
	return false
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
	local c1 = s:byte(1)
	if c1 >= 49 and c1 <= 57 and short_digits(s) then -- plain decimal, no
		return i64(tonumber(s)) -- leading 0 (octal) — exact as a double; the common case
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
-- bash's ipow (expr.c): square-and-multiply on wrapping int64 — `1 ** 3000000000` is
-- instant (a multiply-n-times loop took forever)
function M.ipow_raw(base, exp)
	local r, b, e = i64(1), i64(base), i64(exp)
	while e ~= 0 do
		if bit.band(e, 1) ~= 0 then
			r = r * b
		end
		e = bit.rshift(e, 1)
		b = b * b
	end
	return r
end
function M.ipow(base, exp, etxt, etok)
	if exp < 0 then
		M.arith_fault(etxt, etok, "exponent less than 0")
	end
	return M.ipow_raw(base, exp)
end

-- Division/modulo with bash's fatal divide-by-zero (aborts the command, status 1).
-- __curse_matherr lets a protected caller (compgen -F) recover; __curse_lineabort
-- makes run_lazy fast-forward past the rest of the current input LINE (bash's
-- line-oriented abort). Shared by both tiers so the compiled path faults alike.
-- (etxt/etok: the expression + bash's error token, baked in by the compiler when known)
local function div0(etxt, etok, msg)
	msg = msg or "division by 0"
	if etxt then
		msg = require("parser").arith_errmsg(etxt, { msg = msg, tok = etok })
	end
	io.stderr:write("curse: " .. msg .. "\n")
	error({ __curse_exit = 1, __curse_matherr = true, __curse_lineabort = true })
end
M.arith_fault = div0
function M.idiv(l, r, etxt, etok)
	if r == i64(0) then
		div0(etxt, etok)
	end
	return l / r
end
function M.imod(l, r, etxt, etok)
	if r == i64(0) then
		div0(etxt, etok)
	end
	return l % r
end

-- int64 -> decimal string with no cdata "LL" suffix (what bash would print).
local function i64_to_str(n)
	local d = tonumber(n)
	if d > -1e14 and d < 1e14 then -- (exact as a double, printed without an exponent)
		return tostring(d)
	end
	return (tostring(n):gsub("LL$", ""))
end
M.i64_to_str = i64_to_str

-- Indexed-array KEYS. LuaJIT's LUA_NUMBER is a double, so a Lua-number key loses
-- precision above 2^53 (distinct huge int64 indices would collide), and tostring
-- prints one past 1e14 with an exponent. Key by a plain NUMBER below 1e14 (the
-- common, fast case — numeric hashing, no string churn; tostring prints it as bash
-- would) and by the canonical decimal STRING beyond (exact). The two key spaces
-- never overlap (t[5] vs t["5"] differ), and a given index always maps to the same
-- key, so writes and reads agree.
local I64_NUMKEY = 100000000000000LL -- 1e14
local function to_arr_key(v) -- v: int64 -> number|string key
	if v > -I64_NUMKEY and v < I64_NUMKEY then
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
	r = "opt_r", -- restricted (no long -o name; can't be turned back off)
}
-- options that default ON (nil field state == off for the rest).
M.SETDEFAULT = { opt_B = true, opt_h = true, opt_icomments = true }
function M.opt_on(sh, field)
	local v = sh[field]
	if v ~= nil then
		return v
	end
	if field == "opt_emacs" or field == "opt_H" or field == "opt_history" then
		return sh.opt_i and true or false
	end -- emacs/histexpand/history are on only when interactive
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
	if op == "-t" then -- fd is a terminal: a legal_number that survives the (int) cast
		local n = M.legal_i64(path)
		return n ~= nil and n >= -2147483648LL and n <= 2147483647LL and C.isatty(tonumber(n)) == 1
	end
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
	if op == "-N" then -- modified since last read: mtime newer than atime
		local as, an = ffi.cast("int64_t *", _ft_a + 72)[0], ffi.cast("int64_t *", _ft_a + 80)[0]
		local ms, mn = ffi.cast("int64_t *", _ft_a + 88)[0], ffi.cast("int64_t *", _ft_a + 96)[0]
		return ms > as or (ms == as and mn > an)
	end
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
		local pw = M.pw_by_uid(tonumber(ffi.C.getuid())) -- (HOME unset: the user's passwd entry)
		return pw and pw.dir ~= "" and (pw.dir .. r) or s
	end
	if r == "+" or r:sub(1, 2) == "+/" or r:sub(1, 2) == "+:" then -- ~+: $PWD's value (unset: literal)
		if sh.vars[sh:deref("PWD")] == nil then
			return s
		end
		return sh:get("PWD") .. r:sub(2)
	end
	-- ~N / ~+N / ~-N: an entry of the directory stack (N from the top, -N from the bottom);
	-- the current-directory entry is $PWD's value (pushd.def get_dirstack_from_string)
	local sign, num, tail = r:match("^([+-]?)(%d+)(.*)$")
	if num and (tail == "" or tail:sub(1, 1) == "/" or tail:sub(1, 1) == ":") then
		local ds = sh:dirstack_array()
		local n = tonumber(num)
		local i = (sign == "-") and #ds - n or n + 1
		if i == 1 then
			if sh.vars[sh:deref("PWD")] == nil then
				return s
			end
			return sh:get("PWD") .. tail
		end
		local e = ds[i]
		if e then
			return e .. tail
		end
		return s
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

-- `more`: further (quoted/expansion) parts follow this literal, so a LAST segment with
-- no `/` has its tilde-prefix running into them — not a pure literal, so no expansion.
-- `cont`: this literal continues text before it (a later part of the word), so its first
-- segment isn't at a segment start and never expands.
function M.tilde_assign(sh, s, more, cont)
	if not s:find("~", 1, true) then
		return s
	end -- fast path: nothing to expand
	local segs = {}
	for seg in (s .. ":"):gmatch("([^:]*):") do
		segs[#segs + 1] = seg
	end
	for k = cont and 2 or 1, #segs do
		if not (more and k == #segs and not segs[k]:find("/", 1, true)) then
			segs[k] = M.tilde_prefix(sh, segs[k])
		end
	end
	return table.concat(segs, ":")
end

-- Word-initial unquoted-literal tilde. bash also tilde-expands a word shaped like
-- `NAME=value` (a valid identifier before `=`) as if it were an assignment RHS —
-- at the value start and after each `:` — even for a plain command argument
-- (`echo x=~`). Otherwise only a leading `~` expands.
-- `more`: other parts follow this literal in the word (see tilde_assign) — a prefix with
-- no `/` then includes quoted/expanded text (`~""`, `~$USER`) and stays literal (bash).
-- `noassign`: don't treat `NAME=` specially (posix mode, a non-declaration command).
function M.tilde_word_initial(sh, s, more, noassign)
	local pre, rest = s:match("^([%a_][%w_]*%+?=)(.*)$")
	if not pre and s:find("]", 1, true) then -- (`a[1]=~`: a subscripted assignment word too)
		pre, rest = s:match("^([%a_][%w_]*%b[]%+?=)(.*)$")
	end
	if pre then
		if noassign then
			return s
		end
		return pre .. M.tilde_assign(sh, rest, more)
	end
	if more and not s:find("/", 1, true) then
		return s
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
-- Found commands, shared by every shell this PROCESS runs (a daemon worker serves many
-- scripts): keyed by the PATH string, valid while no PATH directory has changed (an added
-- or removed file changes its directory's mtime) — re-checked once per request (daemon:
-- M.path_epoch). Only positive results, like bash's hash; a PATH with a relative entry
-- (cwd-dependent) isn't cached.
M.path_epoch = 0
local path_cache
local PC = { key = nil, map = {}, sig = nil, epoch = -1 }
local function path_sig(curpath)
	local t = {}
	for dir in (curpath .. ":"):gmatch("([^:]*):") do
		if ffi.C.curse_rt_stat(dir, stbuf_a) == 0 then
			local u = ffi.cast("int64_t *", stbuf_a)
			t[#t + 1] = tostring(u[11]) .. "." .. tostring(u[12]) -- st_mtim (sec, nsec)
		else
			t[#t + 1] = "-"
		end
	end
	return table.concat(t, ",")
end
function path_cache(curpath)
	if curpath:find("^:") or curpath:find("::", 1, true) or curpath:find(":$") or curpath:find("%f[^:][^/]") then
		return nil -- (a relative entry)
	end
	if PC.key ~= curpath then
		PC.key, PC.map, PC.sig, PC.epoch = curpath, {}, path_sig(curpath), M.path_epoch
	elseif PC.epoch ~= M.path_epoch then
		PC.epoch = M.path_epoch
		local sg = path_sig(curpath)
		if sg ~= PC.sig then
			PC.map, PC.sig = {}, sg
		end
	end
	return PC
end
-- The diagnostic for a spawn that failed with errno `rc`. A PATH/hash-resolved command
-- whose file then fails ENOENT is named by its PATH (bash: the hashed file is gone, or
-- — the file exists — its interpreter is: "cannot execute: required file not found").
function M.spawn_errmsg(self, name, execpath, rc)
	local pre = "curse: " .. (self.exec_builtin and "exec: " or "")
	if rc == 2 and not self.exec_builtin and execpath then
		local shown = tostring(name):find("/", 1, true) and M.err_name(tostring(name)) or execpath
		if ffi.C.access(execpath, 0) == 0 then
			return pre .. shown .. ": cannot execute: required file not found\n"
		end
		return pre .. shown .. ": No such file or directory\n"
	end
	return pre .. M.err_name(tostring(name)) .. (rc == 2 and (self.exec_builtin and ": not found\n" or ": command not found\n") or ": Permission denied\n")
end
-- A lookup that found NAME in the hash table HC counts a hit (bash's hash_search). An
-- in-process subshell's table is a shallow copy of its parent's, sharing the entries:
-- an entry is copied into HC (its owner) before its first change there, so the count
-- — like everything else a subshell does — stays in the subshell.
function M.hash_hit(hc, name)
	local e = hc[name]
	if e.owner ~= hc then
		e = { path = e.path, hits = e.hits, seq = e.seq, owner = hc }
		hc[name] = e
	end
	e.hits = e.hits + 1
	return e
end
-- PATHSTR's elements as bash's extract_colon_unit yields them ("" = the current directory):
-- a leading `:` and each `::` give one empty element, a trailing `:` one more
-- (`d1::` is d1 and "", `d1:::` d1, "" and "").
function M.path_units(s)
	local out, p, len = {}, 0, #s -- (p: bash's 0-based *p_index)
	while p < len do
		local i = p
		if i > 0 and s:byte(i + 1) == 58 then
			i = i + 1
		end
		local start = i
		while i < len and s:byte(i + 1) ~= 58 do
			i = i + 1
		end
		p = i
		if i == start then
			if i < len then
				p = p + 1
			end
			out[#out + 1] = ""
		else
			out[#out + 1] = s:sub(start + 1, i)
		end
	end
	return out
end
-- The first executable, non-directory NAME along PATHSTR (no hashing), or nil
function M.path_find(pathstr, name)
	for dir in (pathstr .. ":"):gmatch("([^:]*):") do
		local cd = (dir == "" and "." or dir) .. "/" .. name
		if ffi.C.access(cd, 1) == 0 and ffi.C.curse_rt_stat(cd, stbuf_a) == 0 -- 1 == X_OK
			and bit.band(ffi.cast("uint32_t *", stbuf_a + 24)[0], 0xF000) ~= 0x4000 then
			return cd
		end
	end
end
function Shell:resolve_cmd(name)
	local pl = self.path_lookup
	if pl then -- (`command -p`: the standard path for this ONE lookup — no hashing, no $PATH change)
		self.path_lookup = nil
		return M.path_find(pl, name)
	end
	local curpath = self:get("PATH")
	if self.hashpath and self.hashpath ~= curpath then
		self.hashcache = {}
	end -- PATH changed: rehash
	self.hashpath = curpath
	local c = self.hashcache and self.hashcache[name]
	if c then
		return M.hash_hit(self.hashcache, name).path
	end
	local pc = path_cache(curpath)
	local cand = pc and pc.map[name]
	if not cand then
		for dir in (curpath .. ":"):gmatch("([^:]*):") do
			local cd = (dir == "" and "." or dir) .. "/" .. name
			if
				ffi.C.access(cd, 1) == 0
				and ffi.C.curse_rt_stat(cd, stbuf_a) == 0 -- 1 == X_OK
				and bit.band(ffi.cast("uint32_t *", stbuf_a + 24)[0], 0xF000) ~= 0x4000
			then -- not a dir
				cand = cd
				break
			end
		end
		if cand and pc then
			pc.map[name] = cand
		end
	end
	if cand then
		self.hashcache = self.hashcache or {}
		M.hash_seq = M.hash_seq + 1
		self.hashcache[name] = { path = cand, hits = 1, seq = M.hash_seq }
	end
	return cand
end
function Shell:phys_cwd()
	local p = ffi.C.getcwd(scratch, 4096)
	return p ~= nil and ffi.string(p) or ""
end
-- The physical cwd, kept under a `//` root when the logical path LOGICAL has one
-- (bash's sh_physpath preserves exactly two leading slashes: `cd -P //; pwd -P`).
function M.phys_under(sh, logical)
	local p = sh:phys_cwd()
	if logical:byte(2) == 47 and logical:byte(1) == 47 and logical:byte(3) ~= 47 then
		return "/" .. p
	end
	return p
end
-- Prompt \w / \W (bash's parse.y): \W is the basename (`/` stays `/`) unless $PWD is
-- $HOME; otherwise a $HOME prefix at a path boundary becomes `~` (a HOME of `/` never
-- does). Both then go through trim_pathname: keep any `~` prefix and the last
-- $PROMPT_DIRTRIM components, the middle shown as `...` (never when that saves <= 3).
function M.prompt_dir(sh, base)
	local dir = sh:pwd()
	local hb = sh.vars["HOME"]
	local home = hb and hb.s
	if base and dir ~= home then
		if dir ~= "/" and dir ~= "//" then
			dir = dir:gsub(".*/", "")
		end
	elseif home and #home > 1 and dir:sub(1, #home) == home then
		local c = dir:byte(#home + 1)
		if c == nil or c == 47 then
			dir = "~" .. dir:sub(#home + 1)
		end
	end
	local tb = sh.vars["PROMPT_DIRTRIM"]
	local n = tb and tb.s and tonumber(tb.s:match("^%s*([+-]?%d+)%s*$"))
	if not n or n <= 0 or dir == "" then
		return dir
	end
	local b = 1 -- start of the trimmable part (after a `~user/` prefix)
	if dir:byte(1) == 126 then
		local sl = dir:find("/", 1, true)
		b = sl and sl + 1 or #dir + 1
	end
	if b > #dir then
		return dir
	end
	local _, ndirs = dir:sub(b):gsub("/", "")
	if ndirs < n then
		return dir
	end
	local t = dir:byte(#dir) == 47 and #dir + 1 or #dir
	while t > b do
		if dir:byte(t) == 47 then
			n = n - 1
			if n == 0 then
				break
			end
		end
		t = t - 1
	end
	if t == b or t - b <= 3 then
		return dir
	end
	return dir:sub(1, b - 1) .. "..." .. dir:sub(t)
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
-- The shell's internal idea of the current directory (bash's
-- the_current_working_directory): set by `cd` and at startup, separate from $PWD (which
-- a script may assign freely). `pwd`, the directory stack and cd's relative paths use
-- it; unknown, it is getcwd's answer (get_working_directory).
function Shell:cwd()
	local t = self.tcwd
	if not t then
		t = self:phys_cwd()
		if t ~= "" then
			self.tcwd = t
		end
	end
	return t
end
function Shell:pid()
	if not pid_cache then
		pid_cache = tonumber(ffi.C.getpid())
	end
	return pid_cache
end
-- The dynamic variables `unset` strips of their magic for good (bash's unset of a
-- dynamic var removes the variable and its hooks): special_get then reads them as unset.
M.DYN_SPECIAL = { SECONDS = true, LINENO = true, BASHPID = true, EPOCHSECONDS = true,
	EPOCHREALTIME = true, SRANDOM = true, BASH_SUBSHELL = true, HISTCMD = true, BASH_COMMAND = true,
	BASH_ARGV0 = true, FUNCNAME = true, BASH_SOURCE = true, BASH_LINENO = true, OSTYPE = true,
	MACHTYPE = true, HOSTTYPE = true, DIRSTACK = true }
function Shell:special_get(name)
	-- the one-char specials as the BASE of an operator form (${?:-x} ${$:+y} ${-+z} ${!-w});
	-- the bare $? $$ $- $! go through their own dedicated nodes
	if name == "?" then
		return tostring(self.status)
	elseif name == "$" then
		return tostring(self:pid())
	elseif name == "!" then
		return self.last_bg_pid or ""
	elseif name == "-" then
		return self:dash_flags()
	end
	-- $# as a base value for an operator form (`${##2}` = $# with a `#2` strip); the
	-- bare ${#}/${#@} count and ${#var} length go through their own dedicated nodes.
	if name == "#" then
		return tostring(self.nparams)
	end
	local us = self.unset_specials
	if us and us[name] then
		return ""
	end
	if name == "RANDOM" then
		if self.random_plain then
			return "" -- (after `unset RANDOM` it is an ordinary variable)
		end
		local ctx = iso_cur(self) -- a subshell's RANDOM stream: its own seed, parent's untouched
		if ctx and not ctx.rand then
			ctx.rand = { self.rseed, self.rlast, self.rpid }
			self.rpid = nil
		end
		return tostring(M.random_next(self))
	end
	-- $PWD is a real tracked variable (see :pwd / import_env); once unset it reads
	-- empty like any other var, so special_get does NOT fall back to getcwd here.
	if name == "PPID" then
		return tostring(tonumber(ffi.C.getppid()))
	end
	if name == "EPOCHSECONDS" then
		return tostring(os.time())
	end
	if name == "BASH_COMMAND" then
		return self.cur_cmd and require("deparse").command_text(self.cur_cmd) or ""
	end
	if name == "EPOCHREALTIME" then
		local tv = ffi.new("struct curse_rt_timeval")
		C.curse_rt_gettimeofday(tv, nil)
		return ("%d.%06d"):format(tonumber(tv.tv_sec), tonumber(tv.tv_usec))
	end
	if name == "BASH_ARGV0" then -- reads as $0 (assigning it sets $0: set_str)
		return self.argv0 or ""
	end
	if name == "UID" then
		return tostring(tonumber(ffi.C.getuid()))
	end
	if name == "EUID" then
		return tostring(tonumber(ffi.C.geteuid()))
	end
	if name == "BASH_SUBSHELL" then
		return tostring((self.subdepth or 0) + M.fork_depth)
	end
	if name == "BASHPID" then
		return tostring(self:bashpid())
	end -- fresh: changes in subshells
	if name == "FUNCNAME" then
		return self:in_function() and self.funcstack[1] or ""
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
	if name == "SRANDOM" then -- 32 random bits from the system (bash's getrandom)
		M.urandom = M.urandom or io.open("/dev/urandom", "rb")
		local b = M.urandom and M.urandom:read(4)
		if b and #b == 4 then
			local a1, a2, a3, a4 = b:byte(1, 4)
			return tostring(((a1 * 256 + a2) * 256 + a3) * 256 + a4)
		end
		return tostring(math.random(0, 4294967295))
	end
	if name == "HISTCMD" then -- the history number of the command now running
		return tostring((self.hist_base or 1) + #(self.history or {}) - 1)
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
		local tname
		if b.outer then
			tname = b.outer -- (a function's self-named ref: the SHADOWED var's alias)
		else
			local t = b.s
			local br = t:find("[", 1, true)
			tname = br and t:sub(1, br - 1) or t
			-- An invalid target name (e.g. `#`, `1`, `$1`) isn't a real reference: reading
			-- the nameref yields its own stored string, so resolve to the nameref itself.
			if not tname:match("^[%a_][%w_]*$") then
				return name
			end
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
-- A nameref chain that ends at an ELEMENT of the nameref itself (a -> b -> 'a[1]'): bash
-- warns, drops the nameref attribute and writes that element. Returns the subscript then.
function Shell:self_elem_unref(name)
	local b = self.vars[name]
	local et = b and b.ref and not b.outer and b.s and not b.s:find("[", 1, true) and self:deref_elem(name)
	local sub = et and et:match("^" .. name .. "%[(.+)%]$")
	if sub then
		io.stderr:write("curse: warning: " .. name .. ": removing nameref attribute\n")
		self.vars[name] = nil
	end
	return sub
end
-- The `base[sub]` a nameref CHAIN ends at (`one -> qux -> 'bar[3]'`), or nil when it ends
-- at a whole variable (plain :deref covers that).
function Shell:deref_elem(name)
	for _ = 1, 100 do
		local b = self.vars[name]
		if not b or not b.ref or b.s == nil or b.s == "" then
			return nil
		end
		if b.s:find("[", 1, true) then
			return b.s
		end
		name = b.s
	end
end
-- Mark `name` as a nameref (declare -n); target is the referenced variable name.
-- A nameref target (when one is given) must be a plain identifier, optionally
-- with a subscript (`ref`, `a[0]`, `a[@]`); bash rejects `@`, `*`, `1`, `a b`,
-- `a-b`, empty, … as "invalid variable name for name reference". Returns false
-- (leaving the var untouched) so the caller can report the error + status 1. A
-- nil target (`typeset -n ref` converting an existing var) is NOT validated.
function Shell:make_nameref(name, target, selfok)
	local function valid(t)
		return t:match("^[%a_][%w_]*$") or t:match("^[%a_][%w_]*%[.+%]$")
	end
	local ob = self.vars[name]
	if target ~= nil and target ~= "" and not valid(target) and ob and ob.arr and not ob.ref then
		return false -- (a bad target is reported before the array conflict: bash)
	end
	if ob and ob.arr and not ob.ref then
		return false, "array" -- (an array can't become a reference)
	end
	if ob and ob.ro and not ob.ref then
		return false, "ro"
	end
	if not selfok and ((target or (ob and ob.s)) or ""):match("^[^[]*") == name then -- (`a[0]` too)
		return false, "self"
	end
	if target ~= nil then
		if target == "" then
			return false, "empty" -- (`declare -n r=""`: bash's "not a valid identifier")
		end
		if not valid(target) then
			return false
		end -- explicit target (@/*/1/… rejected)
	else
		-- converting an existing var: its current value becomes the target — bash
		-- rejects the conversion if that value is not a valid target (a non-empty
		-- invalid one; an unset/empty var makes a valid deferred nameref).
		local b = self.vars[name]
		local cur = b and (b.s or (b.n and M.i64_to_str(b.n))) -- (`((r=0))` left a number)
		if cur and not valid(cur) then -- (an EMPTY value too: `r=""; declare -n r`)
			return false
		end
	end
	local b = box(name, self.vars)
	if not b.ref then -- (a plain var becoming a nameref loses its value attributes: bash)
		b.int, b.lower, b.upper, b.cap = nil, nil, nil, nil
	end
	b.ref = true
	if target ~= nil then
		b.s = target
		b.n = nil
		b.arr = nil
	end
	return true
end
-- declare/typeset/local -n NAME[=TARGET]: make the nameref, reporting bash's errors;
-- false = it failed (status 1). `inlocal`: in a function a self reference only warns
-- (twice, as bash) and is made anyway.
function Shell:nameref_decl(cmd, name, target, inlocal)
	local ok, why = self:make_nameref(name, target)
	if ok then
		return true
	end
	if why == "self" and inlocal then
		io.stderr:write("curse: " .. cmd .. ": warning: " .. name .. ": circular name reference\n")
		io.stderr:write("curse: warning: " .. name .. ": circular name reference\n")
		self:make_nameref(name, target, true)
		-- …and it references the SHADOWED `name` (the caller's / global one): alias that
		-- saved box under a hidden name the ref follows (b.outer), so reads and writes hit
		-- the binding restored on return; the alias itself goes away with this frame.
		local saved = self.savedstack[self.pd]
		local e = saved and saved[name]
		if e then
			e.box = e.box or {}
			local alias = name .. "\0" .. self.pd
			self.vars[alias] = e.box
			saved[alias] = saved[alias] or { box = false, seq = e.seq }
			self.vars[name].outer = alias
		end
		return true
	elseif why == "self" then
		io.stderr:write("curse: " .. cmd .. ": " .. name .. ": nameref variable self references not allowed\n")
	elseif why == "array" then
		io.stderr:write("curse: " .. cmd .. ": " .. name .. ": reference variable cannot be an array\n")
	elseif why == "ro" then
		io.stderr:write("curse: " .. cmd .. ": " .. name .. ": readonly variable\n")
	elseif why == "empty" then
		M.bad_ref_target("", cmd)
	else
		local ob = self.vars[name]
		local t = target or (ob and (ob.s or (ob.n and M.i64_to_str(ob.n)))) or ""
		io.stderr:write("curse: " .. cmd .. ": `" .. t .. "': invalid variable name for name reference\n")
	end
	return false
end
function Shell:unref(name)
	local b = self.vars[name]
	if b then
		b.ref = nil
		b.outer = nil
	end
end
function Shell:is_nameref(name)
	local b = self.vars[name]
	return b and b.ref
end
-- ${var@a}: the variable's attribute flags, in bash's order (aA r x i l u n).
-- ${x@a} in compiled code: under set -u a variable with NO VALUE is unbound (bash — even
-- a declared-but-valueless one).
function Shell:attr_string_u(name)
	local b = self.vars[self:deref(name)]
	local has = b and (b.s ~= nil or b.n ~= nil or (b.arr and next(b.arr) ~= nil))
	if self.opt_u and not has and self:special_get(name) == "" then
		io.stderr:write("curse: " .. name .. ": unbound variable\n")
		error({ __curse_exit = self.opt_c and 127 or 1, __curse_lineabort = self.opt_i or nil })
	end
	return self:attr_string(name)
end
-- declared (`declare -r v`, `declare -a a`) but never given a value
function Shell:declared_unset(name)
	local b = self.vars[self:deref(name)]
	if not b then
		return false
	end
	if b.arr then
		return b.empty_decl and next(b.arr) == nil or false
	end
	return b.s == nil and b.n == nil
end
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
	if b.trace then
		s = s .. "t"
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
	if b.cap then
		s = s .. "c"
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

-- `set -r`: restricted from here on (never back). The variables that could escape the
-- restriction become readonly — set or not (bash maybe_make_restricted).
function M.make_restricted(sh)
	sh.opt_r = true
	for _, n in ipairs({ "SHELL", "PATH", "HISTFILE", "ENV", "BASH_ENV" }) do
		local b = sh.vars[n]
		if b then
			b.ro = true
		else
			sh.vars[n] = { ro = true }
		end
	end
end
-- The restricted-shell refusal for `what` (bash's wording), status 1. Returns true when
-- `sh` is restricted (the caller then skips the operation).
-- A restricted shell may only (re)hash a command to a name found by a $PATH search
-- (bash's assign_hashcmd / hash -p): else `NAME: not found`, false.
function M.restricted_hash_ok(sh, what, value)
	if not sh.opt_r then
		return true
	end
	if value:find("/", 1, true) then
		return not M.restricted(sh, what .. value .. ": restricted")
	end
	for dir in ((sh:get("PATH") or "") .. ":"):gmatch("([^:]*):") do
		local cand = (dir == "" and "." or dir) .. "/" .. value
		if M.file_test("-x", cand) and not M.file_test("-d", cand) then
			return true
		end
	end
	io.stderr:write("curse: " .. what .. value .. ": not found\n")
	sh.status = 1
	return false
end
function M.restricted(sh, what)
	if not sh.opt_r then
		return false
	end
	io.stderr:write("curse: " .. what .. "\n")
	sh.status = 1
	return true
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
-- In posix mode an arithmetic EXPANSION error exits a non-interactive shell (bash's
-- posixly_correct FORCE_EOF) instead of abandoning the line: raise that exit for a
-- caught line-abort `err`, else return.
function M.posix_arith_fatal(sh, err)
	if sh.opt_posix and not sh.opt_i and err.__curse_matherr then
		error({ __curse_exit = sh.opt_c and 127 or 1 }, 0)
	end
end
-- `kill -l` / `trap -l`: bash's display_signal_list — `%2d) SIGNAME` five to a line,
-- tab-separated (so a short last line ends in a tab), from a number -> name table
function M.signal_list(numsig)
	local nums = {}
	for n in pairs(numsig) do
		nums[#nums + 1] = n
	end
	table.sort(nums)
	local out, col = {}, 0
	for _, n in ipairs(nums) do
		out[#out + 1] = ("%2d) SIG%s"):format(n, numsig[n])
		col = col + 1
		if col < 5 then
			out[#out + 1] = "\t"
		else
			out[#out + 1] = "\n"
			col = 0
		end
	end
	if col ~= 0 then
		out[#out + 1] = "\n"
	end
	return table.concat(out)
end
-- bash's shell_compatibility_level from $BASH_COMPAT (`5.1` or `51`); 52 when unset/invalid
function M.compat_level(sh)
	local v = sh:get("BASH_COMPAT")
	local a, b = v:match("^(%d)%.(%d)$")
	local n = a and tonumber(a .. b) or (v:match("^%d%d$") and tonumber(v))
	return (n and n >= 31 and n <= 52) and n or 52 -- (sv_shcompat: out of range → the default)
end
-- bash's valid_array_reference: `NAME`, or `NAME[SUB]` whose subscript's brackets balance
-- exactly to the end (`A[]]` is not one). Returns name, sub (nil for a plain name), or nil.
-- An argument that was an UNQUOTED `NAME[…$x…]` word (under assoc_expand_once): bash knows
-- its subscript is everything up to the final `]`, whatever the expansion put there
-- (`read A[$k]` with k=']'), unlike the same text quoted ("A[$k]" -> invalid `A[]]`).
function M.mark_arrayref(sh, s)
	local t = sh.arrayref_args
	if not t then
		t = {}
		sh.arrayref_args = t
	end
	t[s] = true
	return s
end
local plain_names, n_plain = {}, 0 -- (a memo: a valid bare NAME, the common case)
function M.split_array_ref(s, sh)
	if plain_names[s] then
		return s
	end
	local name, rest = s:match("^([%a_][%w_]*)(.*)$")
	if name and rest == "" and n_plain < 4096 then
		plain_names[s], n_plain = true, n_plain + 1
	end
	if not name then
		return nil
	end
	if rest == "" then
		return name
	end
	if rest:sub(1, 1) ~= "[" then
		return nil
	end
	local ar = sh and sh.arrayref_args
	if ar and ar[s] and #rest > 2 and rest:sub(-1) == "]" and sh.shopt.assoc_expand_once
		and sh:is_assoc(name) then
		return name, rest:sub(2, -2)
	end
	-- under assoc_expand_once an assoc's (already expanded) subscript isn't quote-scanned:
	-- only the brackets balance (`A[']` is key ', `A[]]` is invalid) — bash's VA_NOEXPAND
	local raw = sh and sh.shopt.assoc_expand_once and sh:is_assoc(name)
	local depth, n, i = 0, #rest, 1
	while i <= n do -- (quote-aware, like bash's skipsubscript: an unclosed quote is invalid)
		local c = rest:sub(i, i)
		if raw and c ~= "[" and c ~= "]" then -- (a plain char)
		elseif c == "\\" then
			i = i + 1
		elseif c == "'" or c == '"' then
			local e = rest:find(c, i + 1, true)
			if not e then
				return nil
			end
			i = e
		elseif c == "[" then
			depth = depth + 1
		elseif c == "]" then
			depth = depth - 1
			if depth == 0 then
				if i ~= n or i == 2 then
					return nil -- (text after the subscript, or an empty one)
				end
				return name, rest:sub(2, n - 1)
			end
		end
		i = i + 1
	end
	return nil
end
-- A diagnostic reported at line LN rather than the current one.
function M.err_at(sh, ln, msg)
	sh.force_line = ln
	io.stderr:write(msg)
	sh.force_line = nil
end
-- A builtin's usage line, as bash prints it after an option error (help's synopsis).
function M.usage(cmd)
	for _, t in ipairs(require("helpdata")) do
		if t[1] == cmd then
			return cmd .. ": usage: " .. t[2] .. "\n"
		end
	end
	return ""
end
-- bash's builtin_help (`CMD --help`): help's synopsis and long text, status 2 (EX_USAGE).
function M.builtin_help(sh, cmd)
	for _, t in ipairs(require("helpdata")) do
		if t[1] == cmd then
			sh.out(cmd .. ": " .. t[2] .. "\n")
			for _, l in ipairs(t[3]) do
				sh.out(l == true and "\n" or "    " .. l .. "\n")
			end
		end
	end
	sh.status = 2
	sh.spb_err = 2 -- (EX_USAGE: M.spb_run)
end
-- `return N`'s status (bash's get_exitstat): N mod 256, or 2 with a message for a non-number.
function M.return_code(sh, s)
	local n = s:match("^%s*[+-]?%d+%s*$") and tonumber(s)
	if not n then
		io.stderr:write("curse: return: " .. s .. ": numeric argument required\n")
		return 2
	end
	return n % 256
end
-- bash's no_args: `CMD: too many arguments`, and the whole current command is discarded
-- (the rest of the line; all of a -c string).
function M.too_many(sh, cmd)
	io.stderr:write("curse: " .. cmd .. ": too many arguments\n")
	sh.status = 1
	error({ __curse_exit = 1, __curse_lineabort = not sh.opt_c or nil })
end
-- bash's internal_getopt rejection: `CMD: -X: invalid option` + the usage line, status 2.
function M.bad_option(sh, cmd, opt)
	io.stderr:write("curse: " .. cmd .. ": " .. opt .. ": invalid option\n" .. M.usage(cmd))
	sh.status = 2
	sh.spb_err = 2 -- (EX_USAGE: fatal from a special builtin in posix mode — M.spb_run)
end
-- The file a function being defined now belongs to (its ${BASH_SOURCE[0]} and error
-- label): the file being sourced, else the script — but under -c there is none, and bash
-- calls it "environment".
function M.def_source(sh)
	return sh.cur_source or (sh.opt_c and "environment") or sh.argv0 or ""
end
-- A builtin about to assign NAME: a readonly one is refused with bash's message (true).
function M.ro_refuse(sh, name)
	local dn = sh:deref(name)
	local b = sh.vars[dn]
	if b and b.ro then
		io.stderr:write("curse: " .. dn .. ": readonly variable\n")
		return true
	end
	return false
end
-- A builtin assigning to a NAME it was given (read, printf -v, …): a plain name or an array
-- element; anything else is `cmd: `A[]]': not a valid identifier` (status 1). false = refused.
function M.assign_ref(sh, cmd, ref, value)
	-- (the common case, fast — `while read a b`, `printf -v s`, getopts: a plain name whose
	-- variable, if any, has no attribute, array or nameref — is just a string set)
	local b = sh.vars[ref]
	if b == nil then
		if ref:find("^[%a_][%w_]*$") then
			return sh:set_str(ref, value) ~= false
		end
	elseif not (b.ro or b.ref or b.arr or b.int or b.lower or b.upper or b.cap) then
		return sh:set_str(ref, value) ~= false
	end
	local name, sub = M.split_array_ref(ref, sh)
	if not name then
		io.stderr:write("curse: " .. cmd .. ": `" .. ref .. "': not a valid identifier\n")
		sh.status = 1
		return false
	end
	if M.ro_refuse(sh, name) then
		sh.status = 1
		return false
	end
	if sub then
		local key = (sh.shopt.assoc_expand_once and sh:is_assoc(name)) and sub
			or require("interp")._int.array_key(sh, name, sub)
		sh:array_set(name, key, value, false)
		return true
	end
	-- a plain name assigns like `name=value`: through a nameref (to an element, too), to
	-- element 0 of an array, arithmetic for declare -i (its errors name the builtin: bash's
	-- this_command_name), case-folded for -l/-u
	local P = require("parser")
	local sv = P.arith_cmd
	P.arith_cmd = cmd
	local ok, e = pcall(M.assign_scalar, sh, name, value)
	P.arith_cmd = sv
	if not ok then
		error(e, 0)
	end
	return true
end
-- $! : under set -u, unbound until a background job exists (bash names the bare form
-- `$!`, the braced one `!`)
function M.last_bg_u(sh, braced)
	local v = sh.last_bg_pid
	if v == nil and sh.opt_u then
		io.stderr:write("curse: " .. (braced and "!" or "$!") .. ": unbound variable\n")
		error({ __curse_exit = sh.opt_c and 127 or 1, __curse_lineabort = sh.opt_i or nil })
	end
	return v or ""
end
-- $N / ${N} in compiled code: under set -u a missing positional is unbound (bash names
-- the bare form `$9`, the braced one `9`)
function Shell:param_u(n, braced)
	if self.opt_u and n > self.nparams then
		io.stderr:write("curse: " .. (braced and "" or "$") .. n .. ": unbound variable\n")
		error({ __curse_exit = self.opt_c and 127 or 1, __curse_lineabort = self.opt_i or nil })
	end
	return self:param(n)
end
function Shell:get_u(name)
	-- A declared-but-value-less box (`local foo` / `declare x`) is still UNSET for
	-- nounset purposes, so treat it like a missing var. `$x` reads ${x[0]}, so an
	-- array whose element 0 is unset (a bare `declare -a x` / `local -a x`, or a
	-- sparse array with no [0]) is likewise unbound — not merely because b.arr exists.
	local b = self.vars[self:deref(name)]
	local unset
	if b == nil then
		unset = true
	elseif b.arr then
		unset = (b.assoc and b.arr["0"] or b.arr[0]) == nil
	else
		unset = b.s == nil and b.n == nil
	end
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
		if msg:sub(1, 7) == "curse: " then
			msg = M.err_prefix(self) .. msg:sub(8)
		end
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

-- A nameref with no (valid) target takes an assigned value AS its target, and bash rejects
-- one that isn't a variable name — named by the assigning builtin, M.assign_ctx (bash's
-- this_command_name: "declare", "printf", …; nil for a plain assignment).
function M.ref_target_ok(s)
	return s:match("^[%a_][%w_]*$") or s:match("^[%a_][%w_]*%[.+%]$")
end
local ref_target_ok = M.ref_target_ok
function M.bad_ref_target(v, ctx)
	io.stderr:write("curse: " .. (ctx and (ctx .. ": ") or "") .. "`" .. v .. "': not a valid identifier\n")
end
-- declare -l / -u / -c: a value is case-folded on every assignment (scalar or element)
local function case_fold(b, s) -- (declare -l/-u/-c: the locale's folding, per character)
	if b.lower then
		return M.fold_case(s, nil, false, true)
	elseif b.upper then
		return M.fold_case(s, nil, true, true)
	elseif b.cap then
		return M.fold_case(M.fold_case(s, nil, false, true), nil, true, false)
	end
	return s
end
function Shell:set_str(name, s)
	if s:find("\0", 1, true) then
		s = M.cstr(s)
	end -- bash vars are C strings: cut at NUL
	local dn = self:deref(name)
	if (dn == "FUNCNAME" or dn == "SRANDOM" or (dn == "LINENO" and not self.vars.LINENO))
		and not (self.unset_specials and self.unset_specials[dn]) then
		return -- assignments to these have no effect (bash): the call stack, fresh random
		-- bits, the line now running
	end
	local b = box(dn, self.vars)
	if b.ref and not ref_target_ok(s) then
		M.bad_ref_target(s, M.assign_ctx)
		self.status = 1
		return false -- (the one failure a caller may check: a loop stops, as bash's)
	end
	if b.lower or b.upper or b.cap then
		s = case_fold(b, s)
	end
	b.s = s
	b.n = nil
	if dn == "OPTIND" and self.getopts_state then
		self.getopts_state[b] = nil -- assigning OPTIND resets getopts' in-argument position (bash)
	end
	if dn == "BASH_ARGV0" and not (self.unset_specials and self.unset_specials.BASH_ARGV0) then
		self.argv0 = s -- assigning BASH_ARGV0 sets $0 (bash)
	elseif dn == "POSIXLY_CORRECT" then
		self.opt_posix = true -- (bash's sv_strict_posix: setting it enters posix mode)
	elseif dn == "IGNOREEOF" then
		self.opt_ignoreeof = true -- (sv_ignoreeof: any value turns ignoreeof on)
	elseif dn == "RANDOM" and not self.random_plain then
		-- assigning seeds the generator; RANDOM itself stays dynamic (bash assign_random)
		local n = s:match("^%s*[+-]?%d+%s*$") and tonumber(s)
		if n then
			M.random_seed(self, n)
		end
		self.vars.RANDOM = nil
		return
	end
	if b.exported then
		C.setenv(dn, s, 1)
		if dn == "TZ" then -- (bash's sv_tz: an exported TZ takes effect at once)
			M.tzset()
		end
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
				or k == "_" -- (a child's `_` is the program's path, set at each exec — not $_)
				or k == "PPID" -- shell-computed, not from env
				or k == "BASHOPTS"
			then -- readonly, derived live from the option state
			elseif k == "SHELLOPTS" then -- inherited set -o options: enable them (bash), keep exported
				self.shellopts_import = s:sub(eq + 1)
				self.shellopts_exported = true
			elseif k:match("^[%a_][%w_]*$") then
				self:set_str(k, s:sub(eq + 1))
				self.vars[k].exported = true -- inherited env vars are exported (bash)
			elseif k:match("^BASH_FUNC_.+%%%%$") then -- an exported function (M.import_functions)
				self.fimports = self.fimports or {}
				self.fimports[#self.fimports + 1] = { k:sub(11, -3), s:sub(eq + 1) }
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
	self.tcwd = pwd ~= "" and pwd or nil
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
-- A compiled fragment (eval, a hot loop) can't see the whole program, so it can't know a
-- name is never a nameref / readonly / array: its native arith assign checks at run time.
-- ${#name} as an int64 (compiled arithmetic): a plain scalar's character count, else
-- the interpreter's expansion of it (arrays, namerefs, set -u).
function M.var_len(sh, name)
	local b = sh.vars[name]
	if b and not b.ref and not b.arr then
		local s = b.s
		if s == nil and b.n ~= nil then
			s = i64_to_str(b.n)
		end
		if s then
			return i64(M.mb_strlen(s))
		end
	end
	local w = require("parser").parse_word("${#" .. name .. "}")
	return i64(tonumber(require("interp")._int.expand_part_str(sh, w.parts[1])) or 0)
end
function M.plain_scalar(sh, name)
	local b = sh.vars[name]
	return b == nil or not (b.ref or b.ro or b.arr)
end
function Shell:aset(name, n)
	local dn = self:deref(name)
	local b = box(dn, self.vars)
	if b.ro then -- an arithmetic write to a readonly var is an arith error (bash): `((x=5))`/let
		-- fail with status 1, a `$((x++))` expansion discards the rest of the line
		io.stderr:write("curse: " .. dn .. ": readonly variable\n")
		error({ __curse_exit = 1, __curse_matherr = true, __curse_lineabort = true })
	end
	if b.ref then -- a number is never a nameref target (`declare -n r; ((r=0))`)
		M.bad_ref_target(i64_to_str(i64(n)), require("parser").arith_cmd)
		error({ __curse_exit = 1, __curse_matherr = true })
	end
	if dn == "OPTIND" and self.getopts_state then
		self.getopts_state[b] = nil
	end
	if b.arr then
		b.arr[b.assoc and "0" or 0] = i64_to_str(i64(n))
		if not b.assoc then
			M.arr_max_note(b.arr, 0)
		end
		return i64(n)
	end -- (( a = n )) hits a[0]
	b.n = i64(n)
	b.s = nil
	return b.n
end

-- ---- indexed arrays ----
-- Stored in the var box as b.arr = { [0]=…, [1]=… } (0-based, may be sparse, to
-- match bash). A plain scalar has no b.arr; reading $a is ${a[0]}.
-- The highest index, cached per array TABLE (a new table starts uncached): `a+=(x)` in
-- a loop scanned every key each time — quadratic. Writers in place keep it right:
-- array_set raises it, an element unset drops it, the others below update it.
local arr_max
do
local ARR_MAX = setmetatable({}, { __mode = "k" })
arr_max = function(arr)
	local m = ARR_MAX[arr]
	if m then
		return m
	end
	m = i64(-1)
	for k in pairs(arr) do
		local ki = key_i64(k)
		if ki > m then
			m = ki
		end
	end
	ARR_MAX[arr] = m
	return m
end
function M.arr_max_note(arr, key) -- (key was just set in arr)
	local m = ARR_MAX[arr]
	if m then
		local ki = key_i64(key)
		if ki > m then
			ARR_MAX[arr] = ki
		end
	end
end
function M.arr_max_drop(arr) -- (an element went: maybe the highest)
	ARR_MAX[arr] = nil
end
-- The key after indexed key K (number|string): int64 arithmetic past 2^53, wrapping at
-- INT64_MAX like bash's arrayind_t (`c[9223372036854775807]=m; c+=(w)` lands at the min)
function M.key_next(k)
	if type(k) == "number" and k < 99999999999999 then
		return k + 1
	end
	return to_arr_key(key_i64(k) + 1)
end
-- `a+=(…)`'s first index: one past the highest (a scalar becomes element [0] first)
function M.arr_next(sh, name)
	local b = sh.vars[name]
	if not b then
		return 0
	end
	if b.s ~= nil and not b.arr then
		b.arr = { [0] = b.s }
		b.s = nil
		b.n = nil
	end
	if not b.arr or next(b.arr) == nil then
		return 0
	end
	return M.key_next(to_arr_key(arr_max(b.arr)))
end
end

-- `declare -A name`: mark as associative (string keys, insertion-order iteration —
-- note: real bash iterates in hash order; insertion order matches the common cases).
function Shell:declare_assoc(name)
	local b = box(self:deref(name), self.vars)
	if not b.assoc and (b.s ~= nil or b.n ~= nil) then
		b.nbuckets = 128 -- (bash's convert_var_to_assoc: hash_create(0) = 128 buckets, not 1024)
	end
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
	if self:deref(name) == "FUNCNAME" then
		return -- (see set_str)
	end
	local b = box(self:deref(name), self.vars)
	if b.ref then -- a nameref with no target becomes the array itself (bash warns)
		io.stderr:write("curse: warning: " .. name .. ": removing nameref attribute\n")
		b.ref, b.s = nil, nil
	end
	if b.int then -- declare -i array: each element is evaluated arithmetically (bash)
		local ev = {}
		for i = 1, #values do
			ev[i] = M.i64_to_str(M.int_value(self, values[i]))
		end
		values = ev
	elseif b.lower or b.upper or b.cap then
		local ev = {}
		for i = 1, #values do
			ev[i] = case_fold(b, values[i])
		end
		values = ev
	end
	if append and b.arr then
		local base = arr_max(b.arr) + 1
		for i = 1, #values do
			local k = to_arr_key(base + i - 1)
			b.arr[k] = values[i]
			M.arr_max_note(b.arr, k)
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
	if type(key) == "number" then
		if key < 0 and not (b and b.assoc) then
			local mx = (b and b.arr) and arr_max(b.arr) or i64(-1) -- int64 highest index
			return to_arr_key(mx + 1 + key) -- resolve from end, then re-key (number|string)
		end
	elseif key:byte(1) == 45 and not (b and b.assoc) and not (b and b.arr and b.arr[key] ~= nil) then
		-- (a huge negative index: its string key — unless it names the element an auto index
		-- wrapped to at INT64_MIN)
		local mx = (b and b.arr) and arr_max(b.arr) or i64(-1)
		local r = mx + 1 + key_i64(key)
		return r < 0 and -1 or to_arr_key(r) -- (-1: still past the start — rejected)
	end
	return key
end
-- A negative subscript past the start of indexed array NAME (`c[-5]` with 2 elements)?
function M.neg_oob(sh, name, key)
	if type(key) == "number" then
		if key >= 0 then
			return false
		end
	elseif type(key) ~= "string" or key:byte(1) ~= 45 then -- (a huge negative index's string key)
		return false
	end
	local b = sh.vars[sh:deref(name)]
	if b and (b.assoc or (b.arr and b.arr[key] ~= nil)) then
		return false
	end
	local mx = (b and b.arr) and arr_max(b.arr) or ((b and (b.s or b.n)) and i64(0) or i64(-1))
	return mx + 1 + key_i64(key) < 0
end
-- ${a[-N]} past the start: bash warns (`a: bad array subscript`) and expands to nothing
-- (an empty associative key too: bash's get_array_value, `${E['']}`)
function M.elem_read_check(sh, name, key)
	if key == "" then
		local b = sh.vars[sh:deref(name)]
		if b and b.assoc then
			io.stderr:write("curse: " .. name .. ": bad array subscript\n")
		end
	elseif M.neg_oob(sh, name, key) then
		io.stderr:write("curse: " .. name .. ": bad array subscript\n")
	end
end
-- Does NAME hold a value (bash's !invisible_p: not `declare x` / `declare -A h` unassigned)?
function M.var_visible(sh, name)
	local b = sh.vars[sh:deref(name)]
	return b ~= nil and (b.arr ~= nil or b.s ~= nil or b.n ~= nil) and not (b.empty_decl and b.arr and next(b.arr) == nil)
end
-- ${#a[SUB]} of a visible array (subst.c array_length_reference): a negative index before
-- the start, or an empty associative key, is err_badarraysub on the subscript text and
-- its `]` — an expansion error that abandons the line
function M.len_badsub(sh, name, sub, key)
	if not M.var_visible(sh, name) then
		return
	end
	local b = sh.vars[sh:deref(name)]
	if (key == "" and b.assoc) or M.neg_oob(sh, name, key) then
		io.stderr:write("curse: " .. sub .. "]: bad array subscript\n")
		error({ __curse_exit = 1, __curse_lineabort = true })
	end
end
-- (`raw`: KEY is already an element's own key — an auto index that wrapped past INT64_MAX
-- is not a count back from the end)
function Shell:array_set(name, key, val, append, raw)
	if val:find("\0", 1, true) then
		val = M.cstr(val)
	end -- C-string element: cut at NUL
	if name == "DIRSTACK" and M.dirstack_dyn(self) then
		M.dirstack_set(self, key, val, append)
		return true
	end
	local b = box(self:deref(name), self.vars)
	if rawget(b, "virt") then -- BASH_ALIASES[k]=v / BASH_CMDS[k]=v: an alias / a hashed path
		key = tostring(key)
		if b.virt == "aliases" then
			self.aliases[key] = append and ((self.aliases[key] or "") .. val) or val
		else
			if not M.restricted_hash_ok(self, "", val) then
				return true -- (reported; nothing hashed)
			end
			self.hashcache = self.hashcache or {}
			M.hash_seq = M.hash_seq + 1
			self.hashcache[key] = { path = val, hits = 0, seq = M.hash_seq }
			self.hashpath = self:get("PATH")
		end
		return true
	end
	if not b.arr then
		b.arr = {}
		if b.s then
			b.arr[0] = b.s
		end
		b.s = nil
		b.n = nil
	end
	if not raw then
		key = norm_key(b, key)
	end
	if type(key) == "number" and key < 0 then
		return false
	end -- out-of-range negative: bash errors
	if b.assoc and b.arr[key] == nil then
		b.order[#b.order + 1] = key
	end
	b.empty_decl = nil -- (it has had an element: emptied later, it shows as `=()`)
	if b.int then -- declare -i array: elements are arithmetic (+= adds) — bash
		local v = M.int_value(self, val)
		if append then
			v = M.int_value(self, b.arr[key] or "0") + v
		end
		b.arr[key] = M.i64_to_str(v)
	elseif append then
		b.arr[key] = case_fold(b, (b.arr[key] or "") .. val)
	else
		b.arr[key] = case_fold(b, val)
	end
	if not b.assoc then
		M.arr_max_note(b.arr, key)
	end
	return key -- (the element's key: a negative index resolved)
end
-- FUNCNAME is a virtual array: the call stack innermost-first, then "main"
-- (empty at the top level). funcstack[1] is the innermost function.
-- A real function frame is on the call stack (`source` pushes a frame too, but bash's
-- FUNCNAME stays unset in a file sourced at the top level).
function Shell:in_function()
	local fs = self.funcstack
	if fs then
		for i = 1, #fs do
			if fs[i] ~= "source" then
				return true
			end
		end
	end
	return false
end
function Shell:funcname_array()
	local fs = self.funcstack
	if not fs or #fs == 0 or not self:in_function() then
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
	if self.opt_c then -- (-c: no script, so no bottom frame — bash)
		t[#t] = nil
	end
	return t
end
function Shell:bash_lineno_array()
	local t = {}
	local ls = self.linestack or {}
	for i = 1, #ls do
		t[i] = tostring(ls[i])
	end
	if not self.opt_c then
		t[#t + 1] = "0"
	end
	return t
end
-- DIRSTACK is bash's dynamic array while no variable of that name shadows it (a
-- `local DIRSTACK`) and it hasn't been unset (for good).
function M.dirstack_dyn(sh)
	return not sh.vars.DIRSTACK and not (sh.unset_specials and sh.unset_specials.DIRSTACK)
end
-- pushd.def's set_dirstack_element (DIRSTACK's assign_func): DIRSTACK[k] (k >= 1) rewrites
-- the k-th entry below the cwd; [0] and indices past the stack are ignored.
function M.dirstack_set(sh, key, val, append)
	local k = tonumber(key)
	local ds = sh.dirstack or {}
	local i = k and (#ds - k + 1)
	if i and k >= 1 and ds[i] then
		ds[i] = append and (ds[i] .. val) or val
		sh.dirstack = ds
	end
end
-- DIRSTACK: the directory stack, full paths, [0] always the current directory (bash)
function Shell:dirstack_array() -- (sh.dirstack: the entries below the cwd, bottom first)
	local ds = self.dirstack or {}
	local t = { self:cwd() }
	for k = #ds, 1, -1 do
		t[#t + 1] = ds[k]
	end
	return t
end
-- BASH_ARGV / BASH_ARGC (bash maintains them only under extdebug): every frame's
-- positional parameters, innermost frame first and each frame's own args reversed; and
-- each frame's count.
function Shell:frame_params()
	local fr = { { self.params, self.nparams } }
	for d = self.pd, 1, -1 do
		fr[#fr + 1] = { self.paramstack[d], self.npstack[d] }
	end
	return fr
end
function Shell:bash_argv_array()
	local t = {}
	if self.shopt.extdebug then
		for _, f in ipairs(self:frame_params()) do
			for k = f[2] or 0, 1, -1 do
				t[#t + 1] = f[1][k] or ""
			end
		end
	end
	return t
end
function Shell:bash_argc_array()
	local t = {}
	if self.shopt.extdebug then
		for _, f in ipairs(self:frame_params()) do
			t[#t + 1] = tostring(f[2] or 0)
		end
	end
	return t
end
-- GROUPS: the process's groups as bash's initialize_group_array orders them (getgroups,
-- with the primary gid swapped into slot 0, or put there if missing)
pcall(ffi.cdef, "int getgroups(int size, unsigned int *list); unsigned int getgid(void);")
local groups_cache
function Shell:groups_array()
	if not groups_cache then
		local t = {}
		pcall(function()
			local n = C.getgroups(0, nil)
			local buf = ffi.new("unsigned int[?]", math.max(n, 1))
			n = C.getgroups(n, buf)
			for k = 0, n - 1 do
				t[#t + 1] = tonumber(buf[k])
			end
			local gid = tonumber(C.getgid())
			local at
			for k, g in ipairs(t) do
				if g == gid then
					at = k
					break
				end
			end
			if not at then
				table.insert(t, 1, gid)
			elseif at ~= 1 then
				t[at], t[1] = t[1], gid
			end
		end)
		for k, g in ipairs(t) do
			t[k] = tostring(g)
		end
		groups_cache = t
	end
	return groups_cache
end
local VIRT_ARR = {
	GROUPS = "groups_array",
	BASH_ARGV = "bash_argv_array",
	BASH_ARGC = "bash_argc_array",
	FUNCNAME = "funcname_array",
	BASH_SOURCE = "bash_source_array",
	BASH_LINENO = "bash_lineno_array",
	DIRSTACK = "dirstack_array",
}
function Shell:array_get(name, key)
	if VIRT_ARR[name] and (name ~= "DIRSTACK" or M.dirstack_dyn(self)) then
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
-- Sorted variable names beginning with `pfx` (for ${!pfx@} / ${!pfx*}). Only VISIBLE
-- ones (all_visible_variables): a declared-but-valueless var (`declare v`, `declare -a
-- a`) is skipped; an assigned empty array (`a=()`) is not.
function Shell:var_prefix_names(pfx)
	local t = {}
	for k, b in pairs(self.vars) do
		if
			k:sub(1, #pfx) == pfx
			and not (b.s == nil and b.n == nil and b.arr == nil)
			and not (b.empty_decl and b.arr and next(b.arr) == nil)
		then
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
	if b and rawget(b, "virt") then -- (unset BASH_ALIASES[k]: drop the alias / hash entry)
		local src = b.virt == "aliases" and self.aliases or self.hashcache
		if src then
			src[tostring(key)] = nil
		end
		return true
	end
	if not (b and b.arr) then
		return true
	end
	local k = norm_key(b, key)
	if type(k) == "number" and k < 0 then
		return false
	end
	if b.assoc and b.arr[k] ~= nil and b.order then -- (and out of the insertion order: a
		for i = #b.order, 1, -1 do -- re-set key is new, not listed twice)
			if b.order[i] == k then
				table.remove(b.order, i)
				break
			end
		end
	end
	b.arr[k] = nil
	M.arr_max_drop(b.arr) -- (maybe the highest: recount on demand)
	return true
end
-- bash iterates an assoc array in HASH-TABLE order, not insertion order: the
-- key's FNV-1 32-bit hash (over its bytes) picks one of 1024 buckets, buckets are
-- walked ascending, and within a bucket the most-recently-inserted key comes
-- first (bash prepends to the chain). Reproduced exactly so ${!m[@]} / ${m[@]}
-- match bash. int64 keeps the 32-bit multiply
-- exact (a plain Lua double would lose precision past 2^53).
local FNV32_OFFSET, FNV32_PRIME, U32 = i64(2166136261), i64(16777619), i64(4294967296)
local function assoc_bucket(key, nb)
	local h = FNV32_OFFSET
	for j = 1, #key do
		h = (h * FNV32_PRIME) % U32 -- FNV-1: multiply first…
		h = bit.bxor(h, i64(key:byte(j))) -- …then xor the byte
	end
	return tonumber(h % i64(nb or 1024))
end
M.assoc_bucket = assoc_bucket
-- $SHLVL: a new shell raises it (bash's adjust_shell_level at startup: a non-number is 0,
-- below 0 is 0, 1000 and up warns and resets to 1), exported.
M.shlvl_delta = 0
M.env_drop_us = false
function M.shlvl_start(sh)
	local b = sh.vars.SHLVL
	local v = b and sh:get("SHLVL") or ""
	local n = v:match("^%s*[+-]?%d+%s*$") and tonumber(v) or 0
	n = n + 1
	if n < 0 then
		n = 0
	elseif n >= 1000 then
		io.stderr:write(("curse: warning: shell level (%d) too high, resetting to 1\n"):format(n))
		n = 1
	end
	sh:set_str("SHLVL", tostring(n))
	local nb = sh.vars.SHLVL
	if nb and not nb.exported then
		nb.exported = true
	end
	C.setenv("SHLVL", tostring(n), 1)
end
-- A child's environment in bash's order: bash builds it by walking its variable hash
-- table — the same FNV-1 / 1024-bucket order, the newest variable first within a
-- bucket — and appends `_` last. The process environ is (re)ordered that way at each
-- spawn: its entries in bucket order, a later (newer) entry first within a bucket.
do
	local bucket_of = setmetatable({}, { __mode = "k" }) -- name -> bucket (names recur)
	local nbuckets_cache = 0
	function M.child_env()
		local env = C.environ
		local items, n = {}, 0
		if env == nil then -- (cleared: `exec -c`)
			local empty = ffi.new("char *[1]")
			return empty
		end
		local nous = M.env_drop_us -- (`exec cmd`: no `_` — only a forked command gets one)
		local j = 0
		while env[j] ~= nil do
			local s = ffi.string(env[j])
			local name = s:match("^[^=]*")
			j = j + 1
			if nous and name == "_" then
				goto continue
			end
			local b = bucket_of[name]
			if not b then
				b = assoc_bucket(name, 1024)
				if nbuckets_cache > 4096 then
					bucket_of, nbuckets_cache = {}, 0
				end
				bucket_of[name], nbuckets_cache = b, nbuckets_cache + 1
			end
			items[n + 1] = { p = env[j - 1], b = name == "_" and 1e9 or b, i = n }
			n = n + 1
			::continue::
		end
		local d = M.shlvl_delta
		if d ~= 0 then -- (the command REPLACES this shell — `exec cmd`: bash lowers SHLVL first)
			for k = 1, n do
				local s = ffi.string(items[k].p)
				if s:sub(1, 6) == "SHLVL=" then
					local lv = (tonumber(s:sub(7)) or 0) + d
					M._shlvl_anchor = "SHLVL=" .. tostring(lv < 0 and 0 or lv)
					items[k].p = ffi.cast("char *", M._shlvl_anchor)
				end
			end
		end
		table.sort(items, function(x, y)
			if x.b ~= y.b then
				return x.b < y.b
			end
			return x.i > y.i
		end)
		local arr = ffi.new("char *[?]", n + 1)
		for k = 1, n do
			arr[k - 1] = items[k].p
		end
		arr[n] = nil
		return arr
	end
end

function Shell:array_indices(name)
	if VIRT_ARR[name] and (name ~= "DIRSTACK" or M.dirstack_dyn(self)) then
		local a = self[VIRT_ARR[name]](self)
		local t = {}
		for i = 1, #a do
			t[i] = i - 1
		end
		return t
	end
	local b = self.vars[self:deref(name)]
	if b and b.assoc then
		return M.assoc_keys(b)
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
-- BASH_ALIASES / BASH_CMDS: bash's dynamic assoc views of the alias table and the command
-- hash table. The box computes `arr`/`order` from them on every access (so it never goes
-- stale, in a subshell too), iterating in their own tables' bucket order (64 / 256).
M.hash_seq = 0
local VIRT_ASSOC_MT = {
	__index = function(b, k)
		if k ~= "arr" and k ~= "order" then
			return nil
		end
		local sh, arr, keys = b.vsh, {}, {}
		if b.virt == "aliases" then
			for name, v in pairs(sh.aliases or {}) do
				arr[name], keys[#keys + 1] = v, name
			end
			table.sort(keys)
		else
			local hc = sh.hashcache or {}
			for name, e in pairs(hc) do
				arr[name], keys[#keys + 1] = e.path, name
			end
			table.sort(keys, function(a, z)
				local sa, sz = hc[a].seq or 0, hc[z].seq or 0
				if sa ~= sz then
					return sa < sz
				end
				return a < z
			end)
		end
		return k == "arr" and arr or keys
	end,
}
function M.virt_assoc(sh, which)
	return setmetatable({ assoc = true, virt = which, vsh = sh, nbuckets = which == "aliases" and 64 or 256 }, VIRT_ASSOC_MT)
end
-- an assoc box's keys in bash's hash-table order (see assoc_bucket)
function M.assoc_keys(b)
	do
		local live = {}
		for idx, k in ipairs(b.order) do
			if b.arr[k] ~= nil then
				live[#live + 1] = { k = k, i = idx, bkt = assoc_bucket(k, b.nbuckets) }
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
end
function Shell:array_values(name)
	if VIRT_ARR[name] and (name ~= "DIRSTACK" or M.dirstack_dyn(self)) then
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
-- ${#a[@]} / ${#a[*]}: the count; under set -u a variable that is unset, never assigned
-- (`declare -a b`) or not an array (`s=x`) is unbound (array_length_reference), `a=()` is 0
function M.array_count_u(sh, name, shown)
	local c = sh:array_count(name)
	if sh.opt_u and name ~= "BASH_ARGV" and name ~= "BASH_ARGC" then -- (always arrays in bash)
		local b = sh.vars[sh:deref(name)]
		if (b == nil and c == 0 and sh:special_get(name) == "") -- (nil but counted: a virtual array)
			or (b and (not b.arr or (b.empty_decl and next(b.arr) == nil))) then
			io.stderr:write("curse: " .. (shown or name) .. ": unbound variable\n")
			error({ __curse_exit = sh.opt_c and 127 or 1, __curse_lineabort = sh.opt_i or nil })
		end
	end
	return c
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
	local rb = M.re_get(M.glob_to_ere(glob), 1 + 8) -- REG_EXTENDED|REG_NOSUB
	if not rb then
		return val
	end
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
	return res
end
-- bash matches a pattern BYTE-wise when the string or the pattern isn't valid in the
-- multibyte locale (xstrmatch's fallback): `case $euro in *$'\202'*)` matches a byte of it.
function M.mb_invalid(s)
	if lc_mb_cur_max <= 1 or not s:find("[\128-\255]") then
		return false
	end
	for _, ch in ipairs(M.mb_chars(s)) do
		if not ch.wc then
			return true
		end
	end
	return false
end
function M.bytewise(fn, ...)
	local cur = C.setlocale(0, nil)
	local saved = cur ~= nil and ffi.string(cur) or "C"
	C.setlocale(0, "C")
	local smb = lc_mb_cur_max
	lc_mb_cur_max = 1
	re_locale_changed()
	local ok, a, b = pcall(fn, ...)
	C.setlocale(0, saved)
	lc_mb_cur_max = smb
	re_locale_changed()
	if not ok then
		error(a, 0)
	end
	return a, b
end
local strip_prefix, strip_suffix
function strip_prefix(val, glob, longest)
	if lc_mb_cur_max > 1 and (M.mb_invalid(val) or M.mb_invalid(glob)) then
		return M.bytewise(strip_prefix, val, glob, longest)
	end
	local r, ok = fast_strip(val, glob, true, longest)
	if ok then
		return r
	end
	return strip_regex(val, glob, true, longest)
end
function strip_suffix(val, glob, longest)
	if lc_mb_cur_max > 1 and (M.mb_invalid(val) or M.mb_invalid(glob)) then
		return M.bytewise(strip_suffix, val, glob, longest)
	end
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
	if lc_mb_cur_max <= 1 or not val:find("[\128-\255]") then -- (bytes are chars: ASCII)
		local n = #val
		local o = tonumber(off) or 0
		if o < 0 then
			o = n + o
		end
		if o < 0 or o > n then
			return "" -- (an offset before the start or past the end: bash yields nothing;
		end -- an int64-sized one must not reach string.sub, which wraps it)
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
	if o < 0 or o > n then
		return ""
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
-- Compiled-regex cache: a `case`/[[ ]]/glob pattern in a loop would otherwise
-- regcomp+regfree per test. regcomp bakes in LC_CTYPE/LC_COLLATE, so the cache is
-- keyed by the locale (re_lockey, set by reset_locale/bytewise) and dropped when it
-- changes. Entries are GC-owned (ffi.gc regfree); `false` caches a failed compile.
local re_cache, re_n = {}, 0
local function re_get(ere, flags)
	local key = flags .. ":" .. ere
	local rb = re_cache[key]
	if rb == nil then
		rb = ffi.new("char[512]") -- opaque regex_t (glibc ~64B; over-allocate)
		if ffi.C.regcomp(rb, ere, flags) ~= 0 then
			rb = false
		else
			rb = ffi.gc(rb, ffi.C.regfree)
		end
		if re_n >= 512 then
			re_cache, re_n = {}, 0
		end
		re_cache[key], re_n = rb, re_n + 1
	end
	return rb
end
M.re_get = re_get
re_locale_changed = function()
	re_cache, re_n = {}, 0
end

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
-- POSIX portable-character-set names for collating symbols `[.name.]` (bash collsyms.h)
local COLLSYM = {
	NUL = "\0", tab = "\t", newline = "\n", ["vertical-tab"] = "\v", ["form-feed"] = "\f",
	["carriage-return"] = "\r", space = " ", ["exclamation-mark"] = "!", ["quotation-mark"] = '"',
	["number-sign"] = "#", ["dollar-sign"] = "$", ["percent-sign"] = "%", ampersand = "&",
	apostrophe = "'", ["left-parenthesis"] = "(", ["right-parenthesis"] = ")", asterisk = "*",
	["plus-sign"] = "+", comma = ",", hyphen = "-", ["hyphen-minus"] = "-", period = ".",
	["full-stop"] = ".", slash = "/", solidus = "/", zero = "0", one = "1", two = "2", three = "3",
	four = "4", five = "5", six = "6", seven = "7", eight = "8", nine = "9", colon = ":",
	semicolon = ";", ["less-than-sign"] = "<", ["equals-sign"] = "=", ["greater-than-sign"] = ">",
	["question-mark"] = "?", ["commercial-at"] = "@", ["left-square-bracket"] = "[",
	backslash = "\\", ["reverse-solidus"] = "\\", ["right-square-bracket"] = "]",
	circumflex = "^", ["circumflex-accent"] = "^", underscore = "_", ["low-line"] = "_",
	["grave-accent"] = "`", ["left-brace"] = "{", ["left-curly-bracket"] = "{",
	["vertical-line"] = "|", ["right-brace"] = "}", ["right-curly-bracket"] = "}", tilde = "~",
}
-- The index of the `]` closing the bracket expression whose `[` is at p[i] — a leading
-- `!`/`^` and a first `]` are members; [:class:] / [.coll.] / [=equiv=] are skipped
-- whole; nil when it never closes.
local function bracket_end(p, i)
	local j, n = i + 1, #p
	if p:sub(j, j) == "!" or p:sub(j, j) == "^" then
		j = j + 1
	end
	if p:sub(j, j) == "]" then
		j = j + 1
	end
	while j <= n do
		local c = p:sub(j, j)
		if c == "]" then
			return j
		end
		local nx = p:sub(j + 1, j + 1)
		local e = c == "[" and (nx == ":" or nx == "." or nx == "=") and p:find(nx .. "]", j + 2, true)
		if e then
			j = e + 2
		elseif c == "\\" then
			j = j + 2
		else
			j = j + 1
		end
	end
	return nil
end
M.bracket_end = bracket_end
local POSIX_CLASS = {}
for c in ("alnum alpha blank cntrl digit graph lower print punct space upper xdigit"):gmatch("%a+") do
	POSIX_CLASS[c] = true
end
local function glob_conv(glob, pn, patsub)
	local star = pn and "[^/]*" or ".*"
	local qmark = pn and "[^/]" or "."
	local out, i, n = {}, 1, #glob
	while i <= n do
		local c = glob:sub(i, i)
		-- an extglob group must CLOSE: an unterminated `*([` is just `*` + literal `([` (bash)
		local d, j = 1, i + 2
		if EXTOP[c] and glob:sub(i + 1, i + 1) == "(" then
			while j <= n and d > 0 do
				local cc = glob:sub(j, j)
				if cc == "\\" then
					j = j + 1 -- (an escaped char)
				elseif cc == "[" then -- a bracket expression: its `)` doesn't close the group
					local close = bracket_end(glob, j)
					if not close then
						d = -1 -- an unclosed `[` swallows the rest: the group never closes (bash)
						break
					end
					j = close
				elseif cc == "(" then
					d = d + 1
				elseif cc == ")" then
					d = d - 1
					if d == 0 then
						break
					end
				end
				j = j + 1
			end
		end
		if EXTOP[c] and glob:sub(i + 1, i + 1) == "(" and d == 0 then
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
			local never = false -- an invalid collating symbol started a range: matches nothing
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
					elseif cj == "[" and nx == "." and glob:find(".]", j + 2, true) then
						-- [.name.] collating symbol: a single char, or a POSIX character name;
						-- an unknown multi-char name matches nothing — as a range START it
						-- invalidates the whole bracket, as a range END it drops that range
						local e = glob:find(".]", j + 2, true)
						local name = glob:sub(j + 2, e - 1)
						local ch = (#name == 1) and name or COLLSYM[name]
						j = e + 2
						if ch then
							members[#members + 1] = "[." .. ch .. ".]"
						elseif glob:sub(j, j) == "-" and glob:sub(j + 1, j + 1) ~= "]" then
							-- invalid range START: drop the range (skip `-` and its end)
							j = j + 1
							local ee = glob:sub(j, j + 1) == "[." and glob:find(".]", j + 2, true)
							j = ee and (ee + 2) or (j + 1)
						elseif members[#members] == "-" and #members >= 2 then
							members[#members] = nil -- the `-`
							members[#members] = nil -- the range start
						end
					elseif cj == "[" and (nx == ":" or nx == "." or nx == "=") then
						-- POSIX [:class:] / [.coll.] / [=equiv=]: copy through its own close
						local e = glob:find(nx .. "]", j + 2, true)
						if e then
							local cls = glob:sub(j, e + 1)
							if nx == ":" then
								local cname = glob:sub(j + 2, e - 1)
								if cname == "ascii" then -- (bash's; not a regcomp class: its range)
									members[#members + 1] = "\1-\127"
								elseif cname == "word" then -- (bash's: alnum + _)
									members[#members + 1] = "[:alnum:]_"
								elseif POSIX_CLASS[cname] then
									members[#members + 1] = cls
								end -- an unknown class name matches nothing; the rest still match
							else
								members[#members + 1] = cls
							end
							j = e + 2
						else -- an unterminated `[:`: the `[` drops out, the rest are members
							-- (bash: `[[:alpha]` matches h, not [ — and a kept `[:` would make
							-- regcomp reject the whole class)
							j = j + 1
						end
					elseif nx == "-" and glob:sub(j + 2, j + 2) ~= "]" and glob:sub(j + 2, j + 2) ~= ""
						and glob:sub(j + 2, j + 3) ~= "[." and glob:sub(j + 2, j + 2):byte() < cj:byte()
					then
						j = j + 3 -- a reversed range (`a-Z`) matches nothing: drop it (regcomp rejects it)
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
					if never or (#members == 0 and not has_rb) then
						out[#out + 1] = "[^\1-\255]" -- matches nothing (no NUL in a shell string)
					else
						out[#out + 1] = "[" .. (neg and "^" or "") .. (has_rb and "]" or "") .. table.concat(members) .. "]"
					end
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
	local rb = re_get(ere, REG_EXTENDED + REG_NOSUB + (icase and REG_ICASE or 0))
	return rb and ffi.C.regexec(rb, s, 0, nil, 0) == 0 or false
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
-- `fl` (glob only): { period = true } — a leading `.` matches only explicitly (FNM_PERIOD,
-- dotglob off); { dotdot = true } — `.`/`..` only explicitly (FNM_DOTDOT). Both apply at
-- the START of `str` only, as in bash's sm_loop.
function M.ext_match(str, pat, icase, fl)
	local plen, slen = #pat, #str
	local lead_dot = fl and str:sub(1, 1) == "."
	local is_dd = fl and fl.dotdot and (str == "." or str == "..")
	local ceq = icase and function(a, b)
		return a:lower() == b:lower()
	end or function(a, b)
		return a == b
	end
	-- index of the `)` closing an extglob group whose op is at `gi` (`(` at gi+1)
	local function group_end(gi) -- (nil: the group never closes — then it's literal text)
		local d, j = 1, gi + 2
		while j <= plen do
			local cc = pat:sub(j, j)
			if cc == "\\" then
				j = j + 2
			elseif cc == "[" then -- a bracket expression: its `)` doesn't close the group
				local close = bracket_end(pat, j)
				if not close then
					return nil -- an unclosed `[` swallows the rest (bash)
				end
				j = close + 1
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
		local ge = EXTOP[c] and nc == "(" and group_end(pi)
		local atstart = si == 1 and fl -- (flags matter only at the string's start)
		if ge and ge <= plen then
			local alts = split_alts(pat:sub(pi + 2, ge - 1))
			local rest = ge + 1
			local function altfull(seg, from)
				for _, a in ipairs(alts) do
					if M.ext_match(seg, a, icase, from == 1 and fl or nil) then
						return true
					end
				end
				return false
			end
			if c == "@" then
				for j = si - 1, slen do
					if altfull(str:sub(si, j), si) and m(j + 1, rest) then
						return true
					end
				end
			elseif c == "?" then
				if m(si, rest) then
					return true
				end
				for j = si, slen do
					if altfull(str:sub(si, j), si) and m(j + 1, rest) then
						return true
					end
				end
			elseif c == "!" then
				for j = si - 1, slen do
					if not altfull(str:sub(si, j), si) then
						-- no arm matched, yet a leading dot still needs explicit matching
						if atstart and ((fl.period and lead_dot) or is_dd) then
							return false
						end
						if m(j + 1, rest) then
							return true
						end
					end
				end
			else -- `*` (zero or more) or `+` (one or more)
				local function rep(pos, count)
					if (c == "*" or count >= 1) and m(pos, rest) then
						return true
					end
					for j = pos, slen do
						if altfull(str:sub(pos, j), pos) and rep(j + 1, count + 1) then
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
		elseif atstart and (c == "*" or c == "?" or c == "[") and ((fl.period and lead_dot) or is_dd) then
			return false -- `*`/`?`/`[…]` can't match a leading `.` (FNM_PERIOD / FNM_DOTDOT)
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
			local j = bracket_end(pat, pi)
			if not j then -- unclosed `[` is a literal `[`
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
	local rb = re_get(ere, REG_EXTENDED + (icase and REG_ICASE or 0))
	if not rb then
		return nil, true
	end
	local rc = ffi.C.regexec(rb, s, NMATCH, pmatch, 0)
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
	if lc_mb_cur_max > 1 and (M.mb_invalid(s) or M.mb_invalid(glob)) then
		return M.bytewise(M.glob_match, s, glob, icase)
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
-- shopt patsub_replacement (bash's strcreplace(rep, '&', m, 2)): in the replacement `&` is
-- the matched text, `\&` a literal `&`, `\\` a literal `\`. The caller's replacement is
-- quote-marked: a QUOTED `&`/`\` arrives backslash-escaped (quote_string_for_repl).
local function repl_amp(rep, m)
	return (rep:gsub("\\?[&\\]", function(t)
		if t == "&" then
			return m
		elseif #t == 2 then
			return t:sub(2)
		end
	end))
end
-- does the replacement use `&` at all (bash's shouldexp_replacement)?
function M.repl_expands(rep)
	return rep:find("&", 1, true) ~= nil or rep:find("\\\\") ~= nil
end
-- With extglob off an `X(` is plain text in a pattern (strmatch without FNM_EXTMATCH):
-- escape the paren so the converters don't read an extglob group.
function M.glob_noext(glob)
	return (glob:gsub("([?*+@!])%(", "%1\\("))
end
-- ${v/pat/rep} with a `!(…)` pattern, which the ERE conversion can only approximate:
-- bash's match_upattern by brute force over whole-substring matches (MATCH_ANY takes
-- the leftmost start and the longest end there; MATCH_BEG the longest prefix; MATCH_END
-- the leftmost suffix), looped as pat_subst does.
function M.subst_ext(val, glob, repl, all, anchor, icase, rx)
	local n = #val
	local function find(from)
		if anchor == "^" then
			if from > 1 then
				return nil
			end
			for e = n, 0, -1 do
				if M.ext_match(val:sub(1, e), glob, icase) then
					return 1, e
				end
			end
		elseif anchor == "$" then
			for b = from, n + 1 do
				if M.ext_match(val:sub(b), glob, icase) then
					return b, n
				end
			end
		else
			for b = from, n + 1 do
				for e = n, b - 1, -1 do
					if M.ext_match(val:sub(b, e), glob, icase) then
						return b, e
					end
				end
			end
		end
	end
	local out, pos = {}, 1
	repeat -- (pat_subst: `while (*str)`, but an empty string still gets one try)
		local b, e = find(pos)
		if not b then
			break
		end
		out[#out + 1] = val:sub(pos, b - 1)
		out[#out + 1] = rx and repl_amp(repl, val:sub(b, e)) or repl
		pos = e + 1
		if not all or anchor then
			break
		end
		if e < b then -- empty match: copy one char
			out[#out + 1] = val:sub(pos, pos)
			pos = pos + 1
		end
	until pos > n
	out[#out + 1] = val:sub(pos)
	return table.concat(out)
end
function M.subst_glob(val, glob, repl, all, icase, rx)
	local anchor -- (only `${x/#p/r}`/`${x/%p/r}` anchor: after `//` a `#`/`%` is literal)
	local c1 = not all and glob:sub(1, 1)
	if c1 == "#" then
		glob = glob:sub(2)
		anchor = "^"
	elseif c1 == "%" then
		glob = glob:sub(2)
		anchor = "$"
	end
	if glob == "" then -- empty pattern: no-op, except an anchored one inserts repl
		if rx then
			repl = repl_amp(repl, "")
		end
		if anchor == "^" then
			return repl .. val
		elseif anchor == "$" then
			return val .. repl
		end
		return val
	end
	-- Literal pattern (no glob metachars): plain byte find/replace, no regex — the
	-- common `${x//-/_}` / `${x//,/ }` case (regex is left for real globs).
	if not icase and not glob:find("[%*%?%[\\]") and not glob:find("[@!+?*]%(") then
		local plen = #glob
		if rx then -- (every match is the literal pattern itself)
			repl = repl_amp(repl, glob)
		end
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
	if val == "" and anchor ~= "$" and glob:byte(1) ~= 42 then
		return val -- (match_pattern_char: at the end of the string only a `*…` pattern
	end -- may match, so an empty value takes ${y/?(a)/Z} as no match; `/%` skips that test)
	if glob:find("!(", 1, true) then
		return M.subst_ext(val, glob, repl, all, anchor, icase, rx)
	end
	local ere = glob_conv(glob, false, true) -- patsub=true: [^]/[!] empty-negated quirk
	if anchor == "^" then
		ere = "^(" .. ere .. ")"
	elseif anchor == "$" then
		ere = "(" .. ere .. ")$"
	else
		ere = "(" .. ere .. ")"
	end
	local rb = re_get(ere, REG_EXTENDED + (icase and REG_ICASE or 0))
	if not rb then
		return val
	end
	-- pat_subst's loop runs `while (*str)`: matching stops at the END of the value (no
	-- trailing empty match: `${x//*(z)/Y}` on abc is YaYbYc), yet right after a non-empty
	-- match an empty one is still tried (`${x//?(b)/-}` is -a--c). An empty value gets
	-- its one try (`${x//*/Y}` on "" is Y).
	local out, pos, n = {}, 0, #val
	repeat
		local sub = val:sub(pos + 1)
		if ffi.C.regexec(rb, sub, 1, pmatch, pos > 0 and REG_NOTBOL or 0) ~= 0 then
			break
		end
		local so, eo = pmatch[0].rm_so, pmatch[0].rm_eo
		out[#out + 1] = sub:sub(1, so) -- text before the match
		out[#out + 1] = rx and repl_amp(repl, sub:sub(so + 1, eo)) or repl
		if eo > so then
			pos = pos + eo
		else
			out[#out + 1] = sub:sub(eo + 1, eo + 1)
			pos = pos + eo + 1
		end -- empty match: keep one char
		if not all or anchor then
			out[#out + 1] = val:sub(pos + 1)
			return table.concat(out)
		end
	until pos >= n
	out[#out + 1] = val:sub(pos + 1)
	return table.concat(out)
end

-- Scan one directory for entries matching a single glob segment. `dir` is the
-- directory to open ("" == cwd). Returns a list of matching base names (unsorted).
-- `dotglob` controls whether names beginning with `.` match a non-`.`-initial glob.
-- bash's glob_patscan: from `i`, the index just past the `)` closing the current group (or,
-- with delim `|`, past the next top-level `|`), bracket/escape aware; nil if unterminated.
local function patscan(p, i, delim)
	local pnest, bnest, skip, cchar, bfirst = 0, 0, false, nil, nil
	local n = #p
	if i > n then
		return nil
	end
	for k = i, n do
		local c = p:sub(k, k)
		if skip then
			skip = false
		elseif c == "\\" then
			skip = true
		elseif c == "[" then
			if bnest == 0 then
				bfirst = k + 1
				local f = p:sub(bfirst, bfirst)
				if f == "!" or f == "^" then
					bfirst = bfirst + 1
				end
				bnest = bnest + 1
			elseif p:sub(k + 1, k + 1):match("^[:.=]$") then
				cchar = p:sub(k + 1, k + 1)
			end
		elseif c == "]" then
			if bnest > 0 then
				if cchar and p:sub(k - 1, k - 1) == cchar then
					cchar = nil
				elseif k ~= bfirst then
					bnest = bnest - 1
					bfirst = nil
				end
			end
		elseif c == "(" then
			if bnest == 0 then
				pnest = pnest + 1
			end
		elseif c == ")" then
			if bnest == 0 then
				if pnest <= 0 then
					return k + 1
				end
				pnest = pnest - 1
			end
		elseif c == "|" then
			if bnest == 0 and pnest == 0 and delim == "|" then
				return k + 1
			end
		end
	end
	return nil
end
-- bash's skipname / extglob_skipname (lib/glob/glob.c): should directory entry `dname` be
-- skipped outright for pattern `pat`? (Mostly: does a leading `.` get matched explicitly.)
local skipname
local function extglob_skipname(pat, dname, dotglob, skipdots)
	local wild = pat:sub(1, 1) == "*" or pat:sub(1, 1) == "?"
	local pp, se = 3, #pat + 1
	local pe = patscan(pat, pp, nil)
	if not pe then
		return false
	end
	if pe == se and pat:sub(pe - 1, pe - 1) == ")" and not pat:find("|", pp, true) then
		return skipname(pat:sub(pp, pe - 2), dname, dotglob, skipdots)
	end
	local r
	while true do
		local t = patscan(pat, pp, "|")
		if not t or t > pe then
			break
		end
		local sub = pat:sub(pp, t - 2)
		if pat:sub(t - 1, t - 1) == ")" and pat:sub(pp):match("^[?*+@!]%(") then
			sub = pat:sub(pp) -- (a nested extglob arm: bash leaves it unterminated)
		end
		r = skipname(sub, dname, dotglob, skipdots)
		if not r then
			return false
		end
		pp = t
		if pp == pe then
			break
		end
	end
	if pp == se then
		return r
	end
	if wild and pe <= #pat then -- can match zero instances: the rest decides
		return skipname(pat:sub(pe), dname, dotglob, skipdots)
	end
	return true
end
skipname = function(pat, dname, dotglob, skipdots)
	if pat:match("^[?*+@!]%(") then
		return extglob_skipname(pat, dname, dotglob, skipdots)
	end
	local dd = dname == "." or dname == ".."
	if skipdots and dd then
		return true
	end
	local pdot = pat:sub(1, 1) == "." or pat:sub(1, 2) == "\\."
	if dotglob and not pdot and dd then
		return true
	elseif not dotglob and dname:sub(1, 1) == "." and not pdot then
		return true
	end
	return false
end
local glob_icase = false -- (shopt -s nocaseglob, for the glob_expand in progress)
local function scan_seg(dir, seg, dotglob, skipdots)
	local scan = (dir == "" and ".") or dir
	local d = ffi.C.opendir(scan)
	if d == nil then
		return {}
	end
	-- a `!()` segment needs the split matcher (per entry); everything else uses one
	-- precompiled ERE.
	local neg = seg:find("!(", 1, true) ~= nil
	local rb
	if not neg then
		rb = re_get(glob_to_ere(seg), REG_EXTENDED + REG_NOSUB + (glob_icase and REG_ICASE or 0))
		if not rb then
			ffi.C.closedir(d)
			return {}
		end
	end
	local hidden = seg:sub(1, 1) == "."
	skipdots = skipdots ~= false -- default: skip . and .. (globskipdots on)
	-- an extglob segment matches like bash's glob_vector: skipname, then strmatch with
	-- FNM_PERIOD (dotglob off) or FNM_DOTDOT (on)
	local xseg = seg:find("[?*+@!]%(") ~= nil
	local xfl = xseg and (dotglob and { dotdot = true } or { period = true })
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
		if xseg then
			if not skipname(seg, name, dotglob, skipdots) and M.ext_match(name, seg, glob_icase, xfl) then
				out[#out + 1] = name
			end
		elseif (not dotdot or (not skipdots and hidden)) and (name:sub(1, 1) ~= "." or hidden or dotglob) then
			local m
			if neg then
				m = M.ext_match(name, seg, glob_icase) -- (explicit if: a false ext_match must NOT fall to regexec on an uncompiled regbuf)
			else
				m = ffi.C.regexec(rb, name, 0, nil, 0) == 0
			end
			if m then
				out[#out + 1] = name
			end
		end
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
-- `time [-p] pipeline` (compiled tier): push the start clocks, run, then report elapsed
-- real/user/sys to stderr in bash's format (same as interp's exec_stmt `timed` branch).
ffi.cdef("struct curse_rt_timeval { long tv_sec; long tv_usec; };"
	.. "int curse_rt_gettimeofday(struct curse_rt_timeval *tv, void *tz) asm(\"gettimeofday\");")
local _tv = ffi.new("struct curse_rt_timeval")
local function wall_secs()
	C.curse_rt_gettimeofday(_tv, nil)
	return tonumber(_tv.tv_sec) + tonumber(_tv.tv_usec) * 1e-6
end
M.wall_secs = wall_secs
-- `read -t`: wait until `fd` is readable (data, EOF or error) or the wall-clock
-- `deadline` passes; false on timeout. Inside a pipeline stage it yields on the
-- scheduler's 10ms tick instead of stalling its siblings.
ffi.cdef("struct curse_rt_timespec { long tv_sec; long tv_nsec; };"
	.. "int curse_rt_ppoll(void *fds, unsigned long nfds, const struct curse_rt_timespec *ts, const void *mask) asm(\"ppoll\");")
local _ppoll_ts = ffi.new("struct curse_rt_timespec")
function M.fd_wait(fd, deadline)
	local t = co_task()
	while fd_would_block(fd, POLLIN) do
		local left = deadline - wall_secs()
		if left <= 0 then
			return false
		end
		if t then
			pre_yield(t)
			if coroutine.yield(-1, 0) == SIGMARK then
				task_signals(t)
			end
		elseif sched_live() then -- (background jobs run while the shell waits)
			M.sched_pump({ fd = fd, ev = POLLIN, deadline = deadline })
		else
			_co_pfd[0].fd, _co_pfd[0].events, _co_pfd[0].revents = fd, POLLIN, 0
			local sec = math.floor(left) -- (ppoll: a sub-millisecond `read -t` isn't rounded up)
			_ppoll_ts.tv_sec, _ppoll_ts.tv_nsec = sec, math.floor((left - sec) * 1e9)
			C.curse_rt_ppoll(_co_pfd, 1, _ppoll_ts, nil)
		end
	end
	return true
end
function M.time_push(sh)
	local st = sh._tstack or {}
	sh._tstack = st
	st[#st + 1] = { wall_secs(), os.clock() }
end
-- The `time` report as bash formats it: $TIMEFORMAT (default `\nreal\t%3lR\nuser\t%3lU\n
-- sys\t%3lS`; `time -p` uses the POSIX form) — %[p][l]R/U/S (p digits, l = MmS.FFs),
-- %P (CPU percentage), %%. An empty TIMEFORMAT prints nothing.
function M.time_text(sh, real, user, sys, posix)
	local fmt
	if posix then
		fmt = "real %2R\nuser %2U\nsys %2S"
	elseif sh.vars.TIMEFORMAT then
		fmt = sh:get("TIMEFORMAT")
		if fmt == "" then
			return ""
		end
	else
		fmt = "\nreal\t%3lR\nuser\t%3lU\nsys\t%3lS"
	end
	local out, i, n = {}, 1, #fmt
	while i <= n do
		local c = fmt:sub(i, i)
		if c == "%" and i < n then
			local j, prec, long = i + 1, 3, false
			local d = fmt:sub(j, j)
			if d == "%" then
				out[#out + 1] = "%"
				i = j + 1
			else
				if d:match("%d") then
					prec = math.min(3, tonumber(d))
					j = j + 1
					d = fmt:sub(j, j)
				end
				if d == "l" then
					long = true
					j = j + 1
					d = fmt:sub(j, j)
				end
				local v = (d == "R" and real) or (d == "U" and user) or (d == "S" and sys)
				if d == "P" then
					v = real > 0 and ((user + sys) * 100 / real) or 0
				end
				if v then
					if long and d ~= "P" then
						out[#out + 1] = ("%dm%." .. prec .. "fs"):format(math.floor(v / 60), v % 60)
					else
						out[#out + 1] = ("%." .. prec .. "f"):format(v)
					end
					i = j + 1
				else
					out[#out + 1] = c
					i = i + 1
				end
			end
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	return table.concat(out) .. "\n"
end
function M.time_report(sh, posix)
	local st = sh._tstack
	local t0 = st and table.remove(st)
	if not t0 then
		return
	end
	local real, cpu = wall_secs() - t0[1], os.clock() - t0[2]
	io.stderr:write(M.time_text(sh, real, cpu, 0, posix))
end
-- Compiled functions installed into sh.functions, keyed to the fn_x they wrap (weak).
-- In a program with eval/source a command name can be (re)defined at RUNTIME, which a
-- compiled call site (direct fn_x / native builtin / external spawn) wouldn't see.
-- names_static(sh, plain, fnames, fvals) is the call-site guard: every `plain` name
-- (builtin/external at compile time) must have NO function now, and every `fnames[i]`
-- must still be the registration of exactly `fvals[i]` (this module's fn_x).
M.COMPILED_ORIG = setmetatable({}, { __mode = "k" })
function M.mark_compiled(f, orig)
	M.COMPILED_ORIG[f] = orig or f
	return f
end
function M.names_static(sh, plain, fnames, fvals)
	local fns = sh.functions
	for i = 1, #plain do
		if fns[plain[i]] ~= nil then
			return false
		end
	end
	if fnames then
		for i = 1, #fnames do
			local f = fns[fnames[i]]
			if f == nil or M.COMPILED_ORIG[f] ~= fvals[i] then
				return false
			end
		end
	end
	return true
end
-- The first CHARACTER of IFS (the "$*" / "${a[*]}" join separator): a whole multibyte
-- character in a UTF-8 locale (IFS=é joins with é, not its first byte).
-- $IFS as splitting sees it: nil when unset — or declared with no value (`local IFS`),
-- which bash treats the same (default splitting, " " joining)
function M.ifs(sh)
	local b = sh.vars.IFS
	if b and (b.s ~= nil or b.n ~= nil) then
		return sh:get("IFS")
	end
	return nil
end
function M.ifs_num(sh) -- does $IFS hold a char of an arith result (a digit or '-')?
	local b = sh.vars.IFS
	if not b or b.s == " \t\n" then -- (unset / the default: the common case, no sh:get)
		return false
	end
	local v = M.ifs(sh)
	return v ~= nil and v:find("[%d%-]") ~= nil
end
function M.ifs_sep(sh) -- the "$*" joiner
	local v = M.ifs(sh)
	return v and M.ifs_first(v) or " "
end
function M.ifs_first(ifs)
	if ifs == "" then
		return ""
	end
	if ifs:byte(1) >= 0x80 and M.lc_mb_cur_max() > 1 then
		return ifs:sub(1, M.mb_charlen(ifs, 1))
	end
	return ifs:sub(1, 1)
end
-- Non-dot entry names of directory `path` (what `ls -1` lists), unsorted; {} if unreadable.
function M.dir_names(path)
	local out = {}
	local d = ffi.C.opendir(path)
	if d == nil then
		return out
	end
	while true do
		local e = ffi.C.readdir(d)
		if e == nil then
			break
		end
		local name = ffi.string(ffi.cast("const char *", e) + 19)
		if name:sub(1, 1) ~= "." then
			out[#out + 1] = name
		end
	end
	ffi.C.closedir(d)
	return out
end
-- globstar `**`: every directory at or under `base` (recursively), including base
-- itself (the zero-level case) — the prefixes an intermediate `**/` descends into.
local _lst = ffi.new("uint8_t[144]")
local function is_symlink(path)
	return C.curse_rt_lstat(path, _lst) == 0 and bit.band(ffi.cast("uint32_t *", _lst + 24)[0], 0xF000) == 0xA000
end
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
			if is_dir(path) and not is_symlink(path) then -- (`**` doesn't follow symlinked dirs)
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
	glob_icase = opts.nocase and true or false
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
	-- the bases came through a pattern segment: a final `**` then lists each base as itself
	-- (`**/a/**` -> a, …) rather than as `dir/` (`a/**` -> a/, …)
	local prev_glob = false
	local collapsed = {} -- segment index -> it absorbed a preceding `**`
	if opts.globstar then -- adjacent `**` segments are one (`**/**/a` is `**/a` — bash)
		local k = 2
		while k <= #segs do
			if segs[k] == "**" and segs[k - 1] == "**" then
				table.remove(segs, k)
				collapsed[k - 1] = true
			else
				k = k + 1
			end
		end
	end
	for si, seg in ipairs(segs) do
		local isglob = seg:find("[*?%[]") or seg:find("[?*+@!]%(")
		local islast = si == #segs
		if collapsed[si] then -- (the absorbed `**` counts as a pattern before this one)
			prev_glob = true
		end
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
		if seg == "**" and opts.globstar and islast then
			-- a FINAL `**` matches every file and directory at any depth below the base
			-- (plus the base itself as `dir/` — the zero-level match — when there is one)
			local function add(pth)
				nxt[#nxt + 1] = pth
			end
			for _, base in ipairs(cur) do
				if base ~= "" and base ~= "/" and is_dir(base) then -- (a base built from a literal may not exist)
					add(prev_glob and base or (base .. "/"))
				end
				for _, dir in ipairs(rec_dirs(base, opts.dotglob)) do
					if dir ~= base then
						add(dir)
					end
					for _, name in ipairs(scan_seg(dir, "*", opts.dotglob, opts.skipdots)) do
						local path = joined(dir, name)
						if not is_dir(path) or is_symlink(path) then -- (a symlinked dir: an entry, not descended)
							add(path)
						end
					end
				end
			end
		elseif seg == "**" and opts.globstar and not islast then
			-- an intermediate `**/` matches zero or more directory levels
			for _, base in ipairs(cur) do
				for _, dir in ipairs(rec_dirs(base, opts.dotglob)) do
					nxt[#nxt + 1] = dir
				end
			end
		elseif not isglob then
			-- literal segment: append; a nonexistent intermediate dir yields nothing
			-- next round (opendir fails), so no explicit stat needed. Its backslash escapes
			-- are removed (`./t\mp/*` names ./tmp — bash).
			-- (a `\` before the `/` that ended it — `./tmp\/a/*` — goes too; in a GLOB segment
			-- it stays, so `tm[p]\/…` matches nothing — bash)
			local lit = seg:find("\\", 1, true) and seg:gsub("\\(.)", "%1"):gsub("\\$", "") or seg
			for _, base in ipairs(cur) do
				local path = joined(base, lit)
				-- a trailing literal (`*/.`) must name something reachable: a directory that
				-- isn't searchable yields no `dir/.` (bash stats the result)
				if not islast or C.curse_rt_lstat(path, _lst) == 0 then
					nxt[#nxt + 1] = path
				end
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
		prev_glob = prev_glob or isglob and true or false
		cur = nxt
		if #cur == 0 then
			return nil
		end
	end
	if #cur == 0 then
		return nil
	end
	-- a pattern ending in `/` (`*/`, `**/`) matches DIRECTORIES only, shown with the slash
	if pattern:sub(-1) == "/" then
		local dirs = {}
		for _, p in ipairs(cur) do
			local d = p:sub(-1) == "/" and p:sub(1, -2) or p
			if d ~= "" and is_dir(d) then
				dirs[#dirs + 1] = d .. "/"
			end
		end
		cur = dirs
		if #cur == 0 then
			return nil
		end
	end
	table.sort(cur, M.coll_lt)
	return cur -- (a path reached twice — `**/a/**` — is listed twice, as bash does)
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
do
local FS_PLAIN = {} -- (bytes that neither split on the default IFS nor glob)
for c = 0, 255 do
	FS_PLAIN[c] = true
end
for c in (" \t\n*?[]\\+@!(") :gmatch(".") do
	FS_PLAIN[c:byte()] = false
end
-- a short value that neither splits on the default IFS nor globs (one field, as is)
function M.plain_field(sh, value)
	local n = #value
	if n > 64 then
		return false
	end
	local ifs0 = M.ifs(sh)
	if not (ifs0 == nil or ifs0 == " \t\n") then
		return false
	end
	for k = 1, n do
		if not FS_PLAIN[value:byte(k)] then
			return false
		end
	end
	return true
end
function M.field_split(sh, value, split)
	local n = #value
	if n <= 64 then -- the common short word ($i, $name): one field, as is — no IFS/glob setup
		local ifs0 = M.ifs(sh)
		if ifs0 == nil or ifs0 == " \t\n" then
			if n == 0 then
				return split and {} or { value }
			end
			local plain = true
			for k = 1, n do
				if not FS_PLAIN[value:byte(k)] then
					plain = false
					break
				end
			end
			if plain then
				return { value }
			end
		end
	end
	local fields
	if split then
		-- word-split on $IFS. IFS is a SET of chars; a delimiter may be multibyte
		-- (`IFS=ç`), so index by whole codepoint. Whitespace runs collapse, and a single
		-- non-whitespace delimiter (optionally surrounded by whitespace) ends a field.
		fields = {}
		local ifs = (M.ifs(sh) or " \t\n")
		local ifsset = {}
		for _, ch in ipairs(M.mb_chars(ifs)) do
			ifsset[ch.s] = true
		end
		local mbifs = M.lc_mb_cur_max() > 1 and ifs:find("[\128-\255]") ~= nil
		local function isws(c) -- IFS whitespace only (subst.c ifs_whitespace)
			return (c == " " or c == "\t" or c == "\n") and ifsset[c]
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
					-- (LEADING whitespace is just ignored: a `:` right after it still ends an
					-- empty first field — IFS=': ' splits " :" into one empty field)
					local leading = cur == nil and #fields == 0
					if cur ~= nil then
						brk()
					end
					i = i + 1
					while i <= n and isws(v:sub(i, i)) do
						i = i + 1
					end
					if i <= n and not leading then
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
			else -- (a run of non-IFS characters joins the field in one piece: linear, not n^2)
				local j = i + cl
				while j <= n do
					local jl = clen(v, j)
					if inifs(jl == 1 and v:sub(j, j) or v:sub(j, j + jl - 1)) then
						break
					end
					j = j + jl
				end
				cur = (cur or "") .. v:sub(i, j - 1)
				i = j
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
			elseif c == "/" then
				open = false -- (a bracket expression can't span a `/`)
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
			local m = M.glob_expand(s, { dotglob = dotglob, skipdots = skipdots, globstar = globstar, nocase = sh.shopt.nocaseglob })
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
-- Tag a segment as part of a double-quoted "…" that holds "$@" (the parser's dqat/dqend):
-- if the @ expands to no words and the rest to empty, the segment is no word at all.
function M.dqseg(seg, dqend)
	seg.dq, seg.dqend = true, dqend
	return seg
end
function M.expand_fields(sh, segs)
	local s1 = #segs == 1 and segs[1]
	if s1 and s1.multi and s1.q and not s1.star then -- a lone "$@" / "${a[@]}": its elements
		return s1.elems
	end
	if s1 and not s1.multi and s1.s and M.plain_field(sh, s1.s) then -- (one plain word: as is)
		if s1.s == "" and s1.split then
			return {}
		end
		return { s1.s }
	end
	local ifs = (M.ifs(sh) or " \t\n")
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
	local function isws(c) -- IFS whitespace only (subst.c ifs_whitespace)
		return (c == " " or c == "\t" or c == "\n") and ifsset[c]
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
					-- (LEADING whitespace is just ignored: a `:` right after it still ends an
					-- empty first field — IFS=': ' splits " :" into one empty field)
					local leading = cur == nil and #fields == 0
					if cur ~= nil then
						brk()
					end
					i = i + 1
					while i <= n and isws(v:sub(i, i)) do
						i = i + 1
					end
					if i <= n and not leading then
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
	local dq_null, dq_at -- (a "…$@…" segment's parts, rt.dqseg: as interp's expand_to_fields)
	for _, seg in ipairs(segs) do
		if seg.dq and (seg.multi and #seg.elems == 0 or seg.s == "") then
			if seg.multi and not seg.star then
				dq_at = true
			else
				dq_null = true
			end
		elseif seg.multi then
			-- a $@ / $* part: multiple elements (seg.elems), joined/split per bash. Quoted
			-- "$@" is one field PER element (each concatenates with the abutting text — the
			-- first with what precedes, the last with what follows); quoted "$*" joins on
			-- IFS[0]; unquoted joins on IFS[0] then word-splits (per-element under IFS="").
			local els = seg.elems
			if seg.q then
				if seg.star then
					add(table.concat(els, M.ifs_first(ifs)), false)
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
				feed_split(table.concat(els, M.ifs_first(ifs)))
			end
		elseif seg.split then
			feed_split(seg.s)
		else
			add(seg.s, seg.unq)
		end
		if seg.dqend then -- end of a "…$@…" segment: empty parts make a null word unless "$@" was empty
			if dq_null and not dq_at then
				add("", false)
			end
			dq_null, dq_at = nil, nil
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
		return M.field_glob_active(f)
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
			local m = M.glob_expand(glob_pat(f), { dotglob = dotglob, skipdots = skipdots, globstar = globstar, nocase = sh.shopt.nocaseglob })
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
	if #out == 1 and #segs > 1 and sh.shopt.assoc_expand_once and segs[1].unq and not segs[1].split
		and segs[1].s:match("^[%a_][%w_]*%[") then
		M.mark_arrayref(sh, out[1]) -- (an unquoted NAME[$k] argument: see mark_arrayref)
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
-- `declare -a/-A NAME=(…)` cannot CHANGE an existing array's kind (bash): an -A on an
-- existing indexed array, or -a on an existing associative one, is an error (status 1, no
-- assignment) — mirrors interp's b_export conversion check. Returns true (having reported it)
-- when the compiled declare-array block must be skipped. `cmd` is declare/typeset/local.
-- The conversion error text (bash): with a compound value `NAME=(…)` it's reported by the
-- array assignment first — named by the running FUNCTION (bash's this_command_name) and
-- then again by the builtin, status 1; at top level just `NAME: …`, status 0. A plain
-- `declare -A NAME` reports `declare: NAME: …`, status 1. Returns the status.
function M.array_convert_msg(sh, cmd, name, what, compound)
	local fn = sh:in_function() and sh.funcstack[1]
	if compound and not fn then -- (and the rest of the line is abandoned)
		io.stderr:write("curse: " .. name .. ": cannot convert " .. what .. "\n")
		error({ __curse_exit = 1, __curse_lineabort = true })
	end
	if compound then
		io.stderr:write("curse: " .. fn .. ": " .. name .. ": cannot convert " .. what .. "\n")
	end
	io.stderr:write("curse: " .. cmd .. ": " .. name .. ": cannot convert " .. what .. "\n")
	return 1
end
-- An empty associative key in a compound literal, as bash reports it: a declaration
-- builtin's literal was expanded and requoted (`['']='x'`), a plain one is shown as
-- written (`[""]=y`, `[$k]=w`)
function M.empty_key_src(sh, it)
	if sh.arrayargs_pending or it.decl then
		return "['']" .. (it.op or "=") .. "'" .. it.val:gsub("'", "'\\''") .. "'"
	end
	return "[" .. (it.rawkey or it.key) .. "]" .. (it.op or "=") .. (it.src or it.val)
end
-- A compound-literal word as bash reports it: the raw text, with a `$'…'` already
-- translated to '…' by the parser; a declaration builtin single-quotes it
function M.compound_word_src(sh, it)
	local s = it.src or it.val
	if s:find("$'", 1, true) then
		local out, i, n, dq = {}, 1, #s, false
		while i <= n do
			local c = s:sub(i, i)
			if c == "\\" then
				out[#out + 1] = s:sub(i, i + 1)
				i = i + 2
			elseif c == '"' then
				dq = not dq
				out[#out + 1] = c
				i = i + 1
			elseif not dq and c == "'" then
				local e = s:find("'", i + 1, true) or n
				out[#out + 1] = s:sub(i, e)
				i = e + 1
			elseif not dq and c == "$" and s:sub(i + 1, i + 1) == "'" then
				local j = i + 2
				while j <= n and s:sub(j, j) ~= "'" do
					j = j + (s:sub(j, j) == "\\" and 2 or 1)
				end
				out[#out + 1] = "'" .. M.ansi_unescape(s:sub(i + 2, j - 1), true):gsub("\1", "") .. "'"
				i = j + 1
			else
				out[#out + 1] = c
				i = i + 1
			end
		end
		s = table.concat(out)
	end
	if sh.arrayargs_pending or it.decl then
		return "'" .. s:gsub("'", "'\\''") .. "'"
	end
	return s
end
-- An associative key/value-pair literal (`A=(k1 v1 k2 v2)`, bash's assign_assoc_from_kvlist):
-- an empty key is reported (as written; by a declaration builtin, requoted: '') and skipped
function M.assoc_kvpairs(sh, name, items)
	for k = 1, #items, 2 do
		local it, v = items[k], items[k + 1]
		-- (a compiled literal's `[k]=v` word, rebuilt as the one plain word it is here)
		local key = it.key and ("[" .. it.key .. "]" .. it.op .. it.val) or it.val
		if key == "" then
			io.stderr:write("curse: " .. ((sh.arrayargs_pending or it.decl) and "''" or M.compound_word_src(sh, it))
				.. ": bad array subscript\n")
		else
			sh:array_set(name, key, v and (v.key and ("[" .. v.key .. "]" .. v.op .. v.val) or v.val) or "", false)
		end
	end
end
function M.array_convert_err(sh, name, isassoc, cmd)
	if isassoc == nil then -- (neither -a nor -A: the literal takes the array's own kind)
		return false
	end
	local b = sh.vars[sh:deref(name)]
	if b and b.ro and b.arr and (b.assoc and true or false) ~= (isassoc and true or false) then
		io.stderr:write("curse: " .. name .. ": readonly variable\n") -- (reported before conversion)
		sh.status = 1
		return true
	end
	if isassoc then
		if b and b.arr and not b.assoc then
			sh.status = M.array_convert_msg(sh, cmd, name, "indexed to associative array", true)
			return true
		end
	elseif b and b.assoc then
		sh.status = M.array_convert_msg(sh, cmd, name, "associative to indexed array", true)
		return true
	end
	return false
end
local arrayassign_body
-- an expression error in a subscript (`a=([x y]=1)`) fails just this assignment, status 1,
-- like interp's arrayassign (errexit is the caller's errchk)
function M.arrayassign(sh, name, items, append)
	local ok, err = pcall(arrayassign_body, sh, name, items, append)
	if not ok then
		if type(err) == "table" and err.__curse_experr then
			sh.status = 1
			return
		end
		error(err, 0)
	end
end
arrayassign_body = function(sh, name, items, append)
	-- through a nameref (`declare -n r=t; declare -a r=(…)`) the literal lands in the
	-- referenced array, as interp's do_arrayassign
	local dn = sh:deref(name)
	name = dn ~= "" and dn or name
	local rb = sh.vars[name]
	if rb and rb.ro then
		io.stderr:write("curse: " .. name .. ": readonly variable\n")
		sh.status = 1
		return
	end
	local isassoc = sh:is_assoc(name)
	-- (bash's kvpair_assignment_p: the FIRST word decides)
	local kv = isassoc and items[1] and items[1].key == nil
		and (sh.arrayargs_pending or items[1].decl or (items[1].src or items[1].val):byte(1) ~= 91)
	local function keyof(kt)
		-- (an indexed subscript loses bash's CTLESC bytes, e.g. from a $'\001' in it)
		return isassoc and kt or M.to_arr_key(M.arith_str(sh, (kt:gsub("\1", ""))))
	end
	if name == "DIRSTACK" and M.dirstack_dyn(sh) then -- (each element through its assign_func)
		local auto = append and #(sh.dirstack or {}) + 1 or 0
		for _, it in ipairs(items) do
			local k = it.key ~= nil and tonumber(keyof(it.key)) or auto
			M.dirstack_set(sh, k, it.val, it.op == "+=")
			auto = (k or auto) + 1
		end
		return
	end
	if append and rb then
		rb.empty_decl = nil -- (`a+=()` counts as an assignment: shows =())
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
		if not kv then -- keyed elements assigned; a bare one is an error (reported, skipped)
			for _, it in ipairs(items) do
				if it.key == nil then
					io.stderr:write("curse: " .. name .. ": " .. M.compound_word_src(sh, it)
						.. ": must use subscript when assigning associative array\n")
				else
					local idx = keyof(it.key)
					if idx == "" then -- (an empty key: reported and skipped, like interp's)
						io.stderr:write("curse: " .. M.empty_key_src(sh, it) .. ": bad array subscript\n")
					elseif it.op == "+=" and not append then
						sh:array_set(name, idx, (snap and snap[idx] or "") .. it.val, false)
					else
						sh:array_set(name, idx, it.val, it.op == "+=")
					end
				end
			end
		else -- key/value pairs: alternating key value words
			M.assoc_kvpairs(sh, name, items)
		end
	else
		local auto = append and M.arr_next(sh, name) or 0
		for _, it in ipairs(items) do
			if it.key ~= nil then
				-- a bad element is reported (as written) and skipped (interp's do_arrayassign)
				local src = "[" .. it.key .. "]" .. (it.op or "=") .. it.val
				if it.key:match("^%s*$") then
					io.stderr:write("curse: " .. src .. ": bad array subscript\n")
				elseif it.key == "*" or it.key == "@" then
					io.stderr:write("curse: " .. src .. ": cannot assign to non-numeric index\n")
				else
					local k = sh:array_set(name, keyof(it.key), it.val, it.op == "+=")
					if k then
						auto = M.key_next(k) -- (indexed += appends to CURRENT)
					else
						io.stderr:write("curse: " .. src .. ": bad array subscript\n")
					end
				end
			else
				sh:array_set(name, auto, it.val, false, true)
				auto = M.key_next(auto)
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
-- a negative subscript past the start: `NAME[SUB]: bad array subscript`, the line aborted —
-- reported before readonly-ness, since bash evaluates the subscript first
local function neg_oob_abort(sh, name, key, sub)
	if M.neg_oob(sh, name, key) then
		io.stderr:write("curse: " .. name .. "[" .. sub .. "]: bad array subscript\n")
		sh.status = 1
		error({ __curse_exit = 1, __curse_lineabort = true })
	end
end
function M.assign_element(sh, name, raw, expanded, value, append)
	local rb = sh.vars[sh:deref(name)]
	if rb and rb.ro and rb.arr and not rb.assoc and raw:find("-", 1, true) then
		neg_oob_abort(sh, name, M.array_key(sh, name, raw, expanded), raw)
	end
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
		if key == "" then -- (an associative array has no "" key)
			io.stderr:write("curse: " .. name .. "[" .. raw .. "]: bad array subscript\n")
			sh.status = 1
			error({ __curse_exit = 1, __curse_lineabort = true })
		end
	elseif raw:match("^%s*$") or raw:match('^%s*"%s*"%s*$') then -- (a blank subscript is 0)
		key = 0
	elseif raw == "@" or raw == "*" then -- (`ia[@]=x`: interp's array_key says so too)
		io.stderr:write("curse: " .. name .. "[" .. raw .. "]: bad array subscript\n")
		error({ __curse_exit = 1, __curse_lineabort = true })
	else
		local ok, v = pcall(function()
			return M.to_arr_key(M.arith_str(sh, raw))
		end)
		if not ok then
			if type(v) == "table" and v.__curse_unbound then
				error(v, 0) -- (set -u: said already, and fatal as it is)
			end
			if not (type(v) == "table" and v.__curse_matherr) then -- (arith_str reported it)
				io.stderr:write("curse: " .. require("parser").arith_errmsg(raw, v) .. "\n")
			end
			sh.status = 1 -- (array_expand_index: DISCARD, like interp's array_key)
			error({ __curse_exit = 1, __curse_lineabort = true, __curse_discard = true })
		end
		key = v
	end
	if not sh:array_set(name, key, value, append) then
		neg_oob_abort(sh, name, key, raw)
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
-- (`raw`: the subscript as written, which a bad-subscript report names)
function M.assign_element_i(sh, name, keyi, value, append, raw)
	if keyi < 0 then
		neg_oob_abort(sh, name, to_arr_key(keyi), raw or M.i64_to_str(keyi))
	end
	if elem_readonly_abort(sh, name) then
		return
	end
	if not sh:array_set(name, to_arr_key(keyi), value, append) then
		neg_oob_abort(sh, name, to_arr_key(keyi), raw or M.i64_to_str(keyi))
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
		local ok, v
		if src:find("[$`]") then -- (the subscript is EXPANDED text: a `$(` in the value is
			-- just a character to the arithmetic, never run — interp's EXP_EXPANDED parse)
			local P = require("parser")
			local sc, sx = P.arith_cmd, sh.arith_expanded
			P.arith_cmd, sh.arith_expanded = nil, true
			ok, v = pcall(require("interp").arith_eval_str, sh, src)
			P.arith_cmd, sh.arith_expanded = sc, sx
		else
			ok, v = pcall(M.arith_str, sh, src)
		end
		if not ok then
			if type(v) == "table" and v.__curse_unbound then
				error(v, 0) -- (set -u: said already, and fatal as it is)
			end
			if not (type(v) == "table" and v.__curse_matherr) then -- (arith_str reported it)
				io.stderr:write("curse: " .. require("parser").arith_errmsg(src, v) .. "\n")
			end
			sh.status = 1 -- (array_expand_index: DISCARD, like interp's array_key)
			error({ __curse_exit = 1, __curse_lineabort = true, __curse_discard = true })
		end
		key = to_arr_key(v)
	end
	if not sh:array_set(name, key, value, append) then
		neg_oob_abort(sh, name, key, src)
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
local SUBSCRIPT_AST = {} -- raw subscript text -> parsed arith (bounded by the program text)
function M.array_key(sh, name, raw, expanded)
	if sh:is_assoc(name) then
		if type(expanded) == "function" then -- (emit's subscript_word: a side-effecting key)
			return expanded()
		end
		return expanded
	end
	if raw:match("^%s*$") then
		return 0
	end
	-- the parsed subscript is cached per raw text; interp's arith_key evaluates it (natively
	-- when it can; a non-numeric $name takes bash's textual path, quoted as a subscript) and
	-- makes any error abandon the line
	local idx = SUBSCRIPT_AST[raw]
	if idx == nil then
		if raw:find("[$`]") then -- (an expansion: the deferred node that knows bash's text rules)
			idx = { k = "xpand", raw = raw }
		else
			local pok, ast = pcall(require("parser").arith, raw, true)
			idx = pok and ast or false
		end
		SUBSCRIPT_AST[raw] = idx
	end
	if not idx then
		local _, perr = pcall(require("parser").arith, raw)
		io.stderr:write("curse: " .. require("parser").arith_errmsg(raw, perr) .. "\n")
		error({ __curse_exit = 1, __curse_lineabort = true })
	end
	return require("interp")._int.arith_key(sh, name, idx, raw)
end

-- Scalar `name+=value` (non-index) for the compiled tier, exactly interp's append path: an
-- ARRAY var appends value to element 0, an INTEGER var (declare -i) arithmetic-adds it, and a
-- plain/unset scalar string-concatenates. A readonly var is rejected (status 1, line-abort like
-- a standalone assignment). Gated at emit to non-nameref programs with an emit_word-able rhs.
-- `s+=piece` in a loop copied the whole value each time (a new Lua string: quadratic).
-- A plain variable being appended to instead holds its value in a string.buffer, with
-- `s` ABSENT from the box: reading b.s builds (and caches) the string; ANY write to b.s
-- (a new value, or nil to unset) drops the buffer first — so every other reader and
-- writer of the box works unchanged.
local append_lazy
do
local SBUF = require("string.buffer")
local LAZY_STR = {
	__index = function(t, k)
		if k == "s" then
			local sb = rawget(t, "_sb")
			if sb and rawget(t, "n") == nil then
				local v = rawget(t, "_sbv")
				if not v then
					v = sb:tostring()
					rawset(t, "_sbv", v)
				end
				return v
			end
		end
		return nil
	end,
	__newindex = function(t, k, v)
		if k == "s" then
			rawset(t, "_sb", nil)
			rawset(t, "_sbv", nil)
		end
		rawset(t, k, v)
	end,
}
local APPEND_SPECIAL = { OPTIND = true, BASH_ARGV0 = true, POSIXLY_CORRECT = true, IGNOREEOF = true,
	RANDOM = true, SRANDOM = true, LINENO = true, FUNCNAME = true, TZ = true }
append_lazy = function(sh, dn, b, value)
	if b.ref or b.arr or b.int or b.lower or b.upper or b.cap or b.exported or rawget(b, "virt")
		or APPEND_SPECIAL[dn] or LOCALE_VARS[dn] or value:find("\0", 1, true) then
		return false
	end
	local mt = getmetatable(b)
	if mt ~= nil and mt ~= LAZY_STR then
		return false
	end
	local sb = rawget(b, "_sb")
	if not (sb and rawget(b, "s") == nil and rawget(b, "n") == nil) then
		local cur = sh:get(dn)
		sb = SBUF.new()
		sb:put(cur)
		rawset(b, "s", nil)
		rawset(b, "n", nil)
		rawset(b, "_sb", sb)
		if mt == nil then
			setmetatable(b, LAZY_STR)
		end
	end
	sb:put(value)
	rawset(b, "_sbv", nil)
	return true
end
end
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
	elseif b and b.int then -- (the old value is evaluated too, as bash does)
		sh:aset(name, M.int_value(sh, sh:get(name)) + M.int_value(sh, value))
	elseif b and (b.lower or b.upper) then -- declare -l/-u: case-fold the appended result
		local v = sh:get(name) .. value
		sh:set_str(name, b.lower and v:lower() or v:upper())
	elseif not (b and append_lazy(sh, sh:deref(name), b, value)) then
		sh:set_str(name, sh:get(name) .. value)
	end
end

-- Read a scalar array/assoc ELEMENT ${name[sub]} (op=nil) for the compiled tier: resolve the
-- key, then defer to Shell:expand_param — the SAME element read + set -u nounset + isset path
-- the interpreter uses, so the value matches exactly.
function M.array_elem(sh, name, raw, expanded)
	local key = M.array_key(sh, name, raw, expanded)
	M.elem_read_check(sh, name, key)
	return sh:expand_param({ name = name, index = raw }, nil, nil, key)
end

-- An element's key for a compiled ${a[i]OP}: a negative subscript past the start says
-- "bad array subscript" (the read then goes on), as interp's expand_pexp does.
function M.array_key_rc(sh, name, raw, expanded)
	local key = M.array_key(sh, name, raw, expanded)
	M.elem_read_check(sh, name, key)
	return key
end
-- ${#a[i]} / ${#a[@]} in compiled code: under set -u only a variable that doesn't exist
-- at all is unbound (named bare, as array_length_reference does); an unset element of an
-- existing array is length 0 — expand_param's exact rule.
function M.elem_len(sh, name, raw, expanded)
	return sh:expand_param({ name = name, index = raw, op = "len" }, nil, nil, M.array_key(sh, name, raw, expanded))
end
-- Read an array/assoc ELEMENT in ARITHMETIC context (`$(( a[i] ))`), exactly interp's arith
-- var-with-idx path (interp.lua ~448): a set -u check on the BASE var (arith_nounset — FATAL
-- for an unset base, but an unset ELEMENT of a set array reads as 0), then arith_resolve the
-- element value recursively (a[0]="x+1" -> x+1). A non-numeric element ("12 34") is a NON-fatal
-- syntax error: arith_resolve prints the exact message and raises experr, which is converted to
-- the tier's lineabort so run_compiled contains it (status 1, abort line, continue).
-- A bad element reference in arithmetic is NOT fatal (bash): the message is said, a read is
-- 0 and a write is skipped. `how` = "r" (a read), "w" (a write) or "rw" (`a[i] += e`, `a[i]++`:
-- both messages). arith_badraw checks the subscript TEXT (before it is evaluated): an empty
-- one (get_array_value / valid_identifier), `@`/`*` of an indexed array (no AV_ALLOWALL);
-- arith_badkey the evaluated index: a negative one before the start (a read of a non-array
-- too), named `NAME` by a read and `NAME[IND]` by a write (expr_bind_array_element).
function M.arith_badraw(sh, name, raw, how)
	if raw == "" then
		if how ~= "w" then
			io.stderr:write("curse: " .. name .. "[]: bad array subscript\n")
			io.stderr:write("curse: " .. name .. "[]: bad array subscript\n")
		end
		if how ~= "r" then
			local cmd = require("parser").arith_cmd or (sh.in_arithcmd and "((") -- (compiled `(( ))`)
			io.stderr:write("curse: " .. (cmd and (cmd .. ": ") or "") .. "`" .. name
				.. "[]': not a valid identifier\n")
		end
		return true
	end
	if (raw == "@" or raw == "*") and not sh:is_assoc(name) then
		for _ = 1, how == "rw" and 2 or 1 do
			io.stderr:write("curse: " .. name .. "[" .. raw .. "]: bad array subscript\n")
		end
		return true
	end
	return false
end
function M.arith_badkey(sh, name, key, how)
	if type(key) ~= "number" or key >= 0 then
		return false
	end
	local b = sh.vars[sh:deref(name)]
	if b and b.assoc then
		return false
	end
	local rbad = not (b and b.arr) or M.neg_oob(sh, name, key)
	local wbad = M.neg_oob(sh, name, key)
	if how ~= "w" and rbad then
		io.stderr:write("curse: " .. name .. ": bad array subscript\n")
	end
	if how ~= "r" and wbad then
		io.stderr:write("curse: " .. name .. "[" .. tostring(key) .. "]: bad array subscript\n")
	end
	if how == "r" then
		return rbad
	end
	return wbad
end

function M.arith_read_elem(sh, name, raw, expanded)
	local I = require("interp")._int
	I.arith_nounset(sh, name) -- fatal if the base var is unset under set -u (outside the pcall)
	if M.arith_badraw(sh, name, raw, "r") then
		return i64(0)
	end
	local key = M.array_key(sh, name, raw, expanded)
	if M.arith_badkey(sh, name, key, "r") then
		return i64(0)
	end
	local ok, v = pcall(I.arith_resolve, sh, sh:array_get(name, key))
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
	local how = read_first and "rw" or "w"
	if M.arith_badraw(sh, name, raw, how) then
		return compute(read_first and i64(0) or nil)
	end
	local key = M.array_key(sh, name, raw, expanded)
	if M.arith_badkey(sh, name, key, how) then -- (a bad element: 0 is read, nothing stored)
		return compute(read_first and i64(0) or nil)
	end
	local old = read_first and M.arith_str(sh, sh:array_get(name, key) or "") or nil
	local v = compute(old)
	sh:array_set(name, key, M.i64_to_str(v))
	return v
end

-- ++a[i] / a[i]++ (and --): read the element (nounset on the base), store old±1, return the
-- OLD value for post or the NEW value for pre.
function M.arith_elem_incr(sh, name, raw, expanded, delta, is_post)
	require("interp")._int.arith_nounset(sh, name)
	local key = not M.arith_badraw(sh, name, raw, "rw") and M.array_key(sh, name, raw, expanded)
	if not key or M.arith_badkey(sh, name, key, "rw") then -- (a bad element: 0 is read, nothing stored)
		return is_post and i64(0) or i64(delta)
	end
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
			return tostring(M.array_count_u(self, name, pe.uname))
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
	-- unset-handling ops (:- - :+ + := = :? ?) and $@/$* are exempt (and @-transforms,
	-- which apply their own rule below).
	if
		self.opt_u
		and not isset
		and not (name == "@" or name == "*")
		and index ~= "@"
		and index ~= "*"
		and op ~= "@"
		and op ~= ":-"
		and op ~= "-"
		and op ~= ":+"
		and op ~= "+"
		and op ~= ":="
		and op ~= "="
		and op ~= ":?"
		and op ~= "?"
		and self:special_get(name) == ""
		-- ${#a[3]} of an unset element of a visible array is just 0; with no such
		-- variable (or an invisible one: `declare -A h`) set -u names the bare array
		-- (array_length_reference)
		and not (op == "len" and index and M.var_visible(self, name))
	then
		local lbl = pe.uname or (op == "len" and name) or M.pe_label(pe)
		io.stderr:write("curse: " .. lbl .. ": unbound variable\n")
		error({ __curse_exit = self.opt_c and 127 or 1, __curse_lineabort = self.opt_i or nil })
	end
	-- := / = write back to the SAME target that was read: an array element when
	-- subscripted (${a[0]=x} must populate a[0]), else the scalar variable.
	local function assign_default(v)
		if not name:match("^[%a_]") then -- ${6=x} ${@=x}: bash aborts the line
			io.stderr:write("curse: $" .. name .. ": cannot assign in this way\n")
			error({ __curse_exit = 1, __curse_lineabort = true })
		end
		if index and index ~= "@" and index ~= "*" then
			local ab = self.vars[self:deref(name)]
			if ab and ab.ro then
				M.assign_default_fail(self, self:deref(name), "readonly variable")
			end
			self:array_set(name, idxnum or 0, v)
			return self:array_get(name, idxnum or 0) or v -- (as stored: -i / -u / -l applied)
		end
		-- a bare name that IS an array writes element 0 (bash), not a scalar shadow; the
		-- var's attributes apply (declare -i/-u/-l) and the expansion is the stored value
		return M.assign_default(self, name, v)
	end
	if op == "len" then
		if index then
			M.len_badsub(self, name, index, idxnum or 0)
		end
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
			return assign_default(A())
		end
		return val
	end
	if op == "=" then
		if not isset then
			return assign_default(A())
		end
		return val
	end
	if op == ":?" then
		if val == "" then -- (no word at all: bash's own words)
			io.stderr:write("curse: " .. (pe.uname or M.pe_label(pe)) .. ": " .. ((arg == nil or arg == "") and "parameter null or not set" or A()) .. "\n")
			error({ __curse_exit = self.opt_c and 127 or 1, __curse_lineabort = self.opt_i or nil })
		end
		return val
	end
	if op == "?" then
		if not isset then
			io.stderr:write("curse: " .. (pe.uname or M.pe_label(pe)) .. ": " .. ((arg == nil or arg == "") and "parameter not set" or A()) .. "\n")
			error({ __curse_exit = self.opt_c and 127 or 1, __curse_lineabort = self.opt_i or nil })
		end
		return val
	end
	arg = arg or ""
	if op == "@" then -- ${x@OP} transforms
		-- under set -u a variable with no value is unbound for every transform, @a included
		-- (even a declared-but-valueless one: `declare -A m; ${m@a}` fails — bash); @a/@A
		-- accept an array with any element, the others need its [0]
		local b = self.opt_u and not isset and (arg == "a" or arg == "A") and not index and self.vars[self:deref(name)]
		if self.opt_u and not isset and not (b and b.arr and next(b.arr) ~= nil) then
			io.stderr:write("curse: " .. (pe.uname or M.pe_label(pe)) .. ": unbound variable\n")
			error({ __curse_exit = self.opt_c and 127 or 1, __curse_lineabort = self.opt_i or nil })
		end
		-- @a reports the VARIABLE's attributes (e.g. `A` for a declared assoc array),
		-- so it's non-empty even when the scalar view (a[0]) is unset; the other
		-- transforms yield empty on an unset var.
		if arg == "a" then
			return self:attr_string(name)
		end
		if not isset then -- (valueless but with attributes: `declare -r v`, an array w/o [0])
			local at = arg == "A" and self:attr_string(name) or ""
			return at ~= "" and ("declare -" .. at .. " " .. name) or ""
		end
		if arg == "A" then -- declare-able form (with the attributes, when it has any: bash)
			if not name:match("^[%a_]") then
				return "" -- (a positional/special parameter isn't a variable: nothing)
			end
			local dn = self:deref(name) -- (through a nameref: its target's assignment)
			local at = self:attr_string(dn)
			return (at ~= "" and ("declare -" .. at .. " ") or "") .. dn .. "=" .. M.shell_quote(val)
		end
	end
	if op == "sub" and not isset then -- (an unset value has no substring to check)
		return ""
	end
	return self:apply_str_op(op, val, arg, arg2, pe.arg2)
end

-- Shell-quote a string so it round-trips through eval (single-quote form).
local shell_quote = M.shell_quote

-- Decode PS1 prompt backslash-escapes (for ${x@P}). Parameter/command expansion
-- of the result is done by the caller (interp) afterward.
-- $- : the current option flags. h/B are always on (like bash); set flags and the
-- -i/-c invocation modes are appended in bash-ish order.
function Shell:dash_flags()
	-- $- in bash's shell_flags order (flags.c which_set_flags): a b e f h i k m n p r t u v x
	-- B C E H P T, then c. hashall/braceexpand default on; histexpand shows only when set
	-- explicitly or interactive (bash turns it off for scripts).
	local function on(f)
		local v = self[f]
		if v == nil then
			return M.SETDEFAULT[f] or false
		end
		return v
	end
	local t = {}
	for _, fl in ipairs({ { "a", "opt_a" }, { "b", "opt_b" }, { "e", "opt_e" }, { "f", "opt_f" },
		{ "h", "opt_h" }, { "i", "opt_i" }, { "k", "opt_k" }, { "m", "opt_m" }, { "n", "opt_n" },
		{ "p", "opt_p" }, { "r", "opt_r" }, { "t", "opt_t" }, { "u", "opt_u" }, { "v", "opt_v" },
		{ "x", "opt_x" }, { "B", "opt_B" }, { "C", "opt_C" }, { "E", "opt_errtrace" } }) do
		if on(fl[2]) then
			t[#t + 1] = fl[1]
		end
	end
	if self.opt_H == true or (self.opt_H == nil and self.opt_i) then
		t[#t + 1] = "H"
	end
	if on("opt_P") then
		t[#t + 1] = "P"
	end
	if on("opt_functrace") then
		t[#t + 1] = "T"
	end
	if self.opt_c then
		t[#t + 1] = "c"
	end
	return table.concat(t)
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
-- promptvars (or posix): the decoded prompt is then expanded as if double-quoted, so
-- text that comes from outside the prompt (\w, \W, \s, \h, \H, \D) is quoted for it —
-- a directory named `$(cmd)` shows as such and never runs (bash's
-- sh_backslash_quote_for_double_quotes).
function M.prompt_expands(sh)
	return sh.shopt.promptvars ~= false or sh.opt_posix
end
local function pq(sh, v)
	return M.prompt_expands(sh) and (v:gsub('[$`"\\]', "\\%0")) or v
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
				-- `\$` decodes to `\$` for a non-root user: the promptvars expansion that
				-- follows removes the backslash (so `\\\$` -> `\` `\$` -> `\$`, as bash)
				["$"] = (self:special_get("EUID") == "0" and "#" or M.prompt_expands(self) and "\\$" or "$"),
				t = os.date("%H:%M:%S"),
				T = os.date("%I:%M:%S"),
				["@"] = os.date("%I:%M %p"),
				A = os.date("%H:%M"),
				d = os.date("%a %b %d"),
				s = pq(self, self.shellname or "bash"),
				v = "5.2",
				V = "5.2.37",
				-- \! the history number of this command; \# the command number
				["!"] = tostring(self.history and #self.history > 0 and (self.hist_base or 1) + #self.history - 1 or 1),
				["#"] = tostring(self.cmd_number or 1),
				j = (function() -- number of jobs the shell is managing
					local nj = 0
					for _, jb in ipairs(self.jobs or {}) do
						if not jb.done then
							nj = nj + 1
						end
					end
					return tostring(nj)
				end)(),
			})[d]
			if d == "[" or d == "]" then
				i = i + 2 -- non-printing markers: drop
			elseif d == "l" then -- basename of the controlling tty, or "tty" when none (bash)
				local tn = C.isatty(0) == 1 and C.ttyname(0) or nil
				out[#out + 1] = tn ~= nil and (ffi.string(tn):gsub(".*/", "")) or "tty"
				i = i + 2
			elseif d == "w" or d == "W" then
				out[#out + 1] = pq(self, M.prompt_dir(self, d == "W"))
				i = i + 2
			elseif d == "u" then
				out[#out + 1] = os.getenv("USER") or "user"
				i = i + 2
			elseif d == "h" then
				out[#out + 1] = pq(self, (M.hostname():gsub("%..*$", "")))
				i = i + 2
			elseif d == "H" then
				out[#out + 1] = pq(self, M.hostname())
				i = i + 2
			elseif d == "D" and s:sub(i + 2, i + 2) == "{" then -- \D{strftime}
				local close = s:find("}", i + 3, true) or (#s + 1) -- (unclosed: the rest is the format)
				local fmt = s:sub(i + 3, close - 1)
				out[#out + 1] = pq(self, os.date(fmt ~= "" and fmt or "%X"))
				i = close + 1
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
-- `upper` == "toggle" swaps each char's case (${x~}/${x~~}).
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
	if lc_mb_cur_max <= 1 and any and upper ~= "toggle" then
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
			local w2
			if upper == "toggle" then -- ${x~}/${x~~}: swap case (sh_modcase CASE_TOGGLE)
				w2 = M.towupper(ch.wc)
				if w2 == ch.wc then
					w2 = M.towlower(ch.wc)
				end
			else
				w2 = upper and M.towupper(ch.wc) or M.towlower(ch.wc)
			end
			if w2 ~= ch.wc then
				s = M.wc_to_bytes(w2, ch.s)
			end
		end
		out[k] = s
	end
	return table.concat(out)
end
M.fold_case = fold_case
-- ${v:off:len} with a negative len that ends before off: bash's "substring expression < 0"
-- (naming the length as written, `ltxt`) abandons the line
local function substr_check(val, off, len, ltxt)
	local l = tonumber(len)
	if not l or l >= 0 then
		return
	end
	local n = M.mb_strlen(val)
	local o = tonumber(off) or 0
	if o < 0 then
		o = n + o
	end
	if o < 0 or o > n then
		return -- (an out-of-range offset is an empty result, checked first)
	end
	if n + l < o then
		io.stderr:write("curse: " .. (ltxt or len) .. ": substring expression < 0\n")
		error({ __curse_exit = 1, __curse_lineabort = true })
	end
end
function Shell:apply_str_op(op, val, arg, arg2, ltxt)
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
		if arg == "E" then -- like $'…' (ansiexpand: ansicstr flags 2), cut at a NUL
			if not val:find("\\", 1, true) then
				return val
			end
			local r = M.ansi_unescape(val, true)
			local z = r:find("\0", 1, true)
			return z and r:sub(1, z - 1) or r
		end
		return val
	end
	if op ~= "sub" and arg:find("(", 1, true) and not self.shopt.extglob then
		arg = M.glob_noext(arg) -- (extglob off: `+(b)` is literal text)
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
	if op == "/" or op == "//" then -- (nocasematch folds case here too, bash 5.2)
		arg2 = arg2 or ""
		local rx = self.shopt.patsub_replacement ~= false and M.repl_expands(arg2)
		return M.subst_glob(val, arg, arg2, op == "//", self.shopt.nocasematch, rx)
	end
	if op == "sub" then
		substr_check(val, arg, arg2, ltxt)
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
	if op == "~~" or op == "~" then
		return fold_case(val, arg, "toggle", op == "~~")
	end
	return val
end

-- Interpret backslash escapes for `echo -e` and ANSI-C `$'…'` quoting.
-- Encode a Unicode code point as UTF-8 bytes (for \u/\U in $'…', echo -e, printf).
function M.utf8_char(cp)
	if cp < 0x80 then
		return string.char(cp)
	elseif cp >= 0x80000000 then
		return "" -- (beyond what bash's u32toutf8 encodes)
	elseif not M.lc_utf8() then -- another charset (Big5, Latin-1…): convert, or spell it out
		ffi.fill(_mb_st, ffi.sizeof(_mb_st)) -- when the locale can't hold it (bash)
		local r = tonumber(C.wcrtomb(_mb_buf, cp, _mb_st))
		if r > 0 and r <= 16 then
			return ffi.string(_mb_buf, r)
		end
		return cp > 0xFFFF and ("\\U%08X"):format(cp) or ("\\u%04X"):format(cp)
	end
	-- UTF-8, with bash's 5- and 6-byte forms for code points past 0x1FFFFF
	local n, lead = 2, 0xC0
	if cp >= 0x4000000 then
		n, lead = 6, 0xFC
	elseif cp >= 0x200000 then
		n, lead = 5, 0xF8
	elseif cp >= 0x10000 then
		n, lead = 4, 0xF0
	elseif cp >= 0x800 then
		n, lead = 3, 0xE0
	end
	local b = {}
	for k = n, 2, -1 do
		b[k] = 0x80 + cp % 64
		cp = math.floor(cp / 64)
	end
	b[1] = lead + cp
	return string.char(unpack(b))
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
				else -- (TOCTRL: `?` is DEL; `\c\\` consumes the escaped backslash)
					out[#out + 1] = x == "?" and "\127" or string.char(x:upper():byte() % 32)
					i = i + 3
					if x == "\\" and s:sub(i, i) == "\\" then
						i = i + 1
					end
				end
			elseif d == "u" or d == "U" then -- \uXXXX / \UXXXXXXXX code point (echo -e and $'…')
				local hex = s:match(d == "u" and "^%x%x?%x?%x?" or "^%x%x?%x?%x?%x?%x?%x?%x?", i + 2)
				if hex then
					out[#out + 1] = M.utf8_char(tonumber(hex, 16))
					i = i + 2 + #hex
				else
					if mode == "b" then -- (printf %b warns, as bash's tescape)
						io.stderr:write("curse: printf: missing unicode digit for \\" .. d .. "\n")
					end
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
			elseif ansi_c and d == "'" then -- (only $'…' knows \' and \"; echo -e / %b keep them)
				out[#out + 1] = "'"
				i = i + 2
			elseif ansi_c and (d == '"' or d == "?") then
				out[#out + 1] = d
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
			elseif d == "x" and ansi_c and s:byte(i + 2) == 123 then -- $'\x{HHH…}' (strtrans.c): any
				-- number of hex digits, the low byte kept; the closing } is optional
				local hex = s:match("^%x*", i + 3)
				local c = 0
				for k = 1, #hex do
					c = (c * 16 + tonumber(hex:sub(k, k), 16)) % 256
				end
				out[#out + 1] = string.char(c)
				i = i + 3 + #hex
				if s:byte(i) == 125 then
					i = i + 1
				end
			elseif d == "x" then
				local hex = s:match("^%x%x?", i + 2)
				if hex then
					out[#out + 1] = string.char(tonumber(hex, 16))
					i = i + 2 + #hex
				else
					if mode == "b" then -- (printf %b warns, as bash's)
						io.stderr:write("curse: printf: missing hex digit for \\x\n")
					end
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
	local nonl, esc = false, self.shopt.xpg_echo and true or false -- (xpg_echo: -e by default)
	-- Build the output string. Fast paths avoid the {...} pack + buf table + concat that
	-- dominate echo's cost (and GC) — the common `echo "one string"` has no -neE flag and a
	-- single (quoted) arg, so it needs neither. Only a leading -flag or multiple args pay them.
	local s
	local first = nil
	if n >= 1 then
		first = select(1, ...)
	end
	-- (posix + xpg_echo: no options at all — `echo -n` prints `-n`, as bash)
	if type(first) == "string" and first:match("^%-[neE]+$") and not (esc and self.opt_posix) then
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
	local werr = false
	if self.out == io.write then
		local ok, m = io.flush()
		if not ok then
			werr, self.write_err, self.write_errmsg = true, true, m
			M.clear_stdout_err()
		end
	end
	self.status = werr and 1 or 0 -- a write error is status 1, like bash's sh_chkwrite
end

pcall(ffi.cdef, [[
  void curse_rt_clearerr(void *fp) asm("clearerr");
  extern void *curse_rt_stdout asm("stdout");
]])
pcall(ffi.cdef, "void tzset(void);")
function M.tzset()
	pcall(function()
		C.tzset()
	end)
end
-- after a failed write, stdout's sticky error flag must go, or every later flush fails too
function M.clear_stdout_err()
	pcall(function()
		C.curse_rt_clearerr(C.curse_rt_stdout)
	end)
end
-- The `echo` BUILTIN (compiled call sites): Shell:echo, then bash's sh_chkwrite report
-- of a failed write. (Other builtins print through Shell:echo silently.)
function Shell:echo_cmd(...)
	self.write_err = nil
	self:echo(...)
	if self.write_err and self.out == io.write then
		M.chkwrite_report(self, "echo", self.write_errmsg)
	end
end
-- …and $_ = its last argument (for a program that reads $_)
function Shell:echo_cmd_u(...)
	local n = select("#", ...)
	self:echo_cmd(...)
	self:set_str("_", n > 0 and (select(n, ...)) or "echo")
end
-- bash's sh_chkwrite: flush a builtin's output; a failure (full disk, a read-only fd) is
-- reported as `NAME: write error: REASON` and flagged (the command's status becomes 1).
-- Returns true when the write went through.
function M.chkwrite(sh, name)
	local ok, m = io.flush()
	if ok then
		return true
	end
	M.clear_stdout_err()
	M.chkwrite_report(sh, name, m)
	return false
end
do
	-- builtins whose output goes out through Shell:echo, then bash's sh_chkwrite
	local CHKW = { declare = 1, typeset = 1, export = 1, readonly = 1, trap = 1, umask = 1,
		times = 1, dirs = 1, help = 1, cd = 1 }
	-- after a builtin flagged a write error: status 1, and the report if nothing made it yet
	function M.chkwrite_late(sh, name)
		sh.status = 1
		if sh.write_errmsg and CHKW[name] then
			M.chkwrite_report(sh, name, sh.write_errmsg)
		end
	end
end
function M.chkwrite_report(sh, name, m)
	sh.write_err, sh.write_errmsg = true, nil -- (reported: chkwrite_late's cue)
	local why = (m or ""):match(":%s*([^:]+)$") or m or "Bad file descriptor"
	io.stderr:write("curse: " .. name .. ": write error: " .. why .. "\n")
end

-- Builtin registry (name -> lazily-loaded module). The interpreter shares this
-- table (interp aliases rt.BUILTIN_LAZY), so there is one source of truth.
local BUILTIN_LAZY = {
	echo = "b_echo",
	enable = "b_enable",
	caller = "b_caller",
	disown = "b_fg",
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
	fg = "b_fg",
	bg = "b_fg",
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
	logout = "b_logout",
	suspend = "b_suspend",
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
-- builtins that need a real process when run inside an in-process subshell/$(…) (their
-- effect is process-global: fds/process image, rlimits, signal dispositions, the builtin
-- table, waiting on the subshell's own children) — shared with interp's dispatch
-- Builtins that change process-global state: inside an in-process subshell, save that
-- state first (put back when the subshell ends).
M.ISO_BUILTIN = {
	exec = function(sh)
		M.iso_save_fds(sh)
		M.iso_save_env(sh)
	end,
	ulimit = M.iso_save_rlimits,
	trap = M.iso_save_traps,
}
-- POSIX "special built-in utilities" (bash's SPECIAL_BUILTIN flag, `enable -s`): found
-- before functions under `set -o posix`, a prefix assignment on one persists, and an error
-- in one ends a non-interactive posix shell (M.spb_run).
M.SPECIAL_BUILTIN = {
	[":"] = 1, ["."] = 1, source = 1, eval = 1, exec = 1, exit = 1, export = 1, readonly = 1,
	["set"] = 1, shift = 1, times = 1, trap = 1, unset = 1, ["break"] = 1, ["continue"] = 1,
	["return"] = 1,
}
-- A special builtin run directly (not through `command`/`builtin`) by a non-interactive
-- posix shell (execute_cmd.c execute_simple_command / execute_command_internal). A builtin
-- flags its special failure in sh.spb_err: 1 for bash's EX_BADASSIGN / EX_REDIRFAIL /
-- EX_EXPFAIL, which exit at once with status 1 whatever the context; 2 for EX_USAGE (and
-- the other > EX_SHERRBASE codes), which set special_builtin_failed: the shell exits after
-- the command, status 2 — unless its status is ignored (a condition, a non-final &&/||
-- operand, or the command itself negated with `!`). A plain failure (status 1) goes on.
function M.spb_run(sh, run, a1, a2, a3, a4)
	local neg = sh.spb_neg -- (`! cmd`: consumed by the first special builtin it dispatches)
	sh.spb_neg = nil
	sh.spb_err = nil
	run(a1, a2, a3, a4)
	local e = sh.spb_err
	if e then
		sh.spb_err = nil
		M.spb_exit(sh, e, neg)
	end
end
-- A special builtin's redirection failed (EX_REDIRFAIL): fatal to a non-interactive posix
-- shell, else just the failure (false) — the compiled tier's twin of interp's run_cmd check.
function M.spb_redir(sh, rs)
	if sh.opt_posix and not sh.opt_i then
		M.redir_restore(rs)
		sh.status = 1
		error({ __curse_exit = 1 })
	end
	return false
end
-- (eval/source/. clear any flag left by the code they ran: only their own error counts)
function M.spb_exit(sh, e, neg) -- (also exec's, which interp runs outside exec_simple)
	if e == 1 then
		sh.status = 1
		error({ __curse_exit = 1 })
	elseif sh.noerr == 0 and not neg then
		sh.status = 2
		error({ __curse_exit = 2 })
	end
end
function M.builtin(sh, argv, hook)
	if sh.opt_posix and M.SPECIAL_BUILTIN[argv[1]] and not sh.opt_i then
		return M.spb_run(sh, M.builtin_run, sh, argv, hook)
	end
	return M.builtin_run(sh, argv, hook)
end
function M.builtin_run(sh, argv, hook)
	local cmd = argv[1]
	if sh.functions[cmd] then
		return require("interp").exec_simple(sh, argv, hook or _noop)
	end
	local prep = M.ISO_BUILTIN[cmd]
	if prep then
		prep(sh)
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
-- Does a builtin's own write to a prefix-assigned variable outlive the command? In bash
-- (execute_builtin) the tempenv of source/eval/unset/mapfile/fc/read is a scope of its own,
-- dropped afterwards; any other builtin's bind_variable reaches the variable beneath, so
-- `x=2 printf -v x 9` leaves x=9 (getopts, let too). declare/local/typeset absorb theirs.
do
	local SCOPED = { source = true, ["."] = true, eval = true, unset = true, mapfile = true,
		readarray = true, fc = true, read = true, declare = true, typeset = true, ["local"] = true }
	function M.prefix_keeps(sh, argv)
		local k, cmd = 1, argv and argv[1]
		while (cmd == "command" or cmd == "builtin") and argv[k + 1] do
			k = k + 1
			cmd = argv[k]
			if cmd:sub(1, 1) == "-" then
				return false
			end
		end
		return cmd ~= nil and not SCOPED[cmd] and not sh.functions[cmd]
			and require("interp")._int.BUILTINS[cmd] ~= nil
	end
end
function M.run_prefix(sh, names, vals, runfn, argv)
	local base = #sh.tenv
	for i = 1, #names do
		local name = names[i]
		local rb = sh.vars[name]
		if rb and rb.ref and rb.s and rb.s:match("^[%a_][%w_]*$") and sh:deref(name) ~= "" then
			name = sh:deref(name) -- (through a nameref with a target: the target's binding)
		end
		local b = sh.vars[name] -- copy the box: set_str below mutates in place
		sh.vseq = sh.vseq + 1
		sh.tenv[#sh.tenv + 1] = {
			name = name,
			env = os.getenv(name),
			consumed = false,
			seq = sh.vseq,
			box = b
					and { s = b.s, n = b.n, arr = b.arr, assoc = b.assoc, order = b.order, exported = b.exported, ro = b.ro, ref = b.ref,
						int = b.int, lower = b.lower, upper = b.upper, cap = b.cap, trace = b.trace }
				or false,
		}
		-- a NAMEREF's prefix binding is a plain temporary (target untouched), and so is an
		-- -i/-l/-u/-c var's (bash's tempenv variable is a plain string: `i=1+1 cmd` gets "1+1")
		if b and (b.ref or ((b.int or b.lower or b.upper or b.cap) and not b.arr and not b.ro)) then
			sh.vars[name] = {}
		end
		sh:set_str(name, vals[i])
		C.setenv(name, sh:get(name), 1)
		sh.tenv[#sh.tenv].tval = sh:get(name) -- (to see whether the command wrote it: prefix_keeps)
		local nb = sh.vars[sh:deref(name)] -- (in the environment: `declare -p` shows -x)
		if nb then
			nb.exported = true
		end
	end
	sh.tenv_call_base = base -- a DIRECT function call tags these with its frame (local absorption)
	local ok, err = pcall(runfn)
	sh.tenv_call_base = nil
	local relocale = false
	local keeps = argv and M.prefix_keeps(sh, argv)
	for k = #sh.tenv, base + 1, -1 do
		local s = sh.tenv[k]
		sh.tenv[k] = nil
		if not s.consumed then -- an `unset` inside the command already revealed it
			local nv = keeps and sh:get(s.name)
			sh.vars[s.name] = s.box or nil
			if s.env then
				C.setenv(s.name, s.env, 1)
			else
				C.unsetenv(s.name)
			end
			if nv and nv ~= s.tval then -- (the builtin's write reached the variable beneath)
				sh:set_str(s.name, nv)
			end
			relocale = relocale or LOCALE_VARS[s.name] ~= nil
		end
	end
	if relocale then -- (`LC_CTYPE=C cmd`: the locale follows the variable back)
		M.reset_locale(sh)
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
		M.xtrace(sh, argv)
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
	if sh.opt_posix and not sh.opt_i then -- (a special builtin: M.spb_run)
		return M.spb_run(sh, M.eval_run, sh, argv)
	end
	return M.eval_run(sh, argv)
end
function M.eval_run(sh, argv)
	local a2 = argv[2]
	if a2 and a2 ~= "-" and a2 ~= "--" and a2:sub(1, 1) == "-" then
		return require("b_eval")(sh, "eval", argv, _noop, nil) -- (the usage error: b_eval's)
	end
	local start = (a2 == "--") and 3 or 2
	local code = table.concat({ unpack(argv, start) }, " ")
	if not code:match("%S") then
		sh.status = 0
		return
	end
	local ln = current_line(sh)
	local mod = require("tier").try_fragment(code, ln > 0 and ln or nil)
	if mod then
		require("tier").run_compiled(mod, sh, nil, true)
		sh.spb_err = nil -- (a builtin the code ran flagged its own: not eval's)
	else
		require("b_eval")(sh, "eval", argv, _noop, nil) -- (a hook: a called function asks it)
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
		local k, p, hashed = I.name_type(sh, argv[j])
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
					sh:echo(argv[j] .. (hashed and " is hashed (" .. p .. ")" or " is " .. p))
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
			elseif k == "alias" then
				sh:echo("alias " .. argv[j] .. "='" .. sh.aliases[argv[j]] .. "'")
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
-- `source`'s call frame (bash): ${BASH_SOURCE[0]} is the file as named, BASH_LINENO gets
-- the `source` line, FUNCNAME gains "source" (shown only inside a function). Shared by both tiers.
function M.source_enter(sh, name, line) -- line: the `source` command's (else found on the stack)
	local fr = { src = sh.cur_source, line = sh.cur_line }
	sh.srcstack = sh.srcstack or {}
	table.insert(sh.srcstack, 1, sh.cur_source or sh.argv0 or "")
	sh.linestack = sh.linestack or {}
	table.insert(sh.linestack, 1, line or (current_line(sh)))
	sh.funcstack = sh.funcstack or {}
	table.insert(sh.funcstack, 1, "source") -- (FUNCNAME shows it only inside a function)
	fr.fn = true
	sh.cur_source = name
	return fr
end
function M.source_leave(sh, fr)
	table.remove(sh.srcstack, 1)
	table.remove(sh.linestack, 1)
	if fr.fn then
		table.remove(sh.funcstack, 1)
	end
	sh.cur_source, sh.cur_line = fr.src, fr.line
end
-- The file `.`/source reads for NAME (bash's source.def): a name with a slash as is;
-- else, with shopt sourcepath (the default), the first regular file of that name in
-- $PATH; else (or with none found) the name itself, in the current directory.
function M.source_path(sh, name)
	if not name:find("/", 1, true) and sh.shopt.sourcepath ~= false then
		local file_test = require("interp")._int.file_test
		for dir in (sh:get("PATH") .. ":"):gmatch("([^:]*):") do
			local cand = (dir == "" and "." or dir) .. "/" .. name
			if file_test("-f", cand) then
				return cand
			end
		end
	end
	return name
end
-- A file with no commands (blank or comments only): sourcing it sets $? to 0
function M.source_empty(code)
	return not code:gsub("#[^\n]*", ""):find("%S")
end
function M.source(sh, argv, line)
	if sh.opt_posix and not sh.opt_i then -- (a special builtin: M.spb_run)
		return M.spb_run(sh, M.source_run, sh, argv, line)
	end
	return M.source_run(sh, argv, line)
end
function M.source_run(sh, argv, line)
	local I = require("interp")
	local Ii = I._int
	local j = 2
	if argv[j] == "--" then
		j = j + 1
	end
	local name = argv[j]
	if not name or (j == 2 and name:match("^%-.")) then
		return require("b_source")(sh, argv[1], argv, nil, nil) -- usage error: let b_source diagnose
	end
	local file = M.source_path(sh, name)
	if Ii.file_test("-d", file) then
		return require("b_source")(sh, argv[1], argv, nil, nil) -- directory: b_source diagnoses
	end
	local f = M.open_read(file)
	if not f then
		return require("b_source")(sh, argv[1], argv, nil, nil) -- not found: b_source diagnoses
	end
	local code = f:read("*a")
	f:close()
	-- (a DEBUG trap that reaches into the file — functrace — needs per-command hooks the
	-- file's own compile doesn't have: the interpreter runs it then)
	local dbg_in = sh.opt_functrace and sh.traps and sh.traps.DEBUG and sh.traps.DEBUG ~= ""
	local mod = not dbg_in and not M.source_empty(code) and require("tier").try_fragment(code)
	if not mod then -- alias / syntax error / uncompilable / empty: b_source runs the text it was handed
		-- (never re-opening the file — a FIFO or /dev/stdin can only be read once)
		sh.source_preread = { file = file, code = code }
		return require("b_source")(sh, argv[1], argv, nil, nil)
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
	local ownp = sh.params -- (a `set --` in the file replaces this table)
	sh.sourcedepth = (sh.sourcedepth or 0) + 1 -- a `return` is valid while sourcing
	local fr = M.source_enter(sh, name, line)
	local dsave, e0 = M.source_debug_hide(sh), sh.traps and sh.traps.ERR
	local rok, err = pcall(require("tier").run_compiled, mod, sh, nil, true)
	sh.spb_err = nil -- (a builtin in the file flagged its own: not the source's)
	M.source_leave(sh, fr)
	sh.sourcedepth = sh.sourcedepth - 1
	-- (params the file SET itself stay — but not inside a function: bash's maybe_pop_dollar_vars)
	if #argv > j and (sh.params == ownp or sh:in_function()) then
		sh.params, sh.nparams = savep, savenp
	end
	local rret -- (`return N` doesn't set $? — the RETURN trap sees the status before it)
	if not rok then
		if type(err) == "table" and err.__curse_return then
			rret = err.__curse_return
		else
			M.source_debug_restore(sh, dsave)
			error(err) -- exit / break / continue propagate
		end
	end
	-- `.`/source fires the RETURN trap on return (any outcome but the usage error).
	local trap = sh.traps and sh.traps.RETURN
	if trap and trap ~= "" and not sh.in_return_trap and M.pseudo_trapped(sh, "RETURN") then
		sh.in_return_trap = true
		local sv = sh.status
		Ii.run_trap(sh, trap)
		sh.status = sv
		sh.in_return_trap = false
	end
	if rret then
		sh.status = rret
	end
	M.source_debug_restore(sh, dsave)
	M.source_err_sample(sh, e0)
end
-- A sourced file isn't traced by the DEBUG trap (nor is its RETURN trap run) unless
-- functrace is on, like a function body (bash).
function M.source_debug_hide(sh)
	local d = sh.traps and sh.traps.DEBUG
	if d ~= nil and not sh.opt_functrace then
		sh.traps.DEBUG = nil
		return d
	end
end
function M.source_debug_restore(sh, d)
	if d ~= nil and sh.traps.DEBUG == nil then
		sh.traps.DEBUG = d
	end
end
-- bash samples the ERR trap BEFORE a command runs (execute_cmd.c was_error_trap): a `.`
-- whose file set the trap (e0: the one before it) doesn't fire it for its own failure.
function M.source_err_sample(sh, e0)
	if e0 == nil and sh.traps and sh.traps.ERR and sh.status ~= 0 and sh.noerr == 0 then
		sh.err_skip = true
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
	if sh.opt_x and not no_func then -- (`command CMD`: the caller traced it, `command` included)
		M.xtrace(sh, argv)
	end
	-- a `cmd &` child armed to exec its lone external in place: only if the word resolved
	-- to an external (a function/builtin runs more than one command — keep the child)
	if sh.exec_tail and (sh.functions[argv[1]] or I.BUILTINS[argv[1]] or (sh.aliases and sh.aliases[argv[1]])) then
		sh.exec_tail = nil
	end
	-- `exec` is a STATEMENT-level builtin in the interpreter (it rewires/replaces the process),
	-- which exec_simple doesn't dispatch: run the already-expanded words as a quoted-literal
	-- statement through exec_stmt (`c=exec; $c cmd`).
	if argv[1] == "exec" and (no_func or not sh.functions.exec) then
		local words = {}
		for i = 1, n do
			words[i] = { k = "word", parts = { { lit = argv[i], q = true } } }
		end
		I.exec_stmt(sh, { t = "simple", words = words, line = sh.cur_line }, hook or _noop)
	elseif no_func then
		-- the `command` prefix: run argv skipping SHELL FUNCTION lookup (builtin/external only),
		-- a special builtin losing its fatal errors (interp's command builtin: via_command)
		local svc = sh.via_command
		sh.via_command = true
		local ok, err = pcall(I.exec_simple, sh, argv, hook or _noop, no_func)
		sh.via_command = svc
		if not ok then
			error(err, 0)
		end
	else
		I.exec_simple(sh, argv, hook or _noop, no_func)
	end
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
-- (only forms that can't fail: `08`, `2#44`, `0#4`… take the validating parse, which
-- reports bash's errors)
function M.looks_numeric(s)
	return s:match("^%s*[+-]?[1-9]%d*%s*$")
		or s:match("^%s*[+-]?0%s*$")
		or s:match("^%s*[+-]?0[xX]%x+%s*$")
		or s:match("^%s*[+-]?0[0-7]+%s*$")
end
local _acache = {} -- value-string -> compiled fn(sh) | false (uncompilable; keep the seam)
function M.arith_read(sh, name)
	local b = sh.vars[name]
	if b and not b.ref and not b.arr then -- (a plain scalar: its int64, or a plain decimal)
		local n = b.n
		if n ~= nil then
			return n
		end
		local bs = b.s
		if bs and short_digits(bs) and (bs:byte(1) ~= 48 or #bs == 1) then -- (010 is octal)
			return i64(tonumber(bs))
		end
	end
	local s = sh:get(name)
	if s ~= nil and M.looks_numeric(s) then
		return M.arith_num(s)
	end -- native fast path
	local P = require("parser")
	if sh.in_arithcmd and P.arith_cmd == nil then -- (a compiled `(( ))`: its errors say `((: `)
		P.arith_cmd = "(("
		local ok, v = pcall(M.arith_read_slow, sh, name, s)
		P.arith_cmd = nil
		if not ok then
			error(v, 0)
		end
		return v
	end
	return M.arith_read_slow(sh, name, s)
end
function M.arith_read_slow(sh, name, s)
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
			-- Mirror arith_read∘arith_resolve exactly: a depth guard (bash's expression
			-- recursion limit, 1024 as interp's arith_resolve, shared via sh.arith_depth),
			-- a nested bad value swallowed to 0, and a real matherr/experr mapped to a
			-- non-fatal $?=1 inside (( )) (sh.arithfault flag) or a line-abort in a word $((…)).
			local ok, v = pcall(function()
				if (sh.arith_depth or 0) >= 1024 then -- (said by the outermost level, below)
					error({ __curse_exit = 1, __curse_matherr = true, __curse_experr = true, __curse_lineabort = true,
						__curse_recur = s })
				end
				sh.arith_depth = (sh.arith_depth or 0) + 1
				local ok2, r = pcall(fn, sh)
				sh.arith_depth = sh.arith_depth - 1
				if not ok2 then
					if type(r) == "table" and (r.__curse_experr or r.__curse_matherr or r.__curse_unbound) then
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
				if v.__curse_recur then
					if (sh.arith_depth or 0) > 0 then
						error(v, 0) -- (up to the outermost read, where the line is still known)
					end
					io.stderr:write("curse: " .. require("parser").arith_errmsg(v.__curse_recur,
						{ msg = "expression recursion level exceeded", tok = v.__curse_recur }) .. "\n")
					v.__curse_recur = nil
				end
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
-- [[ … -eq … ]] operands (compiled): arith_str, but an arith error flags sh.db_err (the
-- comparison's enclosing rt.db_ok turns THAT primary false) instead of unwinding — no pcall
-- on the fast path. Once flagged, the right operand is not evaluated (bash's arithcomp).
function M.db_arith(sh, s)
	if sh.db_err then
		return i64(0)
	end
	if M.looks_numeric(s) then
		return M.arith_num(s)
	end
	local ok, v = pcall(require("interp").dbracket_arith, sh, s)
	if ok then
		return v
	end
	if type(v) == "table" and v.__curse_matherr and not v.__curse_subscript then -- (a
		sh.db_err = true -- subscript's error abandons the line instead)
		return i64(0)
	end
	error(v, 0)
end
function M.db_ok(sh, b)
	if sh.db_err then
		sh.db_err = nil
		return false
	end
	return b
end
-- bash's $RANDOM (lib/sh/random.c): the Park–Miller minimal standard LCG, 16-bit folded,
-- never repeating the previous value; `RANDOM=n` seeds it; a subshell reseeds on first use.
local function intrand32(last)
	local r = (last == 0) and 123459876 or last
	local h = math.floor(r / 127773)
	local l = r - 127773 * h
	local t = 16807 * l - 2836 * h
	return t < 0 and t + 0x7fffffff or t
end
function M.random_seed(sh, v)
	sh.rseed = v % 4294967296
	sh.rlast = 0
	sh.rpid = tonumber(ffi.C.getpid())
end
local reseeds = 0
function M.random_next(sh)
	local pid = tonumber(ffi.C.getpid())
	if sh.rpid ~= pid then -- first use in this process (startup, or a forked subshell)
		reseeds = reseeds + 1 -- (two subshells seeded in the same microsecond still differ)
		sh.rseed = (os.time() * 1000003 + pid * 7919 + math.floor(os.clock() * 1e6) + reseeds * 104729) % 2147483647
		sh.rlast = 0
		sh.rpid = pid
	end
	local rv
	repeat
		sh.rseed = intrand32(sh.rseed)
		rv = bit.band(bit.bxor(bit.rshift(sh.rseed, 16), bit.band(sh.rseed, 65535)), 32767)
	until rv ~= sh.rlast
	sh.rlast = rv
	return rv
end
-- Does arithmetic text assign a variable it ALSO reads as `$name`? bash expands every
-- $name before evaluating, so an in-order native read could see the new value; such an
-- expression takes the textual path (`x=x[1], x[1]=$x`). `sum += $i` stays native.
function M.xpand_self_assign(raw)
	for nm in raw:gmatch("%$([%a_][%w_]*)") do
		local f = "%f[%w_]" .. nm
		if raw:find(f .. "%s*[%+%-%*/%%&|%^]?=[^=]") or raw:find(f .. "%s*<<=") or raw:find(f .. "%s*>>=")
			or raw:find(f .. "%s*%[[^%]]*%]%s*[%+%-%*/%%&|%^]?=[^=]")
			or raw:find(f .. "%s*%+%+") or raw:find(f .. "%s*%-%-")
			or raw:find("%+%+%s*" .. nm .. "%f[^%w_]") or raw:find("%-%-%s*" .. nm .. "%f[^%w_]") then
			return true
		end
	end
	return false
end
function M.arith_str(sh, s)
	if s == "" then
		return i64(0)
	end
	if M.looks_numeric(s) then
		return M.arith_num(s)
	end
	local fn = _acache[s]
	if fn == nil then
		local cok, f = pcall(require("emit").compile_arith_value, s)
		fn = cok and f or false
		_acache[s] = fn
	end
	if fn then
		return fn(sh)
	end
	return require("interp").arith_eval_str(sh, s)
end
-- The value of an INTEGER variable's assignment (declare -i): `s` evaluated by `ev`
-- (default arith_str). bash's bind_variable evaluates it with evalexp, and a failure
-- there is top_level_cleanup + jump_to_top_level(DISCARD) (variables.c): the whole
-- TOP-LEVEL command is abandoned — every function, eval and source level unwinds
-- (`__curse_discard`: those builtins don't contain it), a subshell exits 1, $? is 1,
-- and neither set -e nor posix mode makes it fatal. A plain decimal takes no pcall.
function M.int_value(sh, s, ev)
	if short_digits(s) and (s:byte(1) ~= 48 or #s == 1) then -- (010 is octal)
		return M.arith_num(s)
	end
	local ok, v = pcall(ev or M.arith_str, sh, s)
	if ok then
		return v
	end
	if type(v) == "table" and (v.__curse_matherr or v.__curse_experr) then
		sh.status = 1
		error({ __curse_exit = 1, __curse_lineabort = true, __curse_discard = true }, 0)
	end
	error(v, 0)
end
-- int_value inside a builtin (declare/local/export/readonly): its errors name the builtin
-- (bash's this_command_name: `declare: 3 x: syntax error …`)
function M.int_value_as(sh, cmd, s, ev)
	if short_digits(s) and (s:byte(1) ~= 48 or #s == 1) then
		return M.arith_num(s)
	end
	local P = require("parser")
	local sv = P.arith_cmd
	P.arith_cmd = cmd
	local ok, v = pcall(M.int_value, sh, s, ev)
	P.arith_cmd = sv
	if not ok then
		error(v, 0)
	end
	return v
end

-- ${v:off:len} / ${a[@]:off:len} offset/length: arith-evaluate the already-expanded
-- string STRICTLY, like bash — an error names the variable (`HOME: }: syntax error:
-- operand expected …`) and abandons the command's line. Returns a Lua number, or nil for
-- empty/nil input (the caller coerces nil->0 for a present operand).
-- the parameter as bash names it in such errors: `a[@]`, `a[0]`, `HOME`
function M.pe_label(pe)
	return pe.index and (pe.name .. "[" .. pe.index .. "]") or pe.name
end
-- ${name:off:len} of an UNSET plain variable expands to nothing without evaluating off/len
-- (parameter_brace_substring returns before verify_substring_values): `${x:1/0}` is silent.
-- (set -u keeps its unbound error: not skipped then)
function M.sub_unset(sh, name)
	if sh.opt_u or not name:match("^[%a_][%w_]*$") then
		return false
	end
	local b = sh.vars[sh:deref(name)]
	return (b == nil or (b.arr == nil and b.s == nil and b.n == nil)) and sh:special_get(name) == ""
end
function M.substr_arith(sh, name, s)
	if s == nil or s == "" then
		return nil
	end
	if M.looks_numeric(s) then
		return tonumber(M.arith_num(s))
	end
	local P = require("parser")
	local sv = P.arith_cmd
	P.arith_cmd = name
	local ok, v = pcall(M.arith_str, sh, s)
	P.arith_cmd = sv
	if not ok then
		if type(v) == "table" and v.__curse_matherr then
			error({ __curse_exit = 1, __curse_lineabort = true })
		end
		error(v, 0)
	end
	return tonumber(v)
end
-- `[[ -v NAME ]]` / `[[ -v a[i] ]]`: is the variable (or array element) set? interp's
-- var_is_set twin. `nm` is already word-expanded, so an array subscript is a plain literal
-- (no $): an ASSOC key is used verbatim, an INDEXED subscript is arith-evaluated via
-- rt.arith_str (native; a nested-subscript operand defers through arith_str's seam). A
-- bare array name tests element 0 (like bash); a digit is a positional parameter.
-- test's -R (test.c unary_test 'R'): find_variable_noref — the name ITSELF is a set nameref.
function M.var_is_nameref(sh, nm)
	local b = sh.vars[nm]
	return b ~= nil and b.ref and b.s ~= nil or false
end
function M.var_is_set(sh, nm, expanded)
	local base, sub = nm:match("^([%a_][%w_]*)%[(.+)%]$")
	if base then
		local b = sh.vars[sh:deref(base)]
		if (sub == "@" or sub == "*") and not sh:is_assoc(base) then -- `-v a[@]`: any element
			-- (an ASSOCIATIVE array's `m[@]` is the literal key "@" — bash)
			if b and b.arr then
				return next(b.arr) ~= nil
			end
			return b ~= nil and (b.s ~= nil or b.n ~= nil)
		end
		local key
		if sh:is_assoc(base) then
			-- an associative subscript is word-expanded (`test -v 'm[$k]'` looks up $k's value)
			-- — except in [[ -v ]], whose word was expanded already (`expanded`): literal then
			key = sub
			if not (expanded or sh.shopt.assoc_expand_once) and sub:find("[$`\\'\"]") then
				key = require("interp")._int.array_key(sh, base, sub)
			end
		else
			key = M.to_arr_key(M.arith_str(sh, sub))
		end
		if M.neg_oob(sh, base, key) then -- (negative counts from the end; before the start: bash's
			io.stderr:write("curse: " .. base .. ": bad array subscript\n") -- get_array_value error)
			return false
		end
		return sh:is_elem_set(base, key)
	end
	local pn = (nm:byte(1) or 65) < 65 and M.legal_i64(nm) -- positional: any legal_number (test.c `-v n`)
	if pn then
		return pn >= 0 and pn <= sh.nparams
	end
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
-- A ${x:=w} / ${a[i]=w} whose assignment fails (a readonly target, or a bad array
-- subscript): parameter_brace_expand_rhs's expansion error — the line is discarded with
-- $? = 2 (EX_BADUSAGE; parse_and_execute callers — eval, source, -c, $(…) — report 1),
-- or under posix the shell exits.
function M.assign_default_fail(sh, what, msg)
	io.stderr:write("curse: " .. what .. ": " .. msg .. "\n")
	if sh.opt_posix then
		error({ __curse_exit = 1 })
	end
	error({ __curse_exit = 1, __curse_lineabort = true, __curse_badusage = true })
end
function M.assign_default(sh, name, v)
	local dn = sh:deref(name)
	local b = sh.vars[dn]
	if b and b.ro and not (sh.vars[name] or b).ref then
		M.assign_default_fail(sh, dn, "readonly variable")
	end
	-- through the var's attributes (declare -i / -u / -l): the expansion is the STORED value
	M.assign_scalar(sh, name, v)
	return sh:get(name)
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
	local sep = M.ifs_sep(sh)
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
-- has bash's :0==:1 off-by-one). A negative length is a line-aborting expansion error.
function M.array_slice_values(sh, name, els, off, len, ltxt)
	off = off or 0
	if len ~= nil and len < 0 then
		-- (bash's verify_substring_values: an offset past the end is just empty — checked
		-- before the length; $@ counts $0, an indexed array is its highest index)
		local pos = name == "@" or name == "*"
		if not pos and #els == 0 then
			return {}
		end
		local total
		if pos then
			total = sh.nparams + 1
		elseif sh:is_assoc(name) then
			total = #els
		else
			local idx = sh:array_indices(name)
			total = idx[#idx] ~= nil and tonumber(key_i64(idx[#idx])) or 0
		end
		local o = off < 0 and off + total or off
		if o < 0 or o > total then
			return {}
		end
		io.stderr:write("curse: " .. (ltxt or len) .. ": substring expression < 0\n")
		error({ __curse_exit = 1, __curse_lineabort = true })
	end
	if name ~= "@" and name ~= "*" then
		-- a SCALAR through [@]/[*] slices its value as a string (`${v[@]:3}` = ${v:3})
		local b = sh.vars[sh:deref(name)]
		if b and b.arr == nil and b.s ~= nil then
			return { substr(b.s, off, len) }
		end
	end
	if name ~= "@" and name ~= "*" and not sh:is_assoc(name) then
		local idx = sh:array_indices(name)
		if off >= 9.2233720368547758e18 then
			off = 0x7fffffffffffffffLL -- (a double at 2^63 would wrap converting to int64)
		end
		if off < 0 then -- (int64: an index can be up to 2^63-1, beyond a double's exactness)
			off = (idx[#idx] ~= nil and key_i64(idx[#idx]) or i64(-1)) + 1 + off
		end
		local out = {}
		if off >= 0 then -- an out-of-bounds negative offset (off < 0 here) is empty
			for i = 1, #idx do
				if key_i64(idx[i]) >= off then
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
	if last > n then
		last = n -- (a huge length must not drive the loop past the elements)
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
	if op == "-R" then
		return sh and M.var_is_nameref(sh, x) or false
	end
	return M.file_test(op, x) -- -e/-f/-d/-r/-w/-x/-s…
end
-- `test` numeric operands are plain DECIMAL integers (leading 0 is NOT octal; 0x/N#/arith
-- rejected) — an invalid one is a syntax error.
local function test_int(s)
	if short_digits(s) then -- (plain decimal: leading 0 is
		return i64(tonumber(s)) -- still decimal for test)
	end
	local n = M.legal_i64(s) -- (bash's legal_number: exact int64, base 10, ERANGE rejected)
	if not n then
		error({ __test_syntax = ("%s: integer expression expected"):format(s) })
	end
	return n
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
-- `locale`: [[ ]] orders < / > by LC_COLLATE; test / [ by plain byte (ASCII) order (bash)
local function test_binary(x, op, y, locale)
	if op == "=" or op == "==" then
		return x == y
	end
	if op == "!=" then
		return x ~= y
	end
	if op == "<" then
		if locale then
			return M.coll_lt(x, y)
		end
		return x < y
	end
	if op == ">" then
		if locale then
			return M.coll_lt(y, x)
		end
		return y < x
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
-- a test/[ syntax error: bash's `test: a: binary operator expected` (status 2)
local function test_error(sh, args, e)
	if type(e) == "table" and e.__test_syntax then
		io.stderr:write("curse: " .. args[1] .. ": " .. e.__test_syntax .. "\n")
	end
	sh.status = 2
end
local function do_test(sh, args)
	local lo, hi = 2, #args
	if args[1] == "[" then
		if args[hi] ~= "]" then
			return test_error(sh, args, { __test_syntax = "missing `]'" })
		end
		hi = hi - 1
	end
	local n = hi - lo + 1
	-- Fast path: 0-3 args need no recursive parser (no closures, no allocation).
	if n <= 3 then
		local ok, v = pcall(test_simple, sh, args, lo, n)
		if not ok then
			return test_error(sh, args, v)
		end
		sh.status = v and 0 or 1
		return
	end
	-- four args (POSIX, as bash): `! A B C` negates the three-arg test, `( A B )` is the
	-- two-arg one; otherwise the full expression parser
	if n == 4 and (args[lo] == "!" or (args[lo] == "(" and args[hi] == ")")) then
		local neg = args[lo] == "!"
		local ok, v = pcall(test_simple, sh, args, lo + 1, neg and 3 or 2)
		if not ok then
			return test_error(sh, args, v)
		end
		if neg then
			v = not v
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
			if args[pos] ~= ")" then -- (whatever came instead is named — for `[` even its `]`)
				local f = args[pos]
				error({ __test_syntax = f and ("`)' expected, found " .. f) or "`)' expected" })
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
			if args[pos] == "-t" and not M.legal_i64(args[pos + 1]) then
				pos = pos + 1 -- (test.c unary_operator: `-t` takes its operand only if it is a
				return false -- number; else it is false and the word is left for the parser)
			end
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
			if pos <= hi then -- (a leftover `-op` is named: bash's test.c)
				local left = args[pos] or ""
				error({ __test_syntax = left:sub(1, 1) == "-" and ("syntax error: `" .. left .. "' unexpected")
					or "too many arguments" })
			end
			return v
		end
	end)
	if not ok then
		return test_error(sh, args, res)
	end
	sh.status = res and 0 or 1
end
M.test_unary, M.test_binary, M.test_int = test_unary, test_binary, test_int
M.TEST_BINOPS, M.TEST_UNOPS, M.do_test = TEST_BINOPS, TEST_UNOPS, do_test
-- A compiled `[ A -op B ]` whose operand is a plain (non-lifted) variable: its value as an
-- int64 when it is a plain decimal (the common case: a native compare), else its fields
-- exactly as the generic path expands them (unquoted: word-split), for do_test.
function M.test_opnd(sh, name, quoted)
	local v = M.nameref_read(sh, name)
	if short_digits(v) then
		return i64(tonumber(v))
	end
	if quoted then
		return { v }
	end
	return M.field_split(sh, v, true)
end
function M.test_opnd_param(sh, n, quoted, braced) -- (test_opnd for $n: sh:param_u, as words)
	local v = sh:param_u(n, braced)
	if short_digits(v) then
		return i64(tonumber(v))
	end
	if quoted then
		return { v }
	end
	return M.field_split(sh, v, true)
end
local TEST_CMP = {
	["-eq"] = function(a, b) return a == b end,
	["-ne"] = function(a, b) return a ~= b end,
	["-lt"] = function(a, b) return a < b end,
	["-le"] = function(a, b) return a <= b end,
	["-gt"] = function(a, b) return a > b end,
	["-ge"] = function(a, b) return a >= b end,
}
-- ...and the test itself: sets and returns $? (0/1; the generic path's 2 + message on a
-- non-integer operand). `cmd` is "[" or "test".
function M.test_icmp(sh, a, op, b, cmd)
	if type(a) == "cdata" and type(b) == "cdata" then
		sh.status = TEST_CMP[op](a, b) and 0 or 1
		sh:set_str("_", cmd == "[" and "]" or i64_to_str(b))
		return sh.status
	end
	local argv = { cmd }
	for _, x in ipairs({ a, false, b }) do
		if x == false then
			argv[#argv + 1] = op
		elseif type(x) == "cdata" then
			argv[#argv + 1] = i64_to_str(x)
		else
			for k = 1, #x do
				argv[#argv + 1] = M.cstr(x[k])
			end
		end
	end
	if cmd == "[" then
		argv[#argv + 1] = "]"
	end
	do_test(sh, argv)
	sh:set_str("_", argv[#argv])
	return sh.status
end

-- Attribute-aware scalar assignment (interp's assign_scalar twin, for the EF.has_attr
-- compiled path): the RHS `value` is already word-expanded. A readonly target errors
-- (writing THROUGH a nameref is non-fatal; a direct one aborts the line, or hard-exits
-- under -c/posix); an array target assigns element [0]; an integer var arith-evaluates
-- the value (rt.arith_str — native, subscript/$-form via the interp seam); -l/-u fold
-- case; else a plain string set. `set -a` auto-exports a plain scalar. No array_key.
-- A compiled attributed assignment: like interp's assign statement, an expansion/arith
-- error in it (declare -i x; x='4+') fails just this assignment (status 1), non-fatally.
function M.assign_scalar_x(sh, name, value)
	local ok, e = pcall(M.assign_scalar, sh, name, value)
	if not ok then
		if type(e) == "table" and e.__curse_experr and not e.__curse_lineabort then
			sh.status = 1
			return
		end
		error(e, 0)
	end
end
function M.assign_scalar(sh, name, value)
	local direct = sh.vars[name]
	-- nameref write-through (interp assign path): a cycle (ref -> … -> ref) is a non-fatal
	-- warning; a nameref whose value carries a SUBSCRIPT (declare -n ref='a[2]') writes to
	-- that element, not the base's [0] that a plain deref would give.
	local selfsub = direct and direct.ref and direct.s and sh:self_elem_unref(name)
	if selfsub then
		sh:array_set(name, require("interp")._int.array_key(sh, name, selfsub), value, false)
		return
	end
	if direct and direct.ref and direct.s and direct.s ~= "" then
		if sh:deref(name) == "" then
			io.stderr:write("curse: warning: " .. name .. ": circular name reference\n")
			sh.status = 1
			return
		elseif direct.outer and direct.s:find("[", 1, true) then -- (`local -n a='a[0]'`)
			io.stderr:write("curse: `" .. direct.s .. "': not a valid identifier\n")
			error({ __curse_exit = 1, __curse_lineabort = true })
		elseif direct.outer then -- (a function's self-named ref: bash warns, then writes)
			io.stderr:write("curse: warning: " .. name .. ": circular name reference\n")
		end
		local nbase, nsub = (sh:deref_elem(name) or ""):match("^([%a_][%w_]*)%[(.+)%]$")
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
		io.stderr:write("curse: " .. sh:deref(name) .. ": readonly variable\n") -- (a ref's target)
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
	elseif b and b.int and not b.ref then
		sh:aset(name, M.int_value(sh, value)) -- declare -i: RHS is arithmetic
	elseif b and (b.lower or b.upper) then
		sh:set_str(name, b.lower and value:lower() or value:upper())
	elseif sh:set_str(name, value) == false then -- (a valueless nameref given a bad target)
		error({ __curse_exit = 1, __curse_lineabort = true })
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

-- xtrace (`set -x`): before running a command, write `$PS4<cmd words>` to the trace fd,
-- single-quoting any word that isn't a plain token (bash's xtrace_print_word_list). Shared
-- by both tiers: the compiled code calls these at the same points the interpreter does
-- (after a command's words expand, before its redirections), guarded by sh.opt_x.
function M.xtrace_quote(w)
	if w == "" then
		return "''"
	end
	if w:match("^[%w_@%%+=:,./%-]+$") then
		return w
	end
	return M.shell_quote(w)
end
-- xtrace output goes to fd $BASH_XTRACEFD when that's set to an open fd (bash), else stderr
function M.xtrace_write(sh, s)
	local fd = sh.vars.BASH_XTRACEFD and tonumber(sh:get("BASH_XTRACEFD"))
	if fd and fd ~= 2 and fd >= 0 and fd == math.floor(fd) then
		io.flush() -- (our buffered stdout first: fd 1 may be the trace fd)
		if M.fd_write(fd, s) then
			return
		end
	end
	io.stderr:write(s)
end
-- one xtrace line: $PS4 (its first char repeated per $(…)/eval/source level) + `text`
function M.xtrace_line(sh, text)
	local ps4 = sh.xtrace_ps4 or sh:get("PS4")
	if ps4:find("[$`\\]") then -- (PS4 is expanded like a prompt, untraced: `+[$LINENO] `)
		local sx, st = sh.opt_x, sh.status
		sh.opt_x = false
		local ok, v = pcall(require("interp").prompt_string, sh, ps4)
		sh.opt_x, sh.status = sx, st
		ps4 = ok and v or ps4
	end
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
function M.xtrace(sh, args, prequoted)
	local parts = {}
	for i = 1, #args do
		parts[i] = prequoted and args[i] or M.xtrace_quote(args[i])
	end
	M.xtrace_line(sh, table.concat(parts, " "))
end
-- (compiled argv built from word 2 on: the command name rides separately)
function M.xtrace_cmd(sh, name, args)
	local parts = { M.xtrace_quote(name) }
	for i = 1, #args do
		parts[i + 1] = M.xtrace_quote(args[i])
	end
	M.xtrace_line(sh, table.concat(parts, " "))
end
-- `+ name=value` for an assignment (the expanded value, as bash prints the word)
function M.xtrace_assign(sh, lhs, v)
	M.xtrace_line(sh, lhs .. (v == "" and "" or M.xtrace_quote(v)))
end
-- [[ ]] under set -x: a unary primary (`[[ -f x ]]`, `[[ ! -n y ]]`) traces its expanded
-- operand and hands it back; given `r` (a =~ RHS), `[[ v =~ r ]]`
function M.xdb1(sh, neg, op, v, r)
	if sh.opt_x then
		M.xtrace_line(sh, "[[ " .. (neg and "! " or "") .. (r and (v .. " =~ " .. r) or (op .. " " .. v)) .. " ]]")
	end
	return v
end
-- a binary primary: trace `[[ l op r ]]`, park the operands for the compare that follows
M._xl, M._xr = "", ""
function M.xdb2(sh, neg, op, l, r)
	if sh.opt_x then
		M.xtrace_line(sh, "[[ " .. (neg and "! " or "") .. l .. " " .. op .. " " .. r .. " ]]")
	end
	M._xl, M._xr = l, r
	return true
end
-- `declare -a NAME=(…)` under set -x: bash traces the compound assignment with every
-- element single-quoted (`+ q=(['2']='z' 'w')`), then the declaration (`+ declare -a q`)
function M.xtrace_declarr(sh, name, items, decl)
	M.xtrace_arrlit(sh, name, items)
	M.xtrace_line(sh, decl)
end
function M.xtrace_arrlit(sh, name, items)
	local function sq(v)
		return "'" .. tostring(v):gsub("'", "'\\''") .. "'"
	end
	local o = {}
	for i, it in ipairs(items) do
		o[i] = (it.key ~= nil and ("[" .. sq(it.key) .. "]=") or "") .. sq(it.val or "")
	end
	M.xtrace_line(sh, name .. "=(" .. table.concat(o, " ") .. ")")
end

return M
