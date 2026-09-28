-- Tiered driver: start in the tree-walking interpreter (instant start), and once
-- the compiled Lua is ready, JUMP into it from wherever we are — a top-level
-- statement boundary OR any loop back-edge, at ANY nesting depth. Both tiers
-- mutate the same `sh`, so the handoff transfers no state; the compiled module is
-- a flattened pc-dispatch CFG (see emit.lua) so it can be entered at the target
-- loop's cond pc and the pc transitions reconstruct the full continuation.
local rt = require("runtime")
local P = require("parser")
local I = require("interp")
local E = require("emit")

local M = {}
M.rt, M.parser, M.interp, M.emit = rt, P, I, E

-- Load emitted Lua and instantiate it (run the chunk: its closures and pc tables): the
-- module { run(sh,pc), loopPc={id->pc}, stmtPc={k->pc} } and its chunk, or nil when it
-- won't load or builds no module. Every compile path (fragments, line mode, whole
-- programs, M.compile) goes through here; `strict` raises the failure instead (compiled
-- mode's M.compile_start: its caller reports it).
local function build(code, name, strict)
	local chunk, err = load(code, name)
	local ok, m = false, err
	if chunk then
		ok, m = pcall(chunk)
	end
	if ok and type(m) == "table" and m.run then
		return m, chunk
	end
	if strict then
		error(ok and "curse: compiled chunk built no module" or m, 0)
	end
	return nil
end
-- Compile an AST to an instantiated module (compiled mode, M.run, unit tests).
function M.compile(ast, opts)
	return (build(E.emit(ast, opts), "=curse:compiled", true))
end
-- What the disk cache stores for a built chunk: its STRIPPED BYTECODE (a warm hit then
-- loads without a Lua parse; string.dump of a chunk is valid after it ran), else the source.
local function dump(chunk, code)
	local ok, bc = pcall(string.dump, chunk, true)
	return ok and bc or code
end

-- Compile a runtime code string (eval / source) as a FRAGMENT: emit with fragment=true so a
-- TOP-LEVEL return/break/continue RAISES its signal (the caller's cf-wrapper catches it)
-- instead of jumping to this unit's own DONE. Returns an instantiated module, or nil when
-- the code can't compile — a parse (syntax) error, alias use (needs line-at-a-time
-- expansion), or a construct emit refuses (cx.refuse). The caller then falls back to the
-- interpreter, which handles those correctly (and incrementally). Memoized by text below.
-- Compiled eval/source fragments, keyed by their exact text: a resident worker re-running a
-- script (or a loop re-running the same `eval "$cmd"`) reuses the module instead of paying
-- parse + emit + load each time. The result is a pure function of the text (fragment mode
-- compiles with no program-level assumptions), and a fragment module is re-runnable like
-- any cached top-level module. Bounded: cleared wholesale when it fills.
--
-- Tiering: compiling pays parse + emit + load up front, which only earns out for code that
-- runs more than once. Text that can't repeat internally (no loop keyword, no function
-- definition) runs in the interpreter on its FIRST sighting (nil here) and compiles when
-- the same text comes back — so a loop eval'ing ever-changing strings (`eval "echo
-- {0..$c}"`) never compiles a thing it won't reuse. The pre-scan is textual (cheap, no
-- second parse); a false positive merely compiles eagerly, as before. (The same scan
-- decides whether a whole program's cold run is worth tiering: run_tiered.)
local frag_cache, frag_n, FRAG_MAX = {}, 0, 512
local LOOP_WORDS = { "while", "until", "for", "select", "function" }
local function may_repeat(src)
	for _, w in ipairs(LOOP_WORDS) do
		if src:find(w, 1, true) and src:find("%f[%w_]" .. w .. "%f[^%w_]") then -- (plain first: cheap)
			return true
		end
	end
	return src:find("(", 1, true) ~= nil and src:find("%(%s*%)") ~= nil -- (a `name()` funcdef)
end
-- A fragment runs inside a shell whose ERR/DEBUG traps (and functrace) its own text may
-- not mention: compile their hooks in when they're set, keyed so each trap state gets its
-- own monomorphic compile.
-- "B": a trap handler that reads $BASH_COMMAND was set (or the program reads it) — code
-- compiled from then on records each command's text. sh.pflags (M.note_text): what the
-- program's text needs of EVERY piece of code compiled for it. A whole module's own scan
-- decides these for itself, but a fragment — a line in line mode, eval/source text, a
-- hot loop — can't see the code around it that reads them.
-- "L": a trap whose action may break/continue is set — a fragment's loops then keep the
-- loop depth and check after each command for the handler's break/continue (emit
-- EF.trap_loopctl), bash's loop_level being global. (Textual, as emit's own scan.)
local function trap_lc(t)
	for _, a in pairs(t) do
		if type(a) == "string" and (a:find("%f[%w_]break%f[^%w_]") or a:find("%f[%w_]continue%f[^%w_]")) then
			return true
		end
	end
	return false
end
local note_main
local function trap_mode(sh)
	local t = sh and sh.traps
	if not t then
		return ""
	end
	if not sh.main_noted and sh.main_src then -- (the tier loaded mid-run — an interpreted
		note_main(sh) -- program's first fragment: what the program's text reads, as start_state)
	end
	local e = t.ERR and t.ERR ~= "" and "E" or ""
	local d = t.DEBUG and t.DEBUG ~= "" and (sh.opt_functrace and "T" or "D") or ""
	return e .. d .. (sh.trap_bcmd and "B" or "") .. (sh.pflags or "") .. (trap_lc(t) and "L" or "")
