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

-- Compile source to a loaded module { run(sh,pc), loopPc={id->pc}, stmtPc={k->pc} }.
function M.compile(ast, opts)
	return assert(load(E.emit(ast, opts), "=curse:compiled"))()
end

-- Compile a runtime code string (eval / source) as a FRAGMENT: emit with fragment=true so a
-- TOP-LEVEL return/break/continue RAISES its signal (the caller's delegated cf-wrapper
-- catches it) instead of jumping to this unit's own DONE. Returns an instantiated module, or
-- nil when the code can't compile — a parse (syntax) error, alias use (needs line-at-a-time
-- expansion), or any construct emit still delegates. The caller then falls back to the
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
-- second parse); a false positive merely compiles eagerly, as before.
local frag_cache, frag_n, FRAG_MAX = {}, 0, 512
local function may_repeat(code)
	return code:find("%f[%w_]while%f[^%w_]") or code:find("%f[%w_]until%f[^%w_]")
		or code:find("%f[%w_]for%f[^%w_]") or code:find("%f[%w_]select%f[^%w_]")
		or code:find("%f[%w_]function%f[^%w_]") or code:find("%(%s*%)")
end
-- A fragment runs inside a shell whose ERR/DEBUG traps (and functrace) its own text may
-- not mention: compile their hooks in when they're set, keyed so each trap state gets its
-- own monomorphic compile.
-- "B": a trap handler that reads $BASH_COMMAND was set (or the program reads it) — code
-- compiled from then on records each command's text. sh.pflags (M.note_text): what the
-- program's text needs of EVERY piece of code compiled for it. A whole module's own scan
-- decides these for itself, but a fragment — a line in line mode, eval/source text, a
-- hot loop — can't see the code around it that reads them.
local function trap_mode(sh)
	local t = sh and sh.traps
	if not t then
		return ""
	end
	local e = t.ERR and t.ERR ~= "" and "E" or ""
	local d = t.DEBUG and t.DEBUG ~= "" and (sh.opt_functrace and "T" or "D") or ""
	return e .. d .. (sh.trap_bcmd and "B" or "") .. (sh.pflags or "")
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
-- (the emit opts a mode string asks for, beyond the trap hooks)
local function mode_opts(o, mode)
	o.bash_command = mode:find("B", 1, true) ~= nil
	o.pipestatus = mode:find("P", 1, true) ~= nil
	o.funcstack = mode:find("F", 1, true) ~= nil
	o.extdebug = mode:find("X", 1, true) ~= nil
	return o
