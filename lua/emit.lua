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
  if k == "param" then return ("rt.str_to_i64(sh:param(%d))"):format(e.n) end
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
    elseif p.param then parts[#parts + 1] = ("sh:param(%d)"):format(p.param)
    elseif p.special then
      if p.special == "#" then parts[#parts + 1] = "tostring(sh:nparams())"
      elseif p.special == "@" or p.special == "*" then parts[#parts + 1] = 'sh:paramsJoin(" ")'
      elseif p.special == "?" then parts[#parts + 1] = "tostring(sh.status)" end
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

-- collect every variable NAME referenced in an arith node / word / stmt list.
local function collect_arith(e, set)
  if type(e) ~= "table" then return end
  if e.k == "var" or e.k == "asgn" or e.k == "post" or e.k == "pre" then set[e.name] = true end
  collect_arith(e.e, set); collect_arith(e.l, set); collect_arith(e.r, set)
end
local function collect_word(w, set)
  for _, p in ipairs(w.parts) do
    if p.var then set[p.var] = true
    elseif p.arith then collect_arith(require("parser").arith(p.arith), set) end
  end
end
local function collect_names(stmts, set)
  for _, st in ipairs(stmts) do
    if st.t == "assign" then
      set[st.name] = true
      if st.arith then collect_arith(st.arith, set) elseif st.rhs then collect_word(st.rhs, set) end
    elseif st.t == "simple" then
      for j = 2, #st.words do collect_word(st.words[j], set) end
      local cmd = st.words[1].parts[1] and st.words[1].parts[1].lit
      if cmd == "local" then
        for j = 2, #st.words do
          local p1 = st.words[j].parts[1]
          local nm = p1 and p1.lit and p1.lit:match("^([%a_][%w_]*)")
          if nm then set[nm] = true end
        end
      end
    elseif st.t == "forc" or st.t == "whilec" then
      collect_arith(st.init, set); collect_arith(st.cond, set); collect_arith(st.step, set)
      collect_names(st.body, set)
    elseif st.t == "forin" then
      set[st.name] = true
      for _, w in ipairs(st.words) do collect_word(w, set) end
      collect_names(st.body, set)
    elseif st.t == "if" then
      for _, cl in ipairs(st.clauses) do collect_arith(cl.cond, set); collect_names(cl.body, set) end
    elseif st.t == "funcdef" then
      collect_names(st.body, set)
    end
  end
end
-- every var any function body touches (lifting these at the top level would go
-- stale vs the function's sh-direct access).
local function collect_funcvars(stmts, set)
  for _, st in ipairs(stmts) do
    if st.t == "funcdef" then collect_names(st.body, set)
    elseif st.t == "forc" or st.t == "whilec" or st.t == "forin" then collect_funcvars(st.body, set)
    elseif st.t == "if" then for _, cl in ipairs(st.clauses) do collect_funcvars(cl.body, set) end end
  end
end

-- Which TOP-LEVEL vars can be int64 locals: assigned outside any function, every
-- assignment arithmetic or a numeric literal (reads never disqualify), and NOT
-- touched by any function.
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
      elseif st.t == "forin" then
        disq[st.name] = true -- a `for x in` var holds arbitrary strings, never lift it
        scan_stmts(st.body)
      elseif st.t == "if" then
        for _, cl in ipairs(st.clauses) do scan_stmts(cl.body) end
      end -- funcdef bodies are intentionally not scanned here
    end
  end
  scan_stmts(ast.stmts)
  local funcvars = {}
  collect_funcvars(ast.stmts, funcvars)
  local lifted = {}
  for n in pairs(assigned) do if not disq[n] and not funcvars[n] then lifted[n] = true end end
  return lifted
end

-- Does a function need a positional-param swap / a `local` frame? A call to a
-- function that needs neither is emitted bare (fn_x(sh)); one that needs only
-- params uses the lightweight pushParams; only `local` needs the full frame.
local function scan_arith_param(e, f)
  if type(e) ~= "table" then return end
  if e.k == "param" then f.params = true end
  scan_arith_param(e.e, f); scan_arith_param(e.l, f); scan_arith_param(e.r, f)
end
local function scan_word_param(w, f)
  for _, p in ipairs(w.parts) do
    if p.param or (p.special and p.special ~= "?") then f.params = true end -- $? is status, not $@
    if p.arith then scan_arith_param(require("parser").arith(p.arith), f) end
  end
end
local function func_flags(body)
  local f = { params = false, locals = false }
  local function scan(stmts)
    for _, st in ipairs(stmts) do
      if st.t == "simple" then
        local cmd = st.words[1].parts[1] and st.words[1].parts[1].lit
        if cmd == "local" then f.locals = true end
        for j = 2, #st.words do scan_word_param(st.words[j], f) end
      elseif st.t == "assign" then
        if st.arith then scan_arith_param(st.arith, f) elseif st.rhs then scan_word_param(st.rhs, f) end
      elseif st.t == "forc" or st.t == "whilec" then
        scan_arith_param(st.init, f); scan_arith_param(st.cond, f); scan_arith_param(st.step, f); scan(st.body)
      elseif st.t == "forin" then
        for _, w in ipairs(st.words) do scan_word_param(w, f) end; scan(st.body)
      elseif st.t == "if" then
        for _, cl in ipairs(st.clauses) do scan_arith_param(cl.cond, f); scan(cl.body) end
      end
    end
  end
  scan(body)
  return f
end

-- Build a pc-dispatch CFG for a statement list. Shared by the top-level `run`
-- and every function body. `funcflags[name] = {params,locals}` marks user
-- functions (a simple command that calls one) and how to slim its call.
-- Returns { blocks, npc, entry, loopPc, stmtPc, DONE }.
local function build_cfg(stmts, lifted, funcflags)
  local blocks = {}
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
    elseif t == "funcdef" then
      local p = newpc(); blocks[p] = ("pc = %d"):format(after); return p -- closures are hoisted
    elseif t == "simple" then
      local cmd = st.words[1].parts[1] and st.words[1].parts[1].lit
      if cmd == "return" then -- exit the current CFG (function or top level)
        local p = newpc()
        local n = st.words[2] and ("tonumber(%s)"):format(emit_word(st.words[2], lifted)) or "sh.status"
        blocks[p] = ("sh.status = (%s) or 0; pc = %d"):format(n, DONE)
        return p
      end
      local p = newpc()
      local args = {}
      for j = 2, #st.words do args[#args + 1] = emit_word(st.words[j], lifted) end
      local body
      if cmd == "echo" then body = "sh:echo(" .. table.concat(args, ", ") .. ")"
      elseif cmd == ":" or cmd == "true" then body = "sh.status = 0"
      elseif cmd == "false" then body = "sh.status = 1"
      elseif cmd == "local" then
        local ls = {}
        for _, a in ipairs(args) do ls[#ls + 1] = ("sh:localAssign(%s)"):format(a) end
        body = table.concat(ls, "; ") .. (#ls > 0 and "; " or "") .. "sh.status = 0"
      elseif funcflags[cmd] then
        local ff = funcflags[cmd]
        if ff.locals then -- full frame (save/restore shadowed vars + params)
          body = ("sh:pushCall({%s}); fn_%s(sh); sh:popCall()"):format(table.concat(args, ", "), cmd)
        elseif ff.params then -- positional swap only (no per-call frame table)
          body = ("sh:pushParams({%s}); fn_%s(sh); sh:popParams()"):format(table.concat(args, ", "), cmd)
        else -- neither: bare call, no allocation
          body = ("fn_%s(sh)"):format(cmd)
        end
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
    elseif t == "forin" then
      local initp = newpc()
      local advp = newpc(); loopPc[st.id] = advp -- back-edge = resume point
      local bodyentry = flatten_list(st.body, advp)
      -- init: expand the word list ONCE into sh.forstate[id] (so OSR resumes it)
      local parts = { "local __l = {}" }
      for _, w in ipairs(st.words) do
        if #w.parts == 1 and w.parts[1].var then
          parts[#parts + 1] = ("for _,p in ipairs(sh:split(sh:get(%q))) do __l[#__l+1]=p end"):format(w.parts[1].var)
        else
          parts[#parts + 1] = "__l[#__l+1] = " .. emit_word(w, lifted)
        end
      end
      parts[#parts + 1] = ("sh.forstate[%d] = {list=__l, idx=0}"):format(st.id)
      blocks[initp] = table.concat(parts, "; ") .. ("; pc = %d"):format(advp)
      blocks[advp] = ("local fs = sh.forstate[%d]; fs.idx = fs.idx + 1; if fs.idx > #fs.list then pc = %d else sh:set_str(%q, fs.list[fs.idx]); pc = %d end"):format(
        st.id, after, st.name, bodyentry)
      return initp
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

  flatten_list = function(list, after)
    local nextpc = after
    for k = #list, 1, -1 do nextpc = flatten_stmt(list[k], nextpc) end
    return nextpc
  end

  local nextpc = DONE
  for k = #stmts, 1, -1 do
    nextpc = flatten_stmt(stmts[k], nextpc)
    stmtPc[k] = nextpc
  end
  return { blocks = blocks, npc = npc, entry = stmtPc[1] or DONE, loopPc = loopPc, stmtPc = stmtPc }
end

-- Assemble a CFG into a Lua function string. `liftvars` (top-level only) are
-- seeded from `sh` on entry and written back on exit.
local function assemble(cfg, sig, liftvars, toplevel)
  local o = { sig }
  for _, n in ipairs(liftvars or {}) do o[#o + 1] = ("  local %s = sh:aget(%q)"):format(lname(n), n) end
  o[#o + 1] = toplevel and ("  pc = pc or %d"):format(cfg.entry) or ("  local pc = %d"):format(cfg.entry)
  o[#o + 1] = "  while true do"
  for p = 0, cfg.npc - 1 do
    o[#o + 1] = ("    %s pc == %d then %s"):format(p == 0 and "if" or "elseif", p, cfg.blocks[p])
  end
  o[#o + 1] = "    end"
  o[#o + 1] = "  end"
  for _, n in ipairs(liftvars or {}) do o[#o + 1] = ("  sh:aset(%q, %s)"):format(n, lname(n)) end
  o[#o + 1] = "end"
  return table.concat(o, "\n")
end

function M.emit(ast)
  local funcflags = {}
  for _, st in ipairs(ast.stmts) do if st.t == "funcdef" then funcflags[st.name] = func_flags(st.body) end end
  -- Lift top-level arith vars; analyze_lift already excludes any var a function
  -- touches (which would go stale vs the function's sh-direct access).
  local lifted = analyze_lift(ast)
  local liftvars = {}
  for n in pairs(lifted) do liftvars[#liftvars + 1] = n end
  table.sort(liftvars)

  local o = { 'local rt = require("runtime")' }
  -- forward-declare function locals so functions can call each other/forward
  local decls = {}
  for name in pairs(funcflags) do decls[#decls + 1] = "fn_" .. name end
  if #decls > 0 then o[#o + 1] = "local " .. table.concat(decls, ", ") end
  for _, st in ipairs(ast.stmts) do
    if st.t == "funcdef" then
      local cfg = build_cfg(st.body, {}, funcflags) -- function bodies are sh-direct
      o[#o + 1] = assemble(cfg, "fn_" .. st.name .. " = function(sh)", nil, false)
    end
  end
  local top = build_cfg(ast.stmts, lifted, funcflags)
  o[#o + 1] = "local loopPc = " .. serialize(top.loopPc)
  o[#o + 1] = "local stmtPc = " .. serialize(top.stmtPc)
  o[#o + 1] = assemble(top, "local function run(sh, pc)", liftvars, true)
  o[#o + 1] = "return { run = run, loopPc = loopPc, stmtPc = stmtPc }"
  return table.concat(o, "\n") .. "\n"
end

return M
