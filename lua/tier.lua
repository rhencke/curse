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

-- resume descriptor {kind,id} -> the pc to enter the compiled CFG at.
local function resume_pc(mod, r)
	return (r.kind == "loop") and mod.loopPc[r.id] or mod.stmtPc[r.id]
end

-- Run the compiled module with the interp's line-abort semantics: a div0/failglob
-- __curse_lineabort thrown from compiled code aborts the REST of the current input
-- line (bash), so re-enter run at sh._ff (set by the per-top-level-statement
-- markers) with $?=1. Under `set -e` it exits like any failed command. Keeping this
-- retry OUT of the generated run() lets pc/lifted stay fast locals (no closure).
function M.run_compiled(mod, sh, pc)
	while true do
		local ok, err = pcall(mod.run, sh, pc)
		if ok then
			return
		end
		if type(err) == "table" and err.__curse_lineabort and not sh.opt_e then
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
function M.run_tiered(src, sh)
	local Cache = require("cache")
	local path = Cache.artifact_path(src)
	local mod = Cache.load(path)
	if mod then
		I.finish_run(sh, function()
			M.run_compiled(mod, sh, nil)
		end)
		return sh, "warm"
	end
	local ok, code = pcall(function()
		return E.emit(P.parse(src))
	end)
	if ok then
		local chunk = load(code, "=curse:compiled")
		if chunk then
			local built, m = pcall(chunk)
			if built and type(m) == "table" and m.run then
				local okd, bc = pcall(string.dump, chunk, true)
				Cache.store(path, okd and bc or code) -- populate for the next (warm) run
				return M.run_mod(m, sh, src, 0) -- interp -> OSR fall-over
			end
		end
	end
	I.run(sh, P.parse(src)) -- fallback: always correct
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
	os.execute(("%s lua/transpile.lua %q %q >/dev/null 2>&1 &"):format(luajit, script_path, out))

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
