-- Tree-walking interpreter over the AST, mutating the shared `sh`. It starts
-- instantly (no compile) and runs statement-by-statement like bash. At each
-- safepoint — a top-level statement boundary and every loop back-edge — it
-- calls `hook(kind, id)`; the tier driver's hook throws {switch=true, resume=…}
-- when the compiled Lua is ready, unwinding here so execution can jump into the
-- compiled code from exactly this point (state is already in `sh`).
local rt = require("runtime")
local i64 = rt.i64

local M = {}

local function truth(n) return n ~= i64(0) end
local function b2i(b) return b and 1LL or 0LL end

local eval  -- arithmetic evaluator (forward decl)
eval = function(sh, e)
  local k = e.k
  if k == "num" then return rt.str_to_i64(e.v) end
  if k == "var" then return sh:aget(e.name) end
  if k == "un" then
    local v = eval(sh, e.e)
    if e.op == "-" then return -v end
    if e.op == "!" then return b2i(not truth(v)) end
  end
  if k == "bin" then
    local op = e.op
    if op == "&&" then return b2i(truth(eval(sh, e.l)) and truth(eval(sh, e.r))) end
    if op == "||" then return b2i(truth(eval(sh, e.l)) or truth(eval(sh, e.r))) end
    local l, r = eval(sh, e.l), eval(sh, e.r)
    if op == "+" then return l + r end
    if op == "-" then return l - r end
    if op == "*" then return l * r end
    if op == "/" then return l / r end
    if op == "%" then return l % r end
    if op == "==" then return b2i(l == r) end
    if op == "!=" then return b2i(l ~= r) end
    if op == "<" then return b2i(l < r) end
    if op == "<=" then return b2i(l <= r) end
    if op == ">" then return b2i(l > r) end
    if op == ">=" then return b2i(l >= r) end
  end
  if k == "asgn" then
    local v = eval(sh, e.e)
    if e.op ~= "=" then
      local cur = sh:aget(e.name)
      local o = e.op:sub(1, 1)
      if o == "+" then v = cur + v elseif o == "-" then v = cur - v
      elseif o == "*" then v = cur * v elseif o == "/" then v = cur / v
      elseif o == "%" then v = cur % v end
    end
    return sh:aset(e.name, v)
  end
  if k == "post" then
    local cur = sh:aget(e.name); sh:aset(e.name, cur + i64(e.d)); return cur
  end
  if k == "pre" then
    local v = sh:aget(e.name) + i64(e.d); return sh:aset(e.name, v)
  end
  error("interp: bad arith node " .. tostring(k))
end
M.eval = eval

local function expand_word(sh, w)
  local buf = {}
  for _, p in ipairs(w.parts) do
    if p.lit then buf[#buf + 1] = p.lit
    elseif p.var then buf[#buf + 1] = sh:get(p.var)
    elseif p.arith then buf[#buf + 1] = rt.i64_to_str(eval(sh, require("parser").arith(p.arith))) end
  end
  return table.concat(buf)
end

local exec_list  -- forward

local function exec_stmt(sh, st, hook)
  local t = st.t
  if t == "assign" then
    if st.arith then sh:aset(st.name, eval(sh, st.arith))
    else sh:set_str(st.name, expand_word(sh, st.rhs)) end
    sh.status = 0
  elseif t == "simple" then
    local args = {}
    for _, w in ipairs(st.words) do args[#args + 1] = expand_word(sh, w) end
    local cmd = args[1]
    if cmd == "echo" then
      sh:echo(table.unpack and table.unpack(args, 2) or unpack(args, 2))
    elseif cmd == ":" or cmd == "true" then sh.status = 0
    elseif cmd == "false" then sh.status = 1
    else error("interp subset: unknown command '" .. tostring(cmd) .. "'") end
  elseif t == "forc" then
    if st.init then eval(sh, st.init) end
    while true do
      hook("loop", st.id)
      if st.cond and not truth(eval(sh, st.cond)) then break end
      exec_list(sh, st.body, hook, false)
      if st.step then eval(sh, st.step) end
    end
  elseif t == "whilec" then
    while true do
      hook("loop", st.id)
      if not truth(eval(sh, st.cond)) then break end
      exec_list(sh, st.body, hook, false)
    end
  else
    error("interp: bad stmt " .. tostring(t))
  end
end

exec_list = function(sh, stmts, hook, toplevel)
  for k = 1, #stmts do
    if toplevel then hook("stmt", k) end
    exec_stmt(sh, stmts[k], hook)
  end
end
M.exec_list = exec_list

-- Run a whole program. `hook` defaults to a no-op (pure interpretation).
function M.run(sh, ast, hook)
  hook = hook or function() end
  exec_list(sh, ast.stmts, hook, true)
end

return M