end
-- With alias expansion on, a fragment's text parses with the live alias table (its own
-- unconditional alias commands then apply from their next line, as the reader does):
-- the table's signature keys the compile. Memoized per table + change count (alias_gen).
local function alias_sig(sh)
	if not (sh and sh.shopt and sh.shopt.expand_aliases) then
		return nil
	end
	local t = sh.aliases or {}
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
M.alias_sig = alias_sig
function M.try_fragment(code, line1, sh, now, label, noalias) -- line1: an eval's own line, which its code numbers from
	-- (now: the caller already saw this code run — compile it on this first call;
	-- line1 == false: a trap handler, whose commands keep the interrupted line;
	-- label "eval": its syntax errors read `eval: line N:` and end just the eval)
	local mode = trap_mode(sh) .. (line1 == false and "H" or "") .. (label == "eval" and "V" or "")
		.. ((label == "cmdsub" or label == "cmdsub-bq") and "C" or "") -- (a $( … ) body: its last command is marked, P.mark_tail)
		.. (label == "cmdsub-bq" and "Q" or "") -- (a backtick body: its syntax errors read `command substitution:`)
	local asig = not noalias and alias_sig(sh) -- (noalias: text read with its aliases expanded)
	-- (the live parse-time options the text is read under: posix mode, extglob)
	local pst = (sh.opt_posix and "p" or "") .. (sh.shopt and sh.shopt.extglob and "x" or "-")
	local key = mode .. pst .. "\0" .. (asig and ("A" .. asig .. "\0") or "") .. (line1 and (line1 .. "\0" .. code) or code)
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
function M.compile_fragment(code, line1, mode, atab, pst)
	-- (atab: the live alias table, expansion on — the parse starts from it; pst: the live
	-- posix/extglob state, "p"?("x"|"-"), else the parse tracks them from the text)
	local aenv = nil
	if atab then
		local tab = {}
		for k, v in pairs(atab) do
			tab[k] = v
		end
		aenv = { tab = tab }
	end
	local pok, ast = pcall(P.parse, code, nil, aenv, nil, pst and pst:find("p", 1, true) ~= nil or nil, nil,
		line1 or nil, pst and pst:find("x", 1, true) ~= nil)
	-- A syntax error becomes a `parse_error` statement after the valid prefix: compiled, it
	-- reports and raises __curse_parseerr, which the caller (eval/source/trap) contains.
	if not pok or type(ast) ~= "table" then
		return nil
	end
	if ast.ltrans then -- (a $"…" is translated as the text is read, under the live locale and
		return nil -- $TEXTDOMAIN: the interpreter's reader does that each time)
	end
	if mode and mode:find("C", 1, true) then
		P.mark_tail(ast.stmts)
	end
	for k, st in ipairs(ast.stmts) do
		if st.t == "parse_error" then
			st.lead = rt.perr_lead(ast.stmts, k) or nil
			if mode and mode:find("Q", 1, true) then -- (as capture_src labels the interpreted one)
				st.plabel = "command substitution"
			end
		end
	end
	local ok, chunk = pcall(function()
		mode = mode or ""
		return load(E.emit(ast, mode_opts({ fragment = true, perr_label = mode:find("V", 1, true) and "eval", trapline = mode:find("H", 1, true) ~= nil, trap_err = mode:find("E", 1, true) ~= nil,
			trap_debug = mode:find("[DT]") ~= nil, functrace = mode:find("T", 1, true) ~= nil }, mode)), "=curse:eval")
	end)
	if ok and chunk then
		local built, mod = pcall(chunk)
		if built and type(mod) == "table" and mod.run then
			-- (run as a $(…) body: the light buffer capture only when the compiler calls it
			-- pure — a redirect like `>&2` needs the fd-level capture: rt capture_src)
			mod.nofork = E.cmdsub_nofork_ok(ast.stmts) and #ast.stmts > 0
			return mod
		end
	end
	return nil
end

-- resume descriptor {kind,id} -> the pc to enter the compiled CFG at.
local function resume_pc(mod, r)
	if r.kind == "loop" then
		return mod.loopPc[r.id] -- (nil: that loop has no resume point — never a statement's)
	end
	return mod.stmtPc[r.id]
end

-- Run the compiled module with the interp's line-abort semantics: a div0/failglob
-- __curse_lineabort thrown from compiled code aborts the REST of the current input
-- line (bash), so re-enter run at sh._ff (set by the per-top-level-statement
-- markers) with $?=1. Under `set -e` it exits like any failed command. Keeping this
-- retry OUT of the generated run() lets pc/lifted stay fast locals (no closure).
-- `nested` (an eval/source/hot-loop fragment): a __curse_discard lineabort (bash's
-- top_level_cleanup + DISCARD) is not contained here but unwinds to the top level.
function M.run_compiled(mod, sh, pc, nested)
	local pd0, cd0, fs0, ne0 = sh.pd, sh.calldepth, sh.funcstack and #sh.funcstack or 0, sh.noerr
	while true do
		local ok, err = pcall(mod.run, sh, pc)
		if ok then
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
			if nested and err.__curse_discard then
				error(err, 0)
			end
			rt.posix_arith_fatal(sh, err)
			sh.status = not nested and err.__curse_badusage and not sh.opt_c and 2 or 1 -- (a failed ${x:=w})
			local sp = not nested and mod.lgspan and mod.lgspan[sh._ff]
			if sp then -- (bash's line numbers drift from here: rt.line_drift)
				rt.line_drift(sh, sp[1], sp[2])
			end
			pc = sh._ff
		else
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
		-- Hand off only where the compiled module has a resume pc for THIS safepoint:
		-- never inside a function call (calldepth>0), and — crucially — a forked child
		-- (subshell) resumes into its OWN bounded fragment (whose loops now have pcs),
		-- NOT the top-level continuation. A still-delegated context has no pc, so
		-- resume_pc is nil there and the child stays in the interpreter.
		if resume ~= nil or sh.calldepth ~= 0 or not ready(kind, id, count) then
			return
		end
		local pc = resume_pc(mod, { kind = kind, id = id })
		if pc ~= nil then
			resume = { kind = kind, id = id }
			-- carry the OSR itself on the error, so whoever catches it can run it: the
			-- top level here, OR a forked subshell child (which OSRs into its own
			-- bounded fragment and _exits, without the parent's finish_run/EXIT trap).
			error({
				__curse_switch = true,
				osr = function()
					M.run_compiled(mod, sh, pc)
				end,
			})
		end
	end

	local ok, err = pcall(I.run_lazy, sh, src, hook) -- lazy interp; ast is for compile only
	if ok then
		return sh, "interp-only"
	end
	if type(err) == "table" and err.__curse_switch then
		M.run_compiled(mod, sh, resume_pc(mod, resume)) -- OSR into compiled code
		return sh, "switched@" .. resume.kind .. resume.id
	end
	error(err)
end

-- Run a PRE-COMPILED module tiered: interpret (instant start), then OSR into `mod`
-- at the first safepoint past `switch_after` (default 0 -> the first one). Same
-- structure as run_background (the interp self-handles exit; only the OSR->compiled
-- part runs under finish_run, for exit-status + EXIT trap) but with the module
-- already built -- for the daemon cold path, which caches `mod` and needs no
-- detached transpile.
function M.run_mod(mod, sh, src, switch_after)
	switch_after = switch_after or 0
	local count, resume = 0, nil
	local hook = function(kind, id)
		count = count + 1
		local t = sh.traps
		if t and ((t.DEBUG and not mod.has_debug) or (t.RETURN and not mod.has_return)) then
			return
		end
		if resume ~= nil or sh.calldepth ~= 0 or count <= switch_after then
			return
		end
		local pc = resume_pc(mod, { kind = kind, id = id })
		if pc ~= nil then
			resume = { kind = kind, id = id }
			error({
				__curse_switch = true,
				osr = function()
					M.run_compiled(mod, sh, pc)
				end,
			})
		end
	end
	local ok, err = pcall(I.run_lazy, sh, src, hook)
	if ok then
		return sh, "interp-only"
	end
	if type(err) == "table" and err.__curse_switch then
		I.finish_run(sh, function()
			M.run_compiled(mod, sh, resume_pc(mod, resume))
		end)
		return sh, "cold"
	end
	error(err)
end

-- Daemon cold/hot execution. A warm cache hit loads the dumped bytecode and runs it
-- compiled ("warm"); a miss emits + STORES the bytecode (so the next run is a hit)
-- and runs TIERED (interp, then OSR fall-over into the compiled module) -- "cold".
-- If the emitter can't handle the script, fall back to the interpreter. Mirrors
-- cache.lua's M.run, but the cold path tiers instead of running compiled from pc=0.
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

local compile_store


local LOOP_WORDS = { "while", "until", "for", "select", "function" }
local function may_loop(src)
	for _, w in ipairs(LOOP_WORDS) do
		if src:find(w, 1, true) and src:find("%f[%w_]" .. w .. "%f[^%w_]") then -- (plain first: cheap)
			return true
		end
	end
	return src:find("(", 1, true) ~= nil and src:find("%(%s*%)") ~= nil -- (a `name()` funcdef)
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
		code = "for ((;" .. (st.src[2] or "") .. ";" .. (st.src[3] or "") .. "))" .. srcs:sub(st._h1, st._s1)
	else
		return false
	end
	local mod = M.compile_fragment(code, st.line, mode, nil, st._pst)
	if mod and st.t == "forin" then
		-- entered at the loop's resume point, adopting the interpreter's list + position
		-- (sh.forstate) under the fragment's own id for that loop: its first
		local fid = 1
		if not (mod.loopPc and mod.loopPc[fid]) then
			mod = nil -- (the emitter delegated the loop: no resume point)
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
	if st._fid then -- a `for … in`: continue its list where the interpreter is
		local fid = st._fid
		local saved = sh.forstate[fid]
		sh.forstate[fid] = sh.forstate[st.id]
		ok, err = pcall(M.run_compiled, mod, sh, mod.loopPc[fid], true)
		sh.forstate[fid] = saved
	else
		ok, err = pcall(M.run_compiled, mod, sh, nil, true)
	end
	sh.loopdepth = ld
	if ok then
		return true
	end
	return true, err
end
I.frag_hook = M.frag_hook -- (the interpreter's isolated contexts tier their hot loops)
-- A hot function whose body is still an interp AST — defined by eval'd or sourced text,
-- in a subshell, or redefined (none of those is in the program's own module) — compiles
-- standalone from its definition's exact text at its own line, and its later calls run
-- the compiled closure (cached on the definition node, per trap state). Not while aliases
-- are live (the definition parsed with the table as it was then).
function M.fn_hot(sh, name, def)
	local n = (def._calls or 0) + 1
	def._calls = n
	if n < HOT_LOOP or not def.deftext then
		return nil
	end
	-- (its compiled body fires DEBUG under functrace, RETURN and $FUNCNEST for the calls it
	-- makes — mode "T" keys it; live aliases: the definition parsed with the table AS IT WAS)
	-- (the parse-time posix/extglob state is fixed per definition node, def._pst)
	local mode = trap_mode(sh)
	if sh.shopt.expand_aliases and sh.aliases and next(sh.aliases) then
		return nil
	end
	if def._cfnm == mode then
		return def._cfn or nil
	end
	local mod = M.compile_fragment(def.deftext, def.line, mode, nil, def._pst)
	local fc = mod and mod.fnCall and mod.fnCall[name]
	def._cfn, def._cfnm = fc and fc.fn or false, mode
	return def._cfn or nil
end
I.fn_hook = M.fn_hot
-- A function a fragment defined runs under a trap state its compile didn't see (a DEBUG/
-- ERR trap set since, or cleared): compile its definition again for this state (cached on
-- the definition per mode). nil: run it as it is.
function M.fn_remode(sh, name, fm)
	local mode = trap_mode(sh)
	if fm.mode == mode then
		return nil
	end
	local def = fm.def
	if not (def and def.deftext) or (sh.shopt.expand_aliases and sh.aliases and next(sh.aliases)) then
		return nil
	end
	def._rm = def._rm or {}
	local f = def._rm[mode]
	if f == nil then
		local mod = M.compile_fragment(def.deftext, def.line, mode, nil, def._pst)
		local fc = mod and mod.fnCall and mod.fnCall[name]
		f = fc and fc.fn or false
		def._rm[mode] = f
	end
	return f or nil
end
I.fn_remode = M.fn_remode
-- emit + load + store (disk cache and this worker's) — nil if the emitter can't. With
-- `later`, the disk write waits for M.flush_stores (a compile MID-RUN happens under the
-- script's own limits — `ulimit -f 1` would kill the process with SIGXFSZ).
local pending_stores = {}
function M.flush_stores()
	local Cache = require("cache")
	while #pending_stores > 0 do
		local ps = table.remove(pending_stores)
		pcall(Cache.store, ps[1], ps[2])
	end
end
function compile_store(path, ast, sh, later)
	local ok, code = pcall(E.emit, ast, (sh.xt_start or sh.attr_start) and { xtrace = sh.xt_start, startattr = sh.attr_start } or nil)
	local chunk = ok and load(code, "=curse:compiled")
	if not chunk then
		if not ok and M.lm_reason(code) then -- (the next run reads it a line at a time)
			pending_stores[#pending_stores + 1] = { path, "return { lm = true, run = function() end }" }
		end
		return nil
	end
	local built, m = pcall(chunk)
	-- (judged by the state the shell STARTED in — the script enabling aliases itself is
	-- what a static-alias module already models)
	if not (built and type(m) == "table" and m.run) or alias_mismatch(m, sh.tier_start or sh) then
		return nil
	end
	local okd, bc = pcall(string.dump, chunk, true)
	if later then
		pending_stores[#pending_stores + 1] = { path, okd and bc or code }
	else
		require("cache").store(path, okd and bc or code)
	end
	modcache_put(path, m)
	return m
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
	local al = {}
	for k, v in pairs(sh.aliases or {}) do
		al[#al + 1] = k .. "=" .. v
	end
	table.sort(al)
	local so = sh.shopt or {}
	return table.concat({ "curse-line", tostring(lg.sline or 0), trap_mode(sh),
		(so.expand_aliases and "a" or "-") .. (sh.opt_posix and "p" or "-") .. (so.extglob and "g" or "-"),
		table.concat(al, "\1"), lg.src:sub(lg.spos, lg.pos - 1) }, "\0")
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
		mod = Cache.load(path)
		if not mod then
			-- (a line abort skips the rest of THIS line: all of it is one line group)
			lg.stmts[1].lgstart = true
			-- (the ERR/DEBUG traps set by earlier lines: their hooks compiled in — trap_mode)
			local tm = trap_mode(sh)
			-- ($(…) bodies parse with the live alias table, as the interpreter's expansion
			-- does — the key has it; a line that changes aliases leaves them to capture_src)
			local lmae = nil
			local txt = lg.src:sub(lg.spos, lg.pos - 1)
			if txt:find("alias", 1, true) then
				lmae = false
			elseif sh.shopt.expand_aliases and next(sh.aliases or {}) then
				lmae = { tab = {} }
				for an, av in pairs(sh.aliases) do
					lmae.tab[an] = av
				end
			end
			local ok, code = pcall(E.emit, { stmts = lg.stmts }, mode_opts({ fragment = true, lm = true,
				trap_err = tm:find("E", 1, true) ~= nil, trap_debug = tm:find("[DT]") ~= nil,
				functrace = tm:find("T", 1, true) ~= nil, lm_aenv = lmae }, tm))
			local chunk = ok and load(code, "=curse:line")
			local built, m = false, nil
			if chunk then
				built, m = pcall(chunk)
			end
			if not (built and type(m) == "table" and m.run) then
				if LM_DEBUG then
					io.stderr:write("[line " .. tostring(lg.sline) .. ": interpreted: " .. tostring(m or code) .. "]\n")
				end
				lm_fail[key] = true
				return nil
			end
			mod = m
			if path then
				local okd, bc = pcall(string.dump, chunk, true)
				pending_stores[#pending_stores + 1] = { path, okd and bc or code }
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
-- A program the emitter declined for a LEXICAL reason runs in line mode: its disk-cache
-- entry is this marker module, so a warm run goes straight to the line reader.
local LM_MARK = "return { lm = true, run = function() end }"
local function lm_reason(err)
	return type(err) == "string" and err:find("curse%-nocompile: line%-mode") ~= nil
end
M.lm_reason = lm_reason
function M.run_lm(sh, src)
	sh.lm = true
	I.run_lazy(sh, src)
end

-- Compile + store the scripts that ran interpreted on a miss (the daemon calls this once
-- the client has its reply — a worker does it one at a time, while nobody waits).
function M.has_deferred()
	return #deferred > 0
end
-- Parse a whole program under the parse options the shell STARTED with (pst: "p" posix
-- mode, "x" extglob — `--posix`, POSIXLY_CORRECT, `-O extglob`, BASHOPTS/SHELLOPTS): the
-- interpreter's first run reads it that way, so the module a warm run loads must too.
function M.parse_start(src, pst)
	if not pst then
		return P.parse(src)
	end
	return P.parse(src, nil, nil, nil, pst:find("p", 1, true) ~= nil or nil, nil, nil,
		pst:find("x", 1, true) ~= nil or nil)
end
function M.compile_deferred(one)
	local Cache = require("cache")
	while #deferred > 0 do
		local d = table.remove(deferred)
		local ok, code = pcall(function()
			return E.emit(M.parse_start(d.src, d.pst), (d.xt or d.attr) and { xtrace = d.xt, startattr = d.attr } or nil)
		end)
		local chunk = ok and load(code, "=curse:compiled")
		if chunk then
			local built, m = pcall(chunk)
			if built and type(m) == "table" and m.run then
				local okd, bc = pcall(string.dump, chunk, true)
				Cache.store(d.path, okd and bc or code)
				modcache_put(d.path, m)
			end
		elseif lm_reason(code) then -- (runs a line at a time from now on)
			Cache.store(d.path, LM_MARK)
		end
		if one then
			return
		end
	end
end
function M.run_tiered(src, sh)
	local Cache = require("cache")
	M.note_text(sh, src)
	-- (a shell started under set -x runs a module compiled WITH trace hooks: its own key)
	sh.xt_start = sh.opt_x or nil
	-- (started allexport/restricted: plain assignments may export or be refused — a module
	-- compiled for that, under its own key)
	sh.attr_start = (sh.opt_a or sh.opt_r) or nil
	sh.tier_start = { opt_x = sh.opt_x, opt_v = sh.opt_v, aliases = next(sh.aliases or {}) and { ["?"] = "" } or {},
		shopt = { expand_aliases = sh.shopt and sh.shopt.expand_aliases } }
	-- (started in posix mode / with extglob: the program parses differently — its own key)
	local pst = (sh.opt_posix and "p" or "") .. (sh.shopt and sh.shopt.extglob and "x" or "")
	pst = pst ~= "" and pst or nil
	local path = Cache.artifact_path((sh.xt_start or sh.attr_start or pst)
		and (src .. (sh.xt_start and "\0xtrace" or "") .. (sh.attr_start and "\0attr" or "")
			.. (pst and "\0pst" .. pst or "")) or src)
	if path then
		local cached = modcache_get(path)
		if cached and alias_mismatch(cached, sh) then -- (read a line at a time: each compiled)
			M.run_lm(sh, src)
			return sh, "lines"
		end
		if cached and cached.lm then
			M.run_lm(sh, src)
			return sh, "warm-lines"
		end
		if cached then -- in-process hit: no disk read, no module rebuild
			I.finish_run(sh, function()
				M.run_compiled(cached, sh, nil)
			end)
			return sh, "warm-mem"
		end
	end
	local mod = Cache.load(path)
	if mod and alias_mismatch(mod, sh) then
		M.run_lm(sh, src)
		return sh, "lines"
	end
	if mod and mod.lm then
		if path then modcache_put(path, mod) end
		M.run_lm(sh, src)
		return sh, "warm-lines"
	end
	if mod then
		if path then modcache_put(path, mod) end -- memoize the instantiated module
		I.finish_run(sh, function()
			M.run_compiled(mod, sh, nil)
		end)
		return sh, "warm"
	end
	-- A miss on a script that can't get hot (no loop, no function: a conservative scan of
	-- the text) runs in the interpreter right away; it's compiled after the reply
	-- (M.compile_deferred) so the NEXT run is a warm hit, and no caller waits for it.
	if path and not may_loop(src) then
		deferred[#deferred + 1] = { path = path, src = src, xt = sh.xt_start, attr = sh.attr_start, pst = pst }
		I.run_lazy(sh, src)
		return sh, "interp-deferred"
	end
	local ast -- (parsed for the compile, only if a loop gets hot)
	if path then
		-- Run it interpreted; a loop that turns hot compiles the script right then and
		-- continues compiled from that loop — at the top level (OSR into run), or inside a
		-- function call (interp run_function continues the call in the compiled function).
		-- A script that never gets hot is compiled after the reply.
		local mod, resume, count = nil, nil, 0
		local fnseen = {} -- (function name -> its switch verdict, checked once)
		local calls = {} -- (function name -> calls interpreted so far)
		-- (a DEBUG/RETURN trap now set: switch only into a module compiled with its hooks)
		local function trap_blocked()
			local t = sh.traps
			if not (t and (t.DEBUG or t.RETURN)) then
				return false
			end
			if mod == nil then
				if not ast then
					local okp, a = pcall(M.parse_start, src, pst)
					ast = okp and a or nil
				end
				mod = ast and compile_store(path, ast, sh, true) or false
			end
			return not mod or (t.DEBUG and not mod.has_debug) or (t.RETURN and not mod.has_return) or false
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
				if mod == nil then
					if not ast then
						local okp, a = pcall(M.parse_start, src, pst)
						ast = okp and a or nil
					end
					mod = ast and compile_store(path, ast, sh, true) or false
				end
				local fc = mod and mod.fnCall and mod.fnCall[id]
				if not fc then
					return nil
				end
				local verdict = fnseen[st]
				if verdict == nil then
					verdict = type(sh.functions[id]) == "table" and I.deparse_func(id, st) == fc.src or false
					fnseen[st] = verdict
				end
				return verdict and fc.fn or nil
			end
			if kind ~= "loop" then
				return
			end
			count = count + 1
			if count < HOT_LOOP or resume or trap_blocked() then
				return
			end
			if sh.calldepth ~= 0 then
				-- a hot loop inside a function call: compile, and continue THIS call
				-- compiled from the loop (interp run_function catches the switch) — when the
				-- running definition is the one compiled (a redefinition isn't)
				if mod == nil then
					if not ast then
						local okp, a = pcall(M.parse_start, src, pst)
						ast = okp and a or nil
					end
					mod = ast and compile_store(path, ast, sh, true) or false
				end
				local fname = sh.funcstack and sh.funcstack[1]
				local fl = mod and mod.fnLoop and fname and mod.fnLoop[fname]
				if not fl then
					return M.loop_osr(sh, st)
				end
				local def = sh.func_def and sh.func_def[fname]
				local verdict = def and fnseen[def]
				if def and verdict == nil then -- (per definition node: a redefinition is re-checked)
					verdict = type(sh.functions[fname]) == "table" and I.deparse_func(fname, def) == fl.src or false
					fnseen[def] = verdict
				end
				local fpc = verdict and fl.pcs[id]
				if fpc then
					error({ __curse_fnswitch = true, fn = fl.fn, pc = fpc, depth = sh.calldepth }, 0)
				end
				return M.loop_osr(sh, st)
			end
			if mod == nil then
				if not ast then
					local okp, a = pcall(M.parse_start, src, pst)
					ast = okp and a or nil
				end
				mod = ast and compile_store(path, ast, sh, true) or false
			end
			local pc = mod and resume_pc(mod, { kind = kind, id = id })
			if pc then -- (no module — the emitter declined, or aliases now in play: stay put)
				resume = { kind = kind, id = id }
				error({ __curse_switch = true })
			end
			return M.loop_osr(sh, st) -- (a loop the module can't resume: a subshell's, …)
		end
		local ok, err = pcall(I.run_lazy, sh, src, hook)
		if ok then
			if mod == nil then
				deferred[#deferred + 1] = { path = path, src = src, xt = sh.xt_start, attr = sh.attr_start, pst = pst }
			end
			return sh, "interp-deferred"
		end
		if type(err) == "table" and err.__curse_switch and mod then
			I.finish_run(sh, function()
				M.run_compiled(mod, sh, resume_pc(mod, resume))
			end)
			return sh, "cold-osr"
		end
		error(err)
	end
	I.run_lazy(sh, src) -- (no cache path: the interpreter's line-at-a-time parse)
	return sh, "interp"
end

-- The real thing: transpile in a DETACHED process while interpreting, switch the
-- instant the compiled Lua lands (works mid-loop, any nesting).
function M.run_background(script_path, opts)
	opts = opts or {}
	local luajit = opts.luajit or "luajit"
	local sh = opts.sh or rt.Shell.new()
	local f = assert(io.open(script_path, "r"))
	local src = f:read("*a")
	f:close()
	-- No eager parse here: the compile runs in a DETACHED process; the main process
	-- interprets LAZILY (instant start, parses only as far as it executes).

	local out = os.tmpname() .. ".curse.lua"
	os.remove(out)
	local tpid = rt.spawn_internal({ luajit, "lua/transpile.lua", script_path, out })

	local poll_every = opts.poll_every or 4096
	local count, resume, mod = 0, nil, nil
	local hook = function(kind, id)
		count = count + 1
		-- Don't OSR into compiled code while a DEBUG/RETURN trap is armed: those fire
		-- per-command, which the native compiled path can't reproduce. Stay in interp.
		if sh.traps and (sh.traps.DEBUG or sh.traps.RETURN) then
			return
		end
		if sh.calldepth ~= 0 then
			return
		end -- inside a function call: not an OSR target
		if mod == nil then
			if count % poll_every ~= 0 then
				return
			end
			local cf = io.open(out, "r")
			if not cf then
				return
			end
			cf:close()
			mod = assert(loadfile(out))() -- fully written (atomic rename)
			rt.reap_internal(tpid)
		end
		-- OSR only where THIS context has a resume pc: the top level, or a forked child
		-- (subshell) into its OWN bounded fragment. A delegated context has no pc, so
		-- it stays in the interpreter. The compiled module (out.lua) is the SAME shared
		-- artifact for parent and children — each jumps to the entry that matches it.
		local pc = resume_pc(mod, { kind = kind, id = id })
		if pc ~= nil then
			resume = { kind = kind, id = id }
			-- attach the OSR (see M.run) so a forked subshell child can OSR itself into
			-- its own bounded fragment (ends in subshell_exit → _exit) when it catches this.
			error({
				__curse_switch = true,
				osr = function()
					M.run_compiled(mod, sh, pc)
				end,
			})
		end
	end

	local ok, err = pcall(I.run_lazy, sh, src, hook)
	os.remove(out)
	rt.reap_internal(tpid)
	if ok then
		return sh, "interp-only", count
	end
	if type(err) == "table" and err.__curse_switch then
		I.finish_run(sh, function()
			M.run_compiled(mod, sh, resume_pc(mod, resume))
		end)
		return sh, "switched-after-" .. count .. "-safepoints", count
	end
	error(err)
end

return M
