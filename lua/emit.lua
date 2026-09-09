-- Transpile the AST to resumable Lua source.
--   return function(sh, resume) ... end
--
-- Two emission modes per top-level loop:
--   * sh-direct (fallback): all state in `sh`; the loop is inline with a
--     `::loop_id::` label so OSR resumes via `goto`. Correct for anything.
--   * lifted (fast): a "liftable" arithmetic loop (init/cond/step arithmetic and
--     a body of only arith assignments / nested liftable loops) becomes a
--     per-loop closure whose vars are native Lua int64 LOCALS, seeded from `sh`
--     on entry and written back on exit. The closure form sidesteps Lua's
--     "no goto into a local's scope" rule and makes OSR a plain seeded call:
--     resume into the loop == call the closure with the live `sh`.
--
-- State that isn't lifted stays in `sh`, so both tiers still share one table.
local M = {}

local CMP = { ["=="] = "==", ["!="] = "~=", ["<"] = "<", ["<="] = "<=", [">"] = ">", [">="] = ">=" }
local function lname(n) return "v_" .. n end

-- `lifted` maps bash var name -> true for vars held in Lua locals in this scope.
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

-- write to a var: a lifted var mutates its local, else sh:aset.
local function emit_set(name, valexpr, lifted)
  if lifted[name] then return lname(name) .. " = " .. valexpr end
  return ("sh:aset(%q, %s)"):format(name, valexpr)
end

