-- Transpile the AST to Lua source. The emitted module is
--   return function(sh, resume) ... end
-- and — this is the point — it can be ENTERED at any top-level statement or any
-- loop back-edge via a `goto`-dispatch keyed by a resume descriptor, so the tier
-- driver can jump into compiled code from wherever the interpreter left off.
-- State lives entirely in `sh` (no locals), which (a) makes the OSR handoff need
-- zero seeding and (b) keeps `goto` legal (Lua forbids jumping into a local's
-- scope). A later pass will lift hot vars into locals with seed/writeback.
local M = {}

local CMP = { ["=="] = "==", ["!="] = "~=", ["<"] = "<", ["<="] = "<=", [">"] = ">", [">="] = ">=" }

local emit_value
emit_value = function(e)
  local k = e.k
  if k == "num" then return e.v .. "LL" end
  if k == "var" then return ("sh:aget(%q)"):format(e.name) end
  if k == "un" then
    if e.op == "-" then return "(-(" .. emit_value(e.e) .. "))" end
    return "((" .. emit_value(e.e) .. ") == 0LL and 1LL or 0LL)"
  end
  if k == "bin" then
    local l, r = emit_value(e.l), emit_value(e.r)
    local op = e.op
    if op == "+" or op == "-" or op == "*" or op == "/" or op == "%" then
      return "(" .. l .. " " .. op .. " " .. r .. ")"
    end
    if CMP[op] then return "((" .. l .. " " .. CMP[op] .. " " .. r .. ") and 1LL or 0LL)" end
    if op == "&&" then return "(((" .. l .. ") ~= 0LL and (" .. r .. ") ~= 0LL) and 1LL or 0LL)" end
    if op == "||" then return "(((" .. l .. ") ~= 0LL or (" .. r .. ") ~= 0LL) and 1LL or 0LL)" end
  end
  error("emit: value position not supported for node " .. tostring(k))
end

-- an arithmetic expression used as a condition -> a Lua boolean
local function emit_bool(e)
  if e.k == "bin" and CMP[e.op] then
    return "(" .. emit_value(e.l) .. " " .. CMP[e.op] .. " " .. emit_value(e.r) .. ")"
  end
  return "((" .. emit_value(e) .. ") ~= 0LL)"
end

-- an arithmetic expression in statement position (loop init / step)
local function emit_arith_stmt(e)
  if e.k == "asgn" then
    local v = emit_value(e.e)
    if e.op == "=" then return ("sh:aset(%q, %s)"):format(e.name, v) end
    return ("sh:aset(%q, sh:aget(%q) %s (%s))"):format(e.name, e.name, e.op:sub(1, 1), v)
  end
  if e.k == "post" or e.k == "pre" then
    return ("sh:aset(%q, sh:aget(%q) + %dLL)"):format(e.name, e.name, e.d)
  end
  error("emit: statement position not supported for arith node " .. tostring(e.k))
end

local function emit_word(w)
  local parts = {}
  for _, p in ipairs(w.parts) do
    if p.lit then parts[#parts + 1] = ("%q"):format(p.lit)
    elseif p.var then parts[#parts + 1] = ("sh:get(%q)"):format(p.var)
    elseif p.arith then parts[#parts + 1] = "rt.i64_to_str(" .. emit_value(require("parser").arith(p.arith)) .. ")" end
  end
  if #parts == 0 then return '""' end
  return "(" .. table.concat(parts, " .. ") .. ")"
end

local out, ind
local function line(s) out[#out + 1] = ("  "):rep(ind) .. s end

local emit_stmt
emit_stmt = function(st)
  local t = st.t
  if t == "assign" then
    if st.arith then line(("sh:aset(%q, %s)"):format(st.name, emit_value(st.arith)))
    else line(("sh:set_str(%q, %s)"):format(st.name, emit_word(st.rhs))) end
  elseif t == "simple" then
    local args = {}
    for j = 2, #st.words do args[#args + 1] = emit_word(st.words[j]) end
    local cmd = st.words[1].parts[1] and st.words[1].parts[1].lit
    if cmd == "echo" then line("sh:echo(" .. table.concat(args, ", ") .. ")")
    elseif cmd == ":" or cmd == "true" then line("sh.status = 0")
    elseif cmd == "false" then line("sh.status = 1")
    else error("emit subset: unknown command " .. tostring(cmd)) end
  elseif t == "forc" then
    if st.init then line(emit_arith_stmt(st.init)) end
    line("::loop_" .. st.id .. "::")
    line("while " .. (st.cond and emit_bool(st.cond) or "true") .. " do")
    ind = ind + 1
    for _, b in ipairs(st.body) do emit_stmt(b) end
    if st.step then line(emit_arith_stmt(st.step)) end
    ind = ind - 1
    line("end")
  elseif t == "whilec" then
    line("::loop_" .. st.id .. "::")
    line("while " .. emit_bool(st.cond) .. " do")
    ind = ind + 1
    for _, b in ipairs(st.body) do emit_stmt(b) end
    ind = ind - 1
    line("end")
  else
    error("emit: bad stmt " .. tostring(t))
  end
end

-- Emit the full resumable module.
function M.emit(ast)
  out, ind = {}, 1
  local top = ast.stmts
  line('local rt = require("runtime")')
  line("return function(sh, resume)")
  ind = ind + 1
  -- resume dispatch: jump to a top-level loop's back-edge, or a statement start.
  line("if resume ~= nil then")
  ind = ind + 1
  for _, st in ipairs(top) do
    if st.t == "forc" or st.t == "whilec" then
      line(("if resume.loop == %d then goto loop_%d end"):format(st.id, st.id))
    end
  end
  for k = 1, #top do line(("if resume.stmt == %d then goto s_%d end"):format(k, k)) end
  ind = ind - 1
  line("end")
  for k = 1, #top do
    line("::s_" .. k .. "::")
    emit_stmt(top[k])
  end
  ind = ind - 1
  line("end")
  return table.concat(out, "\n") .. "\n"
end

return M
