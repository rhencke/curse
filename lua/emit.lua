-- Transpile the AST to a resumable Lua module using a flattened control-flow
-- graph dispatched on a program counter:
--
--   return { loopPc = {id->pc}, stmtPc = {k->pc}, run = function(sh, pc) ... end }
--
-- run() seeds lifted vars from `sh`, then `while true do if pc==N then …; pc=M …`.
-- Because control flow is flattened, run() can be ENTERED at ANY pc — the cond
-- check of any loop, at any nesting depth — and following the pc transitions
-- reconstructs the full continuation (inner loop exits -> outer step -> …). That
-- is general on-stack replacement: the interpreter hands off at a loop back-edge
-- and we jump into compiled code at that loop's cond pc. LuaJIT traces the hot
-- pc path to machine code with ~zero dispatch overhead (measured 1.01x native).
--
-- Vars used only arithmetically (all assignments arithmetic or a numeric
-- literal) are LIFTED to native Lua int64 locals, seeded from `sh` on entry and
-- written back on exit. Everything else stays in `sh`, so both tiers share it.
local M = {}

local CMP = { ["=="] = "==", ["!="] = "~=", ["<"] = "<", ["<="] = "<=", [">"] = ">", [">="] = ">=" }
local function lname(n) return "v_" .. n end

