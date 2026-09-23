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
function M.compile(ast)
	return assert(load(E.emit(ast), "=curse:compiled"))()
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
function M.try_fragment(code, line1) -- line1: an eval's own line, which its code numbers from
	local key = line1 and (line1 .. "\0" .. code) or code
	local hit = frag_cache[key]
	if hit ~= nil and hit ~= 0 then
		return hit or nil
	end
	local mod = false
	if hit == nil and not may_repeat(code) then
		mod = 0 -- seen once: interpret now, compile if it recurs
	else
		mod = M.compile_fragment(code, line1) or false
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
function M.compile_fragment(code, line1)
	local pok, ast = pcall(P.parse, code, nil, nil, nil, nil, nil, line1)
	-- A syntax error (P.parse sets ast.perr and/or emits a `parse_error` statement, or
	-- throws): the interpreter is the oracle for it — it runs the valid PREFIX then reports
	-- the error with bash's status — so bail to the fallback rather than compile a fragment
	-- that would raise the parse error at runtime and abort the caller.
	if not pok or type(ast) ~= "table" or ast.perr then
		return nil
	end
	for _, st in ipairs(ast.stmts or {}) do
		if st.t == "parse_error" then
			return nil
		end
	end
	local ok, chunk = pcall(function()
		return load(E.emit(ast, { fragment = true }), "=curse:eval")
	end)
	if ok and chunk then
		local built, mod = pcall(chunk)
		if built and type(mod) == "table" and mod.run then
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
function M.run_compiled(mod, sh, pc)
	local pd0, cd0, fs0 = sh.pd, sh.calldepth, sh.funcstack and #sh.funcstack or 0
	while true do
		local ok, err = pcall(mod.run, sh, pc)
		if ok then
			return
		end
		if type(err) == "table" and err.__curse_lineabort and not sh.opt_e then
			-- a lineabort from inside a function call unwinds its frames (locals, params,
			-- FUNCNAME) — the compiled call sites pop them only on a normal return
			while sh.pd > pd0 do
				sh:popCall()
			end
			while sh.funcstack and #sh.funcstack > fs0 do
				sh:leaveFunc()
			end
			sh.calldepth = cd0
			rt.posix_arith_fatal(sh, err)
			sh.status = 1
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
		if sh.traps and (sh.traps.DEBUG or sh.traps.RETURN) then
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
	if sh.opt_x or sh.opt_v then -- started tracing (-x, inherited SHELLOPTS): interp traces
		return true
	end
	if not (sh.shopt and sh.shopt.expand_aliases) then
		return false
	end
	return mod.alias_static or (sh.aliases and next(sh.aliases) ~= nil)
end

local compile_first, compile_store

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
-- Must a miss compile BEFORE it runs? Only when it can get hot inside a function call — a
-- loop in a function body, or a function that calls itself — where the interpreter can't
-- switch to compiled code mid-call. Anything else can switch at a hot top-level loop.
local LOOPS = { whilec = 1, forin = 1, forc = 1, select = 1 }
function compile_first(ast)
	local found = false
	local function walk(t, fname, d)
		if found or d > 300 then
			return
		end
		if t.t == "funcdef" then
			fname = t.name
		end
		if fname then
			if LOOPS[t.t] then
				found = true
				return
			end
			local w = t.t == "simple" and t.words and t.words[1]
			local p = w and w.parts and w.parts[1]
			if p and p.lit == fname then
				found = true
				return
			end
		end
		for _, v in pairs(t) do
			if type(v) == "table" then
				walk(v, fname, d + 1)
			end
		end
	end
	walk(ast.stmts, nil, 0)
	return found
end
-- emit + load + store (disk cache and this worker's) — nil if the emitter can't.
function compile_store(path, ast, sh)
	local ok, code = pcall(E.emit, ast)
	local chunk = ok and load(code, "=curse:compiled")
	if not chunk then
		return nil
	end
	local built, m = pcall(chunk)
	if not (built and type(m) == "table" and m.run) or alias_mismatch(m, sh) then
		return nil
	end
	local okd, bc = pcall(string.dump, chunk, true)
	require("cache").store(path, okd and bc or code)
	modcache_put(path, m)
	return m
end
-- Compile + store the scripts that ran interpreted on a miss (the daemon calls this once
-- the client has its reply).
function M.compile_deferred()
	local Cache = require("cache")
	while #deferred > 0 do
		local d = table.remove(deferred)
		local ok, code = pcall(function()
			return E.emit(P.parse(d.src))
		end)
		local chunk = ok and load(code, "=curse:compiled")
		if chunk then
			local built, m = pcall(chunk)
			if built and type(m) == "table" and m.run then
				local okd, bc = pcall(string.dump, chunk, true)
				Cache.store(d.path, okd and bc or code)
				modcache_put(d.path, m)
			end
		end
	end
end
function M.run_tiered(src, sh)
	local Cache = require("cache")
	local path = Cache.artifact_path(src)
	if path then
		local cached = modcache_get(path)
		if cached and alias_mismatch(cached, sh) then
			I.run_lazy(sh, src)
			return sh, "interp"
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
		I.run_lazy(sh, src)
		return sh, "interp"
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
		deferred[#deferred + 1] = { path = path, src = src }
		I.run_lazy(sh, src)
		return sh, "interp-deferred"
	end
	local pok, ast = pcall(P.parse, src)
	if path and pok and type(ast) == "table" and ast.stmts and not compile_first(ast) then
		-- It can only get hot in a TOP-LEVEL loop, where the interpreter can switch: run it
		-- interpreted; a loop that turns hot compiles it right then and continues compiled
		-- (OSR at that loop); one that never does is compiled after the reply.
		local mod, resume, count = nil, nil, 0
		local hook = function(kind, id)
			if kind ~= "loop" then
				return
			end
			count = count + 1
			if count < HOT_LOOP or resume or sh.calldepth ~= 0 or (sh.traps and (sh.traps.DEBUG or sh.traps.RETURN)) then
				return
			end
			if mod == nil then
				mod = compile_store(path, ast, sh) or false
			end
			local pc = mod and resume_pc(mod, { kind = kind, id = id })
			if pc then -- (no module — the emitter declined, or aliases now in play: stay put)
				resume = { kind = kind, id = id }
				error({ __curse_switch = true })
			end
		end
		local ok, err = pcall(I.run_lazy, sh, src, hook)
		if ok then
			if mod == nil then
				deferred[#deferred + 1] = { path = path, src = src }
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
	local m = pok and path and compile_store(path, ast, sh)
	if m then
		return M.run_mod(m, sh, src, 0) -- interp -> OSR fall-over
	end
	I.run_lazy(sh, src) -- fallback: the interpreter's line-at-a-time parse, always correct
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
