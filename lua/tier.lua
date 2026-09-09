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
    -- only hand off at a top-level safepoint (the compiled CFG can resume there);
    -- never inside a function call (calldepth > 0).
    if resume == nil and sh.calldepth == 0 and ready(kind, id, count) then
      resume = { kind = kind, id = id }
      error({ __curse_switch = true })
    end
  end

  local ok, err = pcall(I.run, sh, ast, hook)
  if ok then return sh, "interp-only" end
  if type(err) == "table" and err.__curse_switch then
    mod.run(sh, resume_pc(mod, resume)) -- OSR into compiled code
    return sh, "switched@" .. resume.kind .. resume.id
  end
  error(err)
end

-- The real thing: transpile in a DETACHED process while interpreting, switch the
-- instant the compiled Lua lands (works mid-loop, any nesting).
function M.run_background(script_path, opts)
  opts = opts or {}
  local luajit = opts.luajit or "luajit"
  local sh = opts.sh or rt.Shell.new()
  local f = assert(io.open(script_path, "r"))
  local src = f:read("*a"); f:close()
  local ast = P.parse(src)

  local out = os.tmpname() .. ".curse.lua"
  os.remove(out)
  os.execute(("%s lua/transpile.lua %q %q >/dev/null 2>&1 &"):format(luajit, script_path, out))

  local poll_every = opts.poll_every or 4096
  local count, resume, mod = 0, nil, nil
  local hook = function(kind, id)
    count = count + 1
    if mod == nil and sh.calldepth == 0 and count % poll_every == 0 then
      local cf = io.open(out, "r")
      if cf then
        cf:close()
        mod = assert(loadfile(out))() -- fully written (atomic rename)
        resume = { kind = kind, id = id }
        error({ __curse_switch = true })
      end
    end
  end

  local ok, err = pcall(I.run, sh, ast, hook)
  os.remove(out)
  if ok then return sh, "interp-only", count end
  if type(err) == "table" and err.__curse_switch then
    mod.run(sh, resume_pc(mod, resume))
    return sh, "switched-after-" .. count .. "-safepoints", count
  end
  error(err)
end

return M