-- serialize a {int->int} pc map to a Lua table literal
local function serialize(t)
  local parts = {}
  for k, v in pairs(t) do parts[#parts + 1] = ("[%d]=%d"):format(k, v) end
  return "{" .. table.concat(parts, ", ") .. "}"
end

local emit_value
emit_value = function(e, lifted)
  local k = e.k
  if k == "num" then return e.v .. "LL" end
  if k == "var" then return lifted[e.name] and lname(e.name) or ("sh:aget(%q)"):format(e.name) end
  if k == "un" then
    if e.op == "-" then return "(-(" .. emit_value(e.e, lifted) .. "))" end
    return "((" .. emit_value(e.e, lifted) .. ") == 0LL and 1LL or 0LL)"
  end
  if k == "bin" then
    local l, r = emit_value(e.l, lifted), emit_value(e.r, lifted)
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

local function emit_bool(e, lifted)
  if e.k == "bin" and CMP[e.op] then
    return "(" .. emit_value(e.l, lifted) .. " " .. CMP[e.op] .. " " .. emit_value(e.r, lifted) .. ")"
  end
  return "((" .. emit_value(e, lifted) .. ") ~= 0LL)"
end

local function emit_set(name, valexpr, lifted)
  if lifted[name] then return lname(name) .. " = " .. valexpr end
  return ("sh:aset(%q, %s)"):format(name, valexpr)
end

local function emit_arith_stmt(e, lifted)
  if e.k == "asgn" then
    local v = emit_value(e.e, lifted)
    if e.op == "=" then return emit_set(e.name, v, lifted) end
    local cur = lifted[e.name] and lname(e.name) or ("sh:aget(%q)"):format(e.name)
    return emit_set(e.name, ("(%s %s (%s))"):format(cur, e.op:sub(1, 1), v), lifted)
  end
  if e.k == "post" or e.k == "pre" then
    local cur = lifted[e.name] and lname(e.name) or ("sh:aget(%q)"):format(e.name)
    return emit_set(e.name, ("(%s + %dLL)"):format(cur, e.d), lifted)
  end
  error("emit: statement position not supported for arith node " .. tostring(e.k))
end

local function emit_word(w, lifted)
  local parts = {}
  for _, p in ipairs(w.parts) do
    if p.lit then parts[#parts + 1] = ("%q"):format(p.lit)
    elseif p.var then
      parts[#parts + 1] = lifted[p.var] and ("rt.i64_to_str(%s)"):format(lname(p.var)) or ("sh:get(%q)"):format(p.var)
    elseif p.arith then
      parts[#parts + 1] = "rt.i64_to_str(" .. emit_value(require("parser").arith(p.arith), lifted) .. ")"
    end
  end
  if #parts == 0 then return '""' end
  return "(" .. table.concat(parts, " .. ") .. ")"
end

-- a word that is exactly one numeric literal -> its digits (else nil)
local function numeric_word(w)
  if #w.parts == 1 and w.parts[1].lit and w.parts[1].lit:match("^[+-]?%d+$") then
    return w.parts[1].lit
  end
  return nil
end

-- Which vars can be int64 locals: assigned somewhere, and every assignment is
-- arithmetic or a numeric literal (reads never disqualify).
local function analyze_lift(ast)
  local assigned, disq = {}, {}
  local function scan_stmts(stmts)
    for _, st in ipairs(stmts) do
      if st.t == "assign" then
        assigned[st.name] = true
        if not st.arith and not (st.rhs and numeric_word(st.rhs)) then disq[st.name] = true end
      elseif st.t == "forc" or st.t == "whilec" then
        for _, e in ipairs({ st.init, st.cond, st.step }) do
          if e and (e.k == "asgn" or e.k == "post" or e.k == "pre") then assigned[e.name] = true end
        end
        scan_stmts(st.body)
      elseif st.t == "if" then
        for _, cl in ipairs(st.clauses) do scan_stmts(cl.body) end
      end
    end
  end
  scan_stmts(ast.stmts)
  local lifted = {}
  for n in pairs(assigned) do if not disq[n] then lifted[n] = true end end
  return lifted
end

function M.emit(ast)
  local lifted = analyze_lift(ast)
  local blocks = {}       -- pc -> code string (must set `pc` to a successor)
  local loopPc, stmtPc = {}, {}
  local npc = 0
  local function newpc() local p = npc; npc = npc + 1; return p end

  local DONE = newpc()
  blocks[DONE] = "break"

  local flatten_list

  -- Build blocks for `st`; its exit flows to pc `after`. Returns st's entry pc.
  local function flatten_stmt(st, after)
    local t = st.t
    if t == "assign" then
      local p = newpc()
      if st.arith then
        blocks[p] = emit_set(st.name, emit_value(st.arith, lifted), lifted) .. ("; pc = %d"):format(after)
      elseif lifted[st.name] then
        blocks[p] = emit_set(st.name, numeric_word(st.rhs) .. "LL", lifted) .. ("; pc = %d"):format(after)
      else
        blocks[p] = ("sh:set_str(%q, %s); pc = %d"):format(st.name, emit_word(st.rhs, lifted), after)
      end
      return p
    elseif t == "simple" then
      local p = newpc()
      local args = {}
      for j = 2, #st.words do args[#args + 1] = emit_word(st.words[j], lifted) end
      local cmd = st.words[1].parts[1] and st.words[1].parts[1].lit
      local body
      if cmd == "echo" then body = "sh:echo(" .. table.concat(args, ", ") .. ")"
      elseif cmd == ":" or cmd == "true" then body = "sh.status = 0"
      elseif cmd == "false" then body = "sh.status = 1"
      else error("emit subset: unknown command " .. tostring(cmd)) end
      blocks[p] = body .. ("; pc = %d"):format(after)
      return p
    elseif t == "forc" then
      local condp = newpc(); loopPc[st.id] = condp
      local stepp = newpc()
      local bodyentry = flatten_list(st.body, stepp)
      blocks[stepp] = (st.step and emit_arith_stmt(st.step, lifted) .. "; " or "") .. ("pc = %d"):format(condp)
      blocks[condp] = ("if %s then pc = %d else pc = %d end"):format(
        st.cond and emit_bool(st.cond, lifted) or "true", bodyentry, after)
      if st.init then
        local ip = newpc()
        blocks[ip] = emit_arith_stmt(st.init, lifted) .. ("; pc = %d"):format(condp)
        return ip
      end
      return condp
    elseif t == "whilec" then
      local condp = newpc(); loopPc[st.id] = condp
      local bodyentry = flatten_list(st.body, condp)
      blocks[condp] = ("if %s then pc = %d else pc = %d end"):format(emit_bool(st.cond, lifted), bodyentry, after)
      return condp
    elseif t == "if" then
      -- allocate a cond pc per conditional clause (forward refs), flatten each
      -- body once, then wire the false-branches to the next clause.
      local cps, bentry = {}, {}
      for i, cl in ipairs(st.clauses) do if cl.cond then cps[i] = newpc() end end
      for i, cl in ipairs(st.clauses) do bentry[i] = flatten_list(cl.body, after) end
      local entry
      for i, cl in ipairs(st.clauses) do
        if cl.cond then
          local nxt = after
          if st.clauses[i + 1] then nxt = cps[i + 1] or bentry[i + 1] end -- next cond, or an else body
          blocks[cps[i]] = ("if %s then pc = %d else pc = %d end"):format(emit_bool(cl.cond, lifted), bentry[i], nxt)
          entry = entry or cps[i]
        else
          entry = entry or bentry[i] -- a leading else (unusual)
        end
      end
      return entry or after
    else
      error("emit: bad stmt " .. tostring(t))
    end
  end

  flatten_list = function(stmts, after)
    local nextpc = after
    for k = #stmts, 1, -1 do nextpc = flatten_stmt(stmts[k], nextpc) end
    return nextpc
  end

  -- top level: record each statement's entry pc for stmt-boundary resume
  local nextpc = DONE
  for k = #ast.stmts, 1, -1 do
    nextpc = flatten_stmt(ast.stmts[k], nextpc)
    stmtPc[k] = nextpc
  end
  local entry = stmtPc[1] or DONE

  -- assemble
  local o = {}
  o[#o + 1] = 'local rt = require("runtime")'
  o[#o + 1] = "local loopPc = " .. serialize(loopPc)
  o[#o + 1] = "local stmtPc = " .. serialize(stmtPc)
  o[#o + 1] = "local function run(sh, pc)"
  local lv = {}
  for n in pairs(lifted) do lv[#lv + 1] = n end
  table.sort(lv)
  for _, n in ipairs(lv) do o[#o + 1] = ("  local %s = sh:aget(%q)"):format(lname(n), n) end
  o[#o + 1] = ("  pc = pc or %d"):format(entry)
  o[#o + 1] = "  while true do"
  for p = 0, npc - 1 do
    o[#o + 1] = ("    %s pc == %d then %s"):format(p == 0 and "if" or "elseif", p, blocks[p])
  end
  o[#o + 1] = "    end"
  o[#o + 1] = "  end"
  for _, n in ipairs(lv) do o[#o + 1] = ("  sh:aset(%q, %s)"):format(n, lname(n)) end
  o[#o + 1] = "end"
  o[#o + 1] = "return { run = run, loopPc = loopPc, stmtPc = stmtPc }"
  return table.concat(o, "\n") .. "\n"
end

return M
