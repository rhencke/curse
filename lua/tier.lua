-- Tiered driver: start in the tree-walking interpreter (instant start), and once
-- the compiled Lua is ready, JUMP into it from wherever we are — including the
-- middle of a top-level loop (the no-function hot-loop case). State lives in the
-- shared `sh`, so the handoff transfers nothing: the interpreter's safepoint
-- unwinds (via a thrown marker) and we call compiled(sh, resume) with a resume
-- descriptor naming the loop back-edge / statement to continue from.
local rt = require("runtime")
local P = require("parser")
local I = require("interp")
local E = require("emit")

local M = {}
M.rt, M.parser, M.interp, M.emit = rt, P, I, E

-- Compile source to a loaded, resumable Lua function.
function M.compile(ast)
  return assert(load(E.emit(ast), "=curse:compiled"))()
end

-- Run with tiering.
--   opts.sh            : shell to use (default fresh)
--   opts.switch_after  : hand off after this many safepoints (nil = pure interp)
--   opts.ready         : function(kind,id,count)->bool, custom switch policy
-- Returns sh, and a string describing how it ran.
function M.run(src, opts)
  opts = opts or {}
  local sh = opts.sh or rt.Shell.new()
  local ast = P.parse(src)
  local compiled = M.compile(ast)

  local count, resume = 0, nil
  local ready = opts.ready or function(_, _, c)
    return opts.switch_after ~= nil and c >= opts.switch_after
  end
  local hook = function(kind, id)
    count = count + 1
    if resume == nil and ready(kind, id, count) then
      resume = (kind == "loop") and { loop = id } or { stmt = id }
      error({ __curse_switch = true })
    end
  end

  local ok, err = pcall(I.run, sh, ast, hook)
  if ok then return sh, "interp-only" end
  if type(err) == "table" and err.__curse_switch then
    compiled(sh, resume)  -- on-stack replacement into compiled code
    return sh, ("switched@" .. (resume.loop and ("loop" .. resume.loop) or ("stmt" .. resume.stmt)))
  end
  error(err)
end

return M