end
M.trap_mode = trap_mode
-- Note a program's (or a sourced file's) text in sh.pflags, sticky: "P" it reads
-- $PIPESTATUS (every command sets it), "F" the call stack (FUNCNAME/BASH_SOURCE/
-- BASH_LINENO: calls keep it), "X" it may turn on extdebug (a DEBUG trap can skip a
-- command); $BASH_COMMAND sets sh.trap_bcmd ("B"). Textual — a false positive only costs
-- speed. The letters key every fragment compile (trap_mode) and reach emit as opts.
function M.note_text(sh, src)
	local pf = sh.pflags or ""
	local p = (pf:find("P", 1, true) or src:find("PIPESTATUS", 1, true)) and "P" or ""
	local f = (pf:find("F", 1, true) or src:find("FUNCNAME", 1, true) or src:find("BASH_SOURCE", 1, true)
		or src:find("BASH_LINENO", 1, true)) and "F" or ""
	local x = (pf:find("X", 1, true) or src:find("extdebug", 1, true)) and "X" or ""
	pf = p .. f .. x
	sh.pflags = pf ~= "" and pf or nil
	if src:find("BASH_COMMAND", 1, true) then
		sh.trap_bcmd = true
	end
end
-- The emit opts a fragment's mode string (trap_mode + try_fragment's letters) asks for:
-- the ERR/DEBUG hooks and functrace, what note_text found, "V" an eval's syntax-error
-- label, "H" a trap handler's line numbering. (The one place mode letters become opts.)
local function emit_opts(mode, o)
	o.trap_err = mode:find("E", 1, true) ~= nil
	o.trap_debug = mode:find("[DT]") ~= nil
	o.functrace = mode:find("T", 1, true) ~= nil
	o.bash_command = mode:find("B", 1, true) ~= nil
	o.pipestatus = mode:find("P", 1, true) ~= nil
	o.funcstack = mode:find("F", 1, true) ~= nil
	o.extdebug = mode:find("X", 1, true) ~= nil
	o.perr_label = mode:find("V", 1, true) and "eval" or nil
	o.trapline = mode:find("H", 1, true) ~= nil
	o.trap_lc = mode:find("L", 1, true) ~= nil
	return o