-- arith expr in statement position (loop init / step)
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
    elseif p.var then parts[#parts + 1] = ("sh:get(%q)"):format(p.var)
    elseif p.arith then parts[#parts + 1] = "rt.i64_to_str(" .. emit_value(require("parser").arith(p.arith), lifted) .. ")" end
  end
  if #parts == 0 then return '""' end
  return "(" .. table.concat(parts, " .. ") .. ")"
end

-- Is a loop "liftable"? init/cond/step must be arithmetic (already are), and the
-- body must be only arith assignments (name=$((…))) or nested liftable loops.
-- Collects every var name the loop reads/writes (for seed/writeback).
local function scan_arith(e, set)
  if type(e) ~= "table" then return end
  if e.k == "var" or e.k == "asgn" or e.k == "post" or e.k == "pre" then set[e.name] = true end
  scan_arith(e.e, set); scan_arith(e.l, set); scan_arith(e.r, set)
end
local function liftable(st, set)
  if st.init then scan_arith(st.init, set) end
  if st.cond then scan_arith(st.cond, set) end
  if st.step then scan_arith(st.step, set) end
  for _, b in ipairs(st.body) do
    if b.t == "assign" and b.arith then
      set[b.name] = true; scan_arith(b.arith, set)
    elseif (b.t == "forc" or b.t == "whilec") then
      if not liftable(b, set) then return false end
    else
      return false -- a command / word-assign => can't lift this loop
    end
  end
  return true
end

local out, ind
local function line(s) out[#out + 1] = ("  "):rep(ind) .. s end

-- emit statements that run inside a lifted loop closure (arith only)
local function emit_lifted_body(stmts, lifted)
  for _, b in ipairs(stmts) do
    if b.t == "assign" then
      line(emit_set(b.name, emit_value(b.arith, lifted), lifted))
    elseif b.t == "forc" then
      if b.init then line(emit_arith_stmt(b.init, lifted)) end
      line("while " .. (b.cond and emit_bool(b.cond, lifted) or "true") .. " do")
      ind = ind + 1; emit_lifted_body(b.body, lifted)
      if b.step then line(emit_arith_stmt(b.step, lifted)) end
      ind = ind - 1; line("end")
    elseif b.t == "whilec" then
      line("while " .. emit_bool(b.cond, lifted) .. " do")
      ind = ind + 1; emit_lifted_body(b.body, lifted); ind = ind - 1; line("end")
    end
  end
end

-- sh-direct statement (fallback for non-liftable loops and top-level non-loops)
local NOLIFT = setmetatable({}, { __index = function() return false end })
local emit_stmt_direct
emit_stmt_direct = function(st)
  local t = st.t
  if t == "assign" then
    if st.arith then line(emit_set(st.name, emit_value(st.arith, NOLIFT), NOLIFT))
    else line(("sh:set_str(%q, %s)"):format(st.name, emit_word(st.rhs, NOLIFT))) end
  elseif t == "simple" then
    local args = {}
    for j = 2, #st.words do args[#args + 1] = emit_word(st.words[j], NOLIFT) end
    local cmd = st.words[1].parts[1] and st.words[1].parts[1].lit
    if cmd == "echo" then line("sh:echo(" .. table.concat(args, ", ") .. ")")
    elseif cmd == ":" or cmd == "true" then line("sh.status = 0")
    elseif cmd == "false" then line("sh.status = 1")
    else error("emit subset: unknown command " .. tostring(cmd)) end
  elseif t == "forc" then
    if st.init then line(emit_arith_stmt(st.init, NOLIFT)) end
    line("::loop_" .. st.id .. "::")
    line("while " .. (st.cond and emit_bool(st.cond, NOLIFT) or "true") .. " do")
    ind = ind + 1
    for _, b in ipairs(st.body) do emit_stmt_direct(b) end
    if st.step then line(emit_arith_stmt(st.step, NOLIFT)) end
    ind = ind - 1; line("end")
  elseif t == "whilec" then
    line("::loop_" .. st.id .. "::")
    line("while " .. emit_bool(st.cond, NOLIFT) .. " do")
    ind = ind + 1
    for _, b in ipairs(st.body) do emit_stmt_direct(b) end
    ind = ind - 1; line("end")
  else
    error("emit: bad stmt " .. tostring(t))
  end
end

function M.emit(ast)
  out, ind = {}, 1
  local top = ast.stmts
  -- classify top-level loops
  local info = {} -- k -> { lifted = bool, vars = sorted names, id = }
  for k, st in ipairs(top) do
    if st.t == "forc" or st.t == "whilec" then
      local set = {}
      local ok = liftable(st, set)
      local vars = {}
      if ok then for n in pairs(set) do vars[#vars + 1] = n end; table.sort(vars) end
      info[k] = { lifted = ok, vars = vars, id = st.id }
    end
  end

  line('local rt = require("runtime")')
  line("return function(sh, resume)")
  ind = ind + 1

  -- per-loop closures for liftable loops (seed from sh, run on locals, write back)
  for k, st in ipairs(top) do
    local nfo = info[k]
    if nfo and nfo.lifted then
      local lifted = {}; for _, n in ipairs(nfo.vars) do lifted[n] = true end
      line(("local function __loop%d(sh)"):format(nfo.id))
      ind = ind + 1
      for _, n in ipairs(nfo.vars) do line(("local %s = sh:aget(%q)"):format(lname(n), n)) end
      if st.t == "forc" then
        line("while " .. (st.cond and emit_bool(st.cond, lifted) or "true") .. " do")
        ind = ind + 1; emit_lifted_body(st.body, lifted)
        if st.step then line(emit_arith_stmt(st.step, lifted)) end
        ind = ind - 1; line("end")
      else
        line("while " .. emit_bool(st.cond, lifted) .. " do")
        ind = ind + 1; emit_lifted_body(st.body, lifted); ind = ind - 1; line("end")
      end
      for _, n in ipairs(nfo.vars) do line(("sh:aset(%q, %s)"):format(n, lname(n))) end
      ind = ind - 1; line("end")
    end
  end

  -- resume dispatch
  line("if resume ~= nil then")
  ind = ind + 1
  for k, st in ipairs(top) do
    local nfo = info[k]
    if nfo then
      if nfo.lifted then
        line(("if resume.loop == %d then __loop%d(sh); goto s_%d end"):format(nfo.id, nfo.id, k + 1))
      else
        line(("if resume.loop == %d then goto loop_%d end"):format(nfo.id, nfo.id))
      end
    end
  end
  for k = 1, #top do line(("if resume.stmt == %d then goto s_%d end"):format(k, k)) end
  ind = ind - 1
  line("end")

  -- statements
  for k = 1, #top do
    line("::s_" .. k .. "::")
    local st = top[k]
    local nfo = info[k]
    if nfo and nfo.lifted then
      if st.init then line(emit_arith_stmt(st.init, NOLIFT)) end -- fresh: seed sh so the closure reads it
      line(("__loop%d(sh)"):format(nfo.id))
    else
      emit_stmt_direct(st)
    end
  end
  line("::s_" .. (#top + 1) .. "::") -- fall-through target for a resume past the last loop

  ind = ind - 1
  line("end")
  return table.concat(out, "\n") .. "\n"
end

return M