end
M.emit_opts = emit_opts -- (tools/delegate-census.lua sweeps every mode through it)
-- With alias expansion on, a fragment's text parses with the live alias table (its own
-- unconditional alias commands then apply from their next line, as the reader does):
-- the table's signature keys the compile. Memoized per table + change count (alias_gen),
-- so line mode (lm_key: every line) doesn't sort the table again each time.
local NO_ALIASES = {}
local function alias_join(sh)
	local t = sh.aliases or NO_ALIASES
	if sh._asig_t == t and sh._asig_g == (sh.alias_gen or 0) then
		return sh._asig
	end
	local al = {}
	for k, v in pairs(t) do
		al[#al + 1] = k .. "=" .. v
	end
	table.sort(al)
	sh._asig_t, sh._asig_g, sh._asig = t, sh.alias_gen or 0, table.concat(al, "\1")
	return sh._asig
end
local function alias_sig(sh)
	return sh and sh.shopt and sh.shopt.expand_aliases and alias_join(sh) or nil
end
-- (a parse starting from alias table t: its own copy, which the text's alias commands change)
local function aenv_of(t)
	local tab = {}
	for k, v in pairs(t) do
		tab[k] = v
	end
	return { tab = tab }
end
-- The lexing a text was read under is part of its parse state, like posix/extglob: pst
-- "b" = a multibyte locale whose trail bytes can be ASCII (Big5/GBK/SJIS: parser MBX, where
-- `\xa3\x5c` is one character, not a backslash). Its charset (P.mb_on(): the LC_CTYPE name)
-- keys every compile cache — the disk cache and a daemon worker's in-memory ones outlive
-- the request, and the next may run the same text in the C locale — and a recompile parses
-- with or without it as the pst says, not as whatever is live by then. (The characters it
-- keeps whole are the LIVE locale's: such a text is never compiled after its run — the
-- deferred compile runs after the request, maybe after the next, in another locale.)
local function mb_parse(pst, f, ...)
	local was = P.mb_on()
	local want = pst ~= nil and pst:find("b", 1, true) ~= nil and (was or "?") or false
	if want == was then
		return f(...)
	end
	P.mb_locale(want)
	local ok, r = pcall(f, ...)
	P.mb_locale(was)
	if not ok then
		error(r, 0)
	end
	return r
end
-- The live parse state as a pst string (the one producer; parser pst_now writes a node's
-- in the same form): "p" posix mode; "x" extglob on, else "-" (known off: P.parse's xg
-- false) — for a WHOLE program nothing (xg nil: its parse tracks extglob from the text);
-- "b" a Big5/GBK/SJIS locale's lexing (mb_parse). A whole program's is nil when empty.
-- Second result: the live charset itself (P.mb_on()), which keys the caches.
function M.pst(sh, whole)
	local mbx = P.mb_on()
	local pst = (sh.opt_posix and "p" or "") .. (sh.shopt and sh.shopt.extglob and "x" or whole and "" or "-")
		.. (mbx and "b" or "")
	return pst ~= "" and pst or nil, mbx
end
-- Parse text under the parse state pst records — not whatever is live by the time it
-- compiles (a whole program: as the shell STARTED — `--posix`, POSIXLY_CORRECT, `-O
-- extglob`, BASHOPTS/SHELLOPTS — which the interpreter's first run read it under, so the
-- module a warm run loads must too). aenv: the alias table the parse starts from; line1:
-- the line the text numbers from.
function M.parse_start(src, pst, aenv, line1, cs) -- (cs: a $(…) body — its last `DELIM )` line)
	local xg = nil
	if pst and pst:find("x", 1, true) then
		xg = true
	elseif pst and pst:find("-", 1, true) then
		xg = false
	end
	return mb_parse(pst, P.parse, src, nil, aenv, nil, pst and pst:find("p", 1, true) ~= nil or nil, nil, line1, xg, nil, cs)
end
function M.try_fragment(code, line1, sh, now, label, noalias) -- line1: an eval's own line, which its code numbers from
	-- (now: the caller already saw this code run — compile it on this first call;
	-- line1 == false: a trap handler, whose commands keep the interrupted line;
	-- label "eval": its syntax errors read `eval: line N:` and end just the eval)
	local mode = trap_mode(sh) .. (line1 == false and "H" or "") .. (label == "eval" and "V" or "")
		.. ((label == "cmdsub" or label == "cmdsub-bq") and "C" or "") -- (a $( … ) body: its last command is marked, P.mark_tail)
		.. (label == "cmdsub-bq" and "Q" or "") -- (a backtick body: its syntax errors read `command substitution:`)
	local asig = not noalias and alias_sig(sh) -- (noalias: text read with its aliases expanded)
	-- (the live parse-time options the text is read under: posix mode, extglob, and a
	-- Big5/GBK/SJIS locale's lexing)
	local pst, mbx = M.pst(sh)
	local key = mode .. pst .. "\0" .. (mbx and mbx .. "\0" or "") .. (asig and ("A" .. asig .. "\0") or "") .. (line1 and (line1 .. "\0" .. code) or code)
	local hit = frag_cache[key]
	if hit ~= nil and hit ~= 0 then
		return hit or nil
	end
	local mod = false
	if hit == nil and not now and not may_repeat(code) then
		mod = 0 -- seen once: interpret now, compile if it recurs
	else
		mod = M.compile_fragment(code, line1, mode, asig and sh.aliases, pst) or false
	end
	if frag_n >= FRAG_MAX then
		frag_cache, frag_n = {}, 0
	end
	if frag_cache[key] == nil then
		frag_n = frag_n + 1
	end
	frag_cache[key] = mod
	return mod ~= 0 and mod or nil
end
local function compile_fragment0(code, line1, mode, atab, pst)
	-- (atab: the live alias table, expansion on — the parse starts from it; pst: the live
	-- posix/extglob/lexing state, "p"?("x"|"-")"b"?, else the parse tracks them from the text)
	local pok, ast = pcall(M.parse_start, code, pst, atab and aenv_of(atab) or nil, line1 or nil,
		mode and mode:find("C", 1, true) ~= nil and not mode:find("Q", 1, true) or nil)
	-- A syntax error becomes a `parse_error` statement after the valid prefix: compiled, it
	-- reports and raises __curse_parseerr, which the caller (eval/source/trap) contains.
	if not pok or type(ast) ~= "table" then
		return nil
	end
	if ast.ltrans then -- (a $"…" is translated as the text is read, under the live locale and
		return nil -- $TEXTDOMAIN: the interpreter's reader does that each time)
	end
	mode = mode or ""
	if mode:find("C", 1, true) then
		P.mark_tail(ast.stmts)
	end
	for k, st in ipairs(ast.stmts) do
		if st.t == "parse_error" then
			st.lead = rt.perr_lead(ast.stmts, k) or nil
			if mode:find("Q", 1, true) then -- (as capture_src labels the interpreted one)
				st.plabel = "command substitution"
			end
		end
	end
	local ok, code = pcall(E.emit, ast, emit_opts(mode, { fragment = true }))
	local mod = ok and build(code, "=curse:eval")
	if mod then
		return mod
	end
	return nil
end
function M.compile_fragment(code, line1, mode, atab, pst)
	return rt.defer_call(compile_fragment0, code, line1, mode, atab, pst)
end

-- A safepoint (kind, id) -> the pc to enter the compiled CFG at.
local function resume_pc(mod, kind, id)
	if kind == "loop" then
		return mod.loopPc[id] -- (nil: that loop has no resume point — never a statement's)
	end
	return mod.stmtPc[id]
end

-- Run the compiled module with the interp's line-abort semantics: a div0/failglob
-- __curse_lineabort thrown from compiled code aborts the REST of the current input
-- line (bash), so re-enter run at sh._ff (set by the per-top-level-statement
-- markers) with $?=1. Under `set -e` it exits like any failed command. Keeping this
-- retry OUT of the generated run() lets pc/lifted stay fast locals (no closure).
-- `nested` (an eval/source/hot-loop fragment): a __curse_discard lineabort (bash's
-- top_level_cleanup + DISCARD) is not contained here but unwinds to the top level.
-- The lifted vars live in run()'s locals / the module's upvalues, written to sh at each
-- top-level statement's marker, so an abort mid-statement must keep what the statement
-- did to them (bash's variables are simply where the command left them). The xpcall
-- handler reads run()'s lifted slots off the still-live stack; after the unwind they are
-- written back — unless a synced call was out (sh._sy above its entry value: the callee,
-- which works on sh, may have changed them there, and sh is then the live copy).
local dgetinfo, dgetlocal = debug.getinfo, debug.getlocal
-- sh._ff belongs to the module running it: a nested fragment's markers write their own
-- (its retry resumes there), and the outer module's is back when the fragment leaves — by
-- return or by error — or the outer retry would jump to a pc of the fragment's numbering.
-- A retry never re-enters without progress: every resume enters through a statement marker,
-- which moves sh._ff on — an abort with sh._ff still where the last resume went is raised.
-- In a subshell environment a line abort out of eval/source/trap text isn't contained: bash's
-- parse_and_execute DISCARD jumps to the subshell's top level, which ends it, status 1.
function M.run_compiled(mod, sh, pc, nested)
	local pd0, cd0, fs0, ne0 = sh.pd, sh.calldepth, sh.funcstack and #sh.funcstack or 0, sh.noerr
	local ffo, lastff = sh._ff, false
	local lrun, lupv, grabbed = mod.lrun, mod.lupv, nil
	local larr = mod.larr -- (run()'s spilled registers: its __L, the local after lrun's)
	if larr and not lrun then
		lrun = {}
	end
	local handler = (lrun or lupv) and function(e)
		if lrun and type(e) == "table" and e.__curse_lineabort then
			local run = mod.run
			for l = 2, 1000 do
				local f = dgetinfo(l, "f")
				if not f then
					break
				end
				if f.func == run then -- (its first locals: slots 3.. — emit's assemble)
					grabbed = {}
					for k = 1, #lrun do
						local _, v = dgetlocal(l, 2 + k)
						grabbed[k] = v
					end
					if larr then
						local _, a = dgetlocal(l, 3 + #lrun)
						for k = 1, #larr do
							grabbed[#lrun + k] = a[k - 1]
						end
					end
					break
				end
			end
		end
		return e
	end
	while true do
		local pf0 = sh.procsub_files and #sh.procsub_files or 0
		local sy0 = sh._sy
		local ok, err
		if handler then
			grabbed = nil
			ok, err = xpcall(mod.run, handler, sh, pc)
		else
			ok, err = pcall(mod.run, sh, pc)
		end
		if ok then
			if nested then
				sh._ff = ffo
			end
			return
		end
		if type(err) == "table" and err.__curse_dbgskip and err.cfg == "run" then
			pc = err.__curse_dbgskip -- (extdebug: the DEBUG trap skipped a command — go on after it)
		elseif type(err) == "table" and err.__curse_lineabort and not rt.lineabort_exits(sh, err) then
			-- a lineabort from inside a function call unwinds its frames (locals, params,
			-- FUNCNAME) — the compiled call sites pop them only on a normal return
			while sh.pd > pd0 do
				sh:popCall()
			end
			while sh.funcstack and #sh.funcstack > fs0 do
				sh:leaveFunc()
			end
			sh.calldepth, sh.noerr = cd0, ne0 -- (a condition's noerr it unwound out of, too)
			if handler and sh._sy == sy0 then -- (no synced call out: the lifted copies are live)
				if grabbed then
					for k, n in ipairs(lrun) do
						sh:aset(n, grabbed[k])
					end
					for k, n in ipairs(larr or {}) do
						sh:aset(n, grabbed[#lrun + k])
					end
				end
				if lupv then
					local vals = { mod.upvget() }
					for k, n in ipairs(lupv) do
						sh:aset(n, vals[k])
					end
					local ua = mod.lupva and vals[#lupv + 1]
					for k, n in ipairs(mod.lupva or {}) do
						sh:aset(n, ua[k - 1])
					end
				end
			end
			sh._sy, grabbed = sy0, nil
			if nested and (err.__curse_discard or rt.in_subshell(sh)) or sh._ff == lastff then
				if nested then
					sh._ff = ffo
				end
				if nested and not err.__curse_discard and rt.in_subshell(sh) then
					sh.status = 1
					error({ __curse_exit = 1 }, 0)
				end
				error(err, 0)
			end
			lastff = sh._ff
			rt.posix_arith_fatal(sh, err)
			rt.line_aborted(sh, not nested and err.__curse_badusage and not sh.opt_c and 2 or 1, pf0, err) -- (a failed ${x:=w})
			local sp = not nested and mod.lgspan and mod.lgspan[sh._ff]
			if sp then -- (bash's line numbers drift from here: rt.line_drift)
				rt.line_drift(sh, sp[1], sp[2])
			end
			pc = sh._ff
		else
			if nested then
				sh._ff = ffo
			end
			error(err)
		end
	end
end

-- Run with a switch POLICY (synchronous compile). opts.switch_after = hand off
-- after this many safepoints (nil = pure interpret); opts.ready overrides.
function M.run(src, opts)
	opts = opts or {}
	local sh = opts.sh or rt.Shell.new()
	local ast = P.parse(src)
	local mod = M.compile(ast)

	local count, resume = 0, nil
	local ready = opts.ready or function(_, _, c)
		return opts.switch_after ~= nil and c >= opts.switch_after
	end
	local hook = function(kind, id)
		count = count + 1
		-- Hand off only where the compiled module has a resume pc for THIS safepoint,
		-- never inside a function call (calldepth>0). A loop with no resume point (one
		-- inside a subshell, $(…), …) has no pc: resume_pc is nil and it stays interpreted.
		if resume ~= nil or sh.calldepth ~= 0 or not ready(kind, id, count) then
			return
		end
		if resume_pc(mod, kind, id) ~= nil then
			resume = { kind = kind, id = id }
			error({ __curse_switch = true }) -- (unwind the interpreter; resumed below)
		end
	end

	local ok, err = pcall(I.run_lazy, sh, src, hook) -- lazy interp; ast is for compile only
	if ok then
		return sh, "interp-only"
	end
	if type(err) == "table" and err.__curse_switch then
		if resume.kind == "loop" and mod.loopFf and mod.loopFf[resume.id] then
			sh._ff = mod.loopFf[resume.id] -- (the loop's statement marker never ran)
		end
		M.run_compiled(mod, sh, resume_pc(mod, resume.kind, resume.id)) -- OSR into compiled code
		return sh, "switched@" .. resume.kind .. resume.id
	end
	error(err)
end

-- In-process module cache for a resident worker (daemon). Keyed by artifact path
-- (which embeds the content hash + build stamp), it holds the ALREADY-INSTANTIATED
-- module so a repeat script skips both the disk loadfile AND the module rebuild
-- (running the generated chunk to define its closures + pc tables). A module is
-- reusable across runs: all per-run state lives in `sh`, never in the module
-- (verified — repeated run_compiled on one mod yields identical results). Bounded
-- by a generational flip (keep the last full generation as a fallback, so a flush
-- never fully cold-starts a hot workload) to cap memory in a long-lived daemon.
local modcache, modcache_old, modcache_n = {}, {}, 0
local MODCACHE_CAP = 1024
local function modcache_get(path)
	local m = modcache[path]
	if m then return m end
	m = modcache_old[path]
	if m then modcache[path] = m; return m end -- promote survivor into the new generation
	return nil
end
local function modcache_put(path, m)
	if modcache_n >= MODCACHE_CAP then modcache_old, modcache, modcache_n = modcache, {}, 0 end
	modcache[path] = m; modcache_n = modcache_n + 1
end
-- (test hook: forget this worker's modules, so the next run loads from the disk cache —
-- test_cache checks a warm run really executes the stored artifact)
function M.drop_modcache()
	modcache, modcache_old, modcache_n = {}, {}, 0
end

-- A compiled module bakes in the alias expansion a from-scratch parse would do. If the
-- shell STARTS with aliases already in play (`-O expand_aliases`, or aliases from an rc/
-- BASH_ENV file), that assumption is off for scripts that define aliases — or for every
-- script when some are already defined — so interpret instead (always correct).
local function alias_mismatch(mod, sh)
	if sh.opt_v then -- started verbose (-v, inherited SHELLOPTS): the interpreter's line reader echoes
		return true
	end
	if sh.opt_x and not mod.xtrace then -- started tracing (-x, SHELLOPTS): a module without hooks
		return true
	end
	if not (sh.shopt and sh.shopt.expand_aliases) then
		return false
	end
	return mod.alias_static or (sh.aliases and next(sh.aliases) ~= nil)
end

local deferred = {}
-- (loop iterations before an interpreted cold run compiles and switches; CURSE_HOT_LOOP
-- overrides — 1 stress-tests OSR at every top-level loop)
local HOT_LOOP = tonumber(os.getenv("CURSE_HOT_LOOP") or "") or 100
-- A hot loop where neither OSR applies — inside a subshell, $(…), a pipeline stage, a
-- background job, or a function the module can't continue — is compiled ALONE, from its
-- own source text, and run in place of the rest of the interpreted loop. At the loop head
-- that is exact: a while/until re-tests its condition, and a (( ; ; )) loop re-states
-- its header without the init already run. Cached on the node (false: declined).
-- A loop whose last line opens here-documents (`… done <<E`, `do cat <<E; done | sort`):
-- their bodies follow that line, past the loop's own text — the fragment's text takes the
-- following lines until the re-parse reads them all (no end-of-file warning), else it would
-- run with the bodies missing.
local function hd_eof(code)
	local ok, ast = pcall(require("parser").parse, code)
	if not ok then
		require("parser").trap_flow(ast)
		return false
	end
	for _, x in ipairs(ast.stmts or {}) do
		if x.t == "warn" and tostring(x.msg):find("delimited by end-of-file", 1, true) then
			return true
		end
	end
	return false
end
local function with_bodies(code, srcs, s1)
	local nl = srcs:find("\n", s1 + 1, true)
	if not nl or not code:find("<<", 1, true) or not hd_eof(code) then
		return code
	end
	local pos, n = nl + 1, #srcs
	while pos <= n do
		local e = srcs:find("\n", pos, true) or n + 1
		code = code .. "\n" .. srcs:sub(pos, e - 1)
		pos = e + 1
		if not hd_eof(code) then
			return code
		end
	end
	return code
end
local function loop_fragment(st, sh)
	-- (its text re-parses under the posix/extglob state it was READ under, st._pst — not
	-- whatever is live by the time it's hot)
	local mode = trap_mode(sh)
	local frag = st._frag
	if frag ~= nil and st._fragm == mode then
		return frag
	end
	st._frag, st._fragm = false, mode
	local srcs = st._srcs
	if not srcs then
		return false
	end
	local code
	if st.t == "whilec" or st.t == "forin" then
		code = srcs:sub(st._s0, st._s1)
	elseif st.t == "forc" and st.src then
		-- (the init slot's newlines stay: the body's lines count from the header's)
		code = "for ((" .. (st.src[1] or ""):gsub("[^\n]", "") .. ";" .. (st.src[2] or "") .. ";" .. (st.src[3] or "") .. "))" .. srcs:sub(st._h1, st._s1)
	else
		return false
	end
	code = with_bodies(code, srcs, st._s1)
	local mod = M.compile_fragment(code, st.line, mode, nil, st._pst)
	if mod and st.t == "forin" then
		-- entered at the loop's resume point, adopting the interpreter's list + position
		-- (sh.forstate) under the fragment's own id for that loop: its first
		local fid = 1
		if not (mod.loopPc and mod.loopPc[fid]) then
			mod = nil -- (the loop has no resume point in the fragment)
		else
			st._fid = fid
		end
	end
	st._frag = mod or false
	return st._frag
end
-- (the interp's SUBHOOK forwards to this: loop fragments only, never a program switch)
function M.frag_hook(kind, id, st, sh)
	if kind == "loop" and sh then -- (a loop fragment carries RETURN-trap and trace hooks)
		return M.loop_osr(sh, st)
	end
end
-- Run the rest of loop `st` compiled, if it's hot enough and compiles: true (+ the
-- control-flow error the fragment raised, for the interp loop to rethrow after its
-- own cleanup), or nil to keep interpreting.
function M.loop_osr(sh, st)
	if not st or (st.t ~= "whilec" and st.t ~= "forc" and st.t ~= "forin") then
		return nil
	end
	if sh and sh.shopt and sh.shopt.expand_aliases and next(sh.aliases or {}) then
		return nil -- (its text re-parsed now wouldn't see the aliases it was read with)
	end
	local hits = (st._hits or 0) + 1
	st._hits = hits
	if hits < HOT_LOOP then
		return nil
	end
	local mod = loop_fragment(st, sh)
	if not mod then
		return nil
	end
	-- (sh.loopdepth counts the loops AROUND the fragment: its own interp frame is out)
	local ld = sh.loopdepth
	sh.loopdepth = ld - 1
	local ok, err
	-- (entered at the loop's resume point, the fragment skipped its statement marker: a line
	-- abort in it resumes at the loop statement's sh._ff — past the loop — not a stale one,
	-- or at the fragment's start: that re-ran the aborted iteration)
	local ff0 = sh._ff
	if st._fid then -- a `for … in`: continue its list where the interpreter is
		local fid = st._fid
		local saved = sh.forstate[fid]
		sh.forstate[fid] = sh.forstate[st.id]
		sh._ff = mod.loopFf and mod.loopFf[fid]
		ok, err = pcall(M.run_compiled, mod, sh, mod.loopPc[fid], true)
		sh.forstate[fid] = saved
	elseif st.t == "forc" and mod.loopPc and mod.loopPc[1] then
		-- a `for ((…))` the interpreter already initialized: resume at its condition (the
		-- fragment's empty init would trace, and fire DEBUG, as `(( 1 ))`)
		sh._ff = mod.loopFf and mod.loopFf[1]
		ok, err = pcall(M.run_compiled, mod, sh, mod.loopPc[1], true)
	else
		ok, err = pcall(M.run_compiled, mod, sh, nil, true)
	end
	sh._ff = ff0
	sh.loopdepth = ld
	if ok then
		return true
	end
	return true, err
end
I.frag_hook = M.frag_hook -- (the interpreter's isolated contexts tier their hot loops)
-- A definition compiled standalone from its exact text at its own line, for trap state
-- `mode`: its closure (cached on the definition node per mode; its parse-time posix/extglob
-- state is fixed per node, def._pst). nil: it doesn't compile, or aliases are live (the
-- definition parsed with the table AS IT WAS).
local function def_fn(sh, name, def, mode)
	if not def.deftext or (sh.shopt.expand_aliases and sh.aliases and next(sh.aliases)) then
		return nil
	end
	local rm = def._rm
	if not rm then
		rm = {}
		def._rm = rm
	end
	local f = rm[mode]
	if f == nil then
		local mod = M.compile_fragment(def.deftext, def.line, mode, nil, def._pst)
		local fc = mod and mod.fnCall and mod.fnCall[name]
		f = fc and fc.fn or false
		rm[mode] = f
	end
	return f or nil
end
-- A hot function whose body is still an interp AST — defined by eval'd or sourced text,
-- in a subshell, or redefined (none of those is in the program's own module) — compiles
-- standalone, and its later calls run the compiled closure. (Its compiled body fires
-- DEBUG under functrace, RETURN and $FUNCNEST for the calls it makes — mode "T" keys it.)
function M.fn_hot(sh, name, def)
	local n = (def._calls or 0) + 1
	def._calls = n
	if n < HOT_LOOP then
		return nil
	end
	return def_fn(sh, name, def, trap_mode(sh))
end
I.fn_hook = M.fn_hot
-- A function a fragment defined runs under a trap state its compile didn't see (a DEBUG/
-- ERR trap set since, or cleared): compile its definition again for this state. nil: run
-- it as it is.
function M.fn_remode(sh, name, fm)
	local mode = trap_mode(sh)
	if fm.mode == mode or not fm.def then
		return nil
	end
	return def_fn(sh, name, fm.def, mode)
end
I.fn_remode = M.fn_remode
-- A program the emitter declined for a LEXICAL reason runs in line mode: its disk-cache
-- entry is this marker module, so a warm run goes straight to the line reader.
local LM_MARK = "return { lm = true, run = function() end }"
local function lm_reason(err)
	return type(err) == "string" and err:find("curse%-nocompile: line%-mode") ~= nil
end
M.lm_reason = lm_reason
-- Publish an artifact in the disk cache. With `later`, the write waits for M.flush_stores
-- (a compile MID-RUN happens under the script's own limits — `ulimit -f 1` would kill the
-- process with SIGXFSZ).
local pending_stores = {}
local function store(path, code, later)
	if later then
		pending_stores[#pending_stores + 1] = { path, code }
	else
		require("cache").store(path, code)
	end
end
function M.flush_stores()
	local Cache = require("cache")
	while #pending_stores > 0 do
		local ps = table.remove(pending_stores)
		pcall(Cache.store, ps[1], ps[2])
	end
end
-- (the emit opts of a program started under set -x / allexport / restricted)
-- (imp: what the functions imported from the environment read — rt.import_functions'
-- sh.imp_flags, "F" the call stack, "P" $PIPESTATUS: the program's calls must keep them)
local function start_opts(xt, attr, imp)
	return (xt or attr or imp) and { xtrace = xt, startattr = attr,
		funcstack = imp and imp:find("F", 1, true) and true or nil,
		pipestatus = imp and imp:find("P", 1, true) and true or nil } or nil
end
-- Compile a whole program for the disk cache and this worker's: d = { path, src, pst, xt,
-- attr }, the inputs its key was made from (run_tiered — also a deferred compile's
-- record). Parses it as the shell STARTED (parse_start), emits, stores the bytecode
-- (`later`: store) and memoizes the module. A program emit declines for a lexical reason
-- stores LM_MARK: the next run reads it a line at a time. `start`: the state the shell
-- STARTED in — a module it can't use (alias_mismatch: judged by that state, since the
-- script enabling aliases itself is what a static-alias module already models) is nil,
-- and not stored.
local function compile_program0(d, later, start)
	local ok, code = pcall(function()
		return E.emit(M.parse_start(d.src, d.pst), start_opts(d.xt, d.attr, d.imp))
	end)
	local m, chunk
	if ok then
		m, chunk = build(code, "=curse:compiled")
	end
	if not m then
		if not ok and lm_reason(code) then
			store(d.path, LM_MARK, later)
		end
		return nil
	end
	if start and alias_mismatch(m, start) then
		return nil
	end
	store(d.path, dump(chunk, code), later)
	modcache_put(d.path, m)
	return m
end
-- (every compile holds signals — rt.defer_call: a trap's exit/return raised in its pcalls
-- would read as "doesn't compile" and be lost; the held signals run once it's done)
local function compile_program(d, later, start)
	return rt.defer_call(compile_program0, d, later, start)
end
-- LINE MODE. A script whose PARSE depends on run-time state — an alias defined as it
-- runs, history expansion, set -v echo — can't be compiled whole: the interpreter's
-- reader (run_lazy / run_history_lines) reads it a logical line at a time with the live
-- alias table, and each line then runs COMPILED (interp run_group -> here), as a line-mode
-- fragment. Its module is keyed by the line's text as parsed (aliases already spliced
-- in), its line, and the state the rest of the parse depends on (the alias table for the
-- $(…) bodies parsed later, expand_aliases, posix, extglob) — memoized in this worker and
-- stored in the disk cache, so a re-run loads each line's bytecode. nil: the line can't
-- compile (the interpreter runs it).
local lm_fail = {}
local LM_DEBUG = os.getenv("CURSE_LM_DEBUG")
local function lm_key(sh, lg)
	if not (lg.src and lg.spos and lg.pos) then
		return nil
	end
	local so = sh.shopt or {}
	return table.concat({ "curse-line", tostring(lg.sline or 0), trap_mode(sh),
		(so.expand_aliases and "a" or "-") .. (sh.opt_posix and "p" or "-") .. (so.extglob and "g" or "-")
			.. (P.mb_on() or "-"), -- (the lexing the line was read under: mb_parse)
		alias_join(sh), lg.src:sub(lg.spos, lg.pos - 1) }, "\0")
end
function M.lm_exec(sh, lg, k)
	local key = lm_key(sh, lg)
	if not key or lm_fail[key] then
		return nil
	end
	local Cache = require("cache")
	local path = Cache.artifact_path(key)
	local mod = path and modcache_get(path)
	if not mod then
		mod = rt.defer_call(Cache.load, path) -- (its chunk runs under a pcall too)
		if not mod then
			-- (a line abort skips the rest of THIS line: all of it is one line group)
			lg.stmts[1].lgstart = true
			-- ($(…) bodies parse with the live alias table, as the interpreter's expansion
			-- does — the key has it; a line that changes aliases leaves them to capture_src)
			local lmae = nil
			if lg.src:sub(lg.spos, lg.pos - 1):find("alias", 1, true) then
				lmae = false
			elseif sh.shopt.expand_aliases and next(sh.aliases or {}) then
				lmae = aenv_of(sh.aliases)
			end
			-- (the ERR/DEBUG traps set by earlier lines: their hooks compiled in — trap_mode)
			local chunk
			local ok, code = rt.defer_call(function()
				local eok, ecode = pcall(E.emit, { stmts = lg.stmts },
					emit_opts(trap_mode(sh), { fragment = true, lm = true, lm_aenv = lmae }))
				if eok then
					mod, chunk = build(ecode, "=curse:line")
				end
				return eok, ecode
			end)
			if not mod then
				if LM_DEBUG then
					io.stderr:write("[line " .. tostring(lg.sline) .. ": interpreted: " .. tostring(code) .. "]\n")
				end
				lm_fail[key] = true
				return nil
			end
			if path then
				store(path, dump(chunk, code), true)
			end
		end
		if path then
			modcache_put(path, mod)
		end
	end
	M.run_compiled(mod, sh, nil)
	-- (a failing call that set the ERR trap skips ITS OWN ERR check — rt.debug_leave; a
	-- line compiled before the trap existed has none to consume that, so it ends here)
	sh.err_skip = nil
	return k + #lg.stmts
end
I.lm_exec = M.lm_exec
function M.run_lm(sh, src)
	sh.lm = true
	I.run_lazy(sh, src)
end

-- Compile + store the scripts that ran interpreted on a miss (the daemon calls this once
-- the client has its reply — a worker does it one at a time, while nobody waits).
function M.has_deferred()
	return #deferred > 0
end
function M.compile_deferred(one)
	while #deferred > 0 do
		compile_program(table.remove(deferred))
		if one then
			return
		end
	end
end
-- The state a whole program compiles for, fixed as the shell STARTED: what its text needs
-- (note_text), set -x (a module compiled WITH trace hooks), allexport/restricted (plain
-- assignments may export or be refused), and its parse state (M.pst) — each its own cache
-- key. Returns the pst and the live multibyte charset.
note_main = function(sh, src)
	sh.main_noted = true
	M.note_text(sh, src or sh.main_src)
	if sh.imp_flags then -- (an imported function's text joins the program's: fragments too)
		M.note_text(sh, (sh.imp_flags:find("F", 1, true) and "FUNCNAME " or "") .. (sh.imp_flags:find("P", 1, true) and "PIPESTATUS" or ""))
	end
end
local function start_state(sh, src)
	sh.main_src = sh.main_src or src -- (the script's text: rt.coproc_exit_dispose's end-of-input line)
	note_main(sh, src)
	sh.xt_start = sh.opt_x or nil
	sh.attr_start = (sh.opt_a or sh.opt_r) or nil
	return M.pst(sh, true)
end
-- Compiled mode (run.lua): the whole program compiled up front, as the shell started. Throws
-- what emit throws (`curse-nocompile: …`, lm_reason) for the caller to fall back on.
function M.compile_start(sh, src)
	local pst = start_state(sh, src)
	return M.compile(M.parse_start(src, pst), start_opts(sh.xt_start, sh.attr_start, sh.imp_flags))
end
-- Daemon cold/hot execution. A warm cache hit (this worker's modules, else the disk's
-- dumped bytecode) runs compiled; a miss runs TIERED (interp, then OSR fall-over into the
-- compiled module once a loop turns hot), or — a script that can't get hot — interpreted,
-- compiling it after the reply (M.compile_deferred) so the NEXT run is a warm hit.
function M.run_tiered(src, sh)
	local pst, mbx = start_state(sh, src)
	sh.tier_start = { opt_x = sh.opt_x, opt_v = sh.opt_v, aliases = next(sh.aliases or {}) and { ["?"] = "" } or {},
		shopt = { expand_aliases = sh.shopt and sh.shopt.expand_aliases } }
	-- (read in a Big5/GBK/SJIS locale: keyed by its charset, and never deferred)
	local Cache = require("cache")
	local path = Cache.artifact_path((sh.xt_start or sh.attr_start or pst or sh.imp_flags)
		and (src .. (sh.xt_start and "\0xtrace" or "") .. (sh.attr_start and "\0attr" or "")
			.. (sh.imp_flags and "\0imp" .. sh.imp_flags or "")
			.. (pst and "\0pst" .. pst or "") .. (mbx and "\0" .. mbx or "")) or src)
	local mod = path and modcache_get(path) -- (in-process: no disk read, no module rebuild)
	if path and not mod then
		mod = Cache.load(path)
		if mod then
			modcache_put(path, mod)
		end
	end
	if mod then
		if mod.lm or alias_mismatch(mod, sh) then -- (read a line at a time: each compiled)
			M.run_lm(sh, src)
		else
			I.finish_run(sh, function()
				M.run_compiled(mod, sh, nil)
			end)
		end
		return
	end
	if not path then
		I.run_lazy(sh, src) -- (no cache path: the interpreter's line-at-a-time parse)
		return
	end
	local d = { path = path, src = src, xt = sh.xt_start, attr = sh.attr_start, pst = pst, imp = sh.imp_flags }
	-- A miss on a script that can't get hot (no loop, no function: may_repeat) runs in the
	-- interpreter right away, compiled after the reply; no caller waits for it.
	if not may_repeat(src) then
		if not mbx then
			deferred[#deferred + 1] = d
		end
		I.run_lazy(sh, src)
		return
	end
	-- Run it interpreted; a loop that turns hot compiles the script right then and
	-- continues compiled from that loop — at the top level (OSR into run), or inside a
	-- function call (interp run_function continues the call in the compiled function).
	-- A script that never gets hot is compiled after the reply.
	local resume, count = nil, 0 -- (the pc a hot loop switches in at)
	local resume_ff -- (its top-level statement's line-abort resume pc: the loop's sh._ff)
	local fnseen = {} -- (definition node -> its switch verdict, checked once)
	-- (the running definition of `name` is the one compiled — src: its compiled text)
	local function same_def(name, def, src)
		local verdict = fnseen[def]
		if verdict == nil then
			verdict = type(sh.functions[name]) == "table" and I.deparse_func(name, def) == src or false
			fnseen[def] = verdict
		end
		return verdict
	end
	local calls = {} -- (function name -> calls interpreted so far)
	-- (the module, compiled on the first hot safepoint; false: none — the emitter declined,
	-- or aliases now in play)
	local function compiled()
		if mod == nil then
			mod = compile_program(d, true, sh.tier_start) or false
		end
		return mod
	end
	-- (a DEBUG/RETURN trap now set: switch only into a module compiled with its hooks)
	local function trap_blocked()
		local t = sh.traps
		if not (t and (t.DEBUG or t.RETURN)) then
			return false
		end
		local m = compiled()
		return not m or (t.DEBUG and not m.has_debug) or (t.RETURN and not m.has_return) or false
	end
	local hook = function(kind, id, st, csh)
		if kind == "call" then
			-- a hot function (recursion, or called in a loop the switch can't take): the
			-- compiled version runs its later calls — when the running definition is the
			-- one compiled (checked once per definition node)
			local n = (calls[id] or 0) + 1
			calls[id] = n
			if n < HOT_LOOP or not st or trap_blocked() then
				return nil
			end
			local m = compiled()
			local fc = m and m.fnCall and m.fnCall[id]
			if not fc then
				return nil
			end
			return same_def(id, st, fc.src) and fc.fn or nil
		end
		if kind ~= "loop" then
			return
		end
		count = count + 1
		if count < HOT_LOOP or resume or trap_blocked() then
			return
		end
		if st and st._srcs ~= src then
			-- a loop of OTHER text — eval'd, sourced, a trap's: its id numbers that parse,
			-- not the program's (resuming the program at the program's loop of the same id
			-- would re-run it); it can only run compiled on its own
			return M.loop_osr(sh, st)
		end
		local m = compiled()
		if sh.calldepth ~= 0 then
			-- a hot loop inside a function call: compile, and continue THIS call
			-- compiled from the loop (interp run_function catches the switch) — when the
			-- running definition is the one compiled (a redefinition isn't)
			local fname = sh.funcstack and sh.funcstack[1]
			local fl = m and m.fnLoop and fname and m.fnLoop[fname]
			if not fl then
				return M.loop_osr(sh, st)
			end
			local def = sh.func_def and sh.func_def[fname]
			-- (per definition node: a redefinition is re-checked)
			local fpc = def and same_def(fname, def, fl.src) and fl.pcs[id]
			if fpc then
				error({ __curse_fnswitch = true, fn = fl.fn, pc = fpc, depth = sh.calldepth }, 0)
			end
			return M.loop_osr(sh, st)
		end
		resume = m and resume_pc(m, kind, id)
		resume_ff = m and m.loopFf and m.loopFf[id]
		if resume then -- (no module: stay put)
			error({ __curse_switch = true })
		end
		return M.loop_osr(sh, st) -- (a loop the module can't resume: a subshell's, …)
	end
	local ok, err = pcall(I.run_lazy, sh, src, hook)
	if ok then
		if mod == nil and not mbx then
			deferred[#deferred + 1] = d
		end
		return
	end
	if type(err) == "table" and err.__curse_switch and mod then
		I.finish_run(sh, function()
			-- (the OSR skipped the loop's statement marker: a line abort in the loop must
			-- resume after ITS statement, not at a stale sh._ff — or rerun from the start)
			sh._ff = resume_ff or sh._ff
			M.run_compiled(mod, sh, resume)
		end)
		return
	end
	error(err)
end

return M
