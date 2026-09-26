-- Interpreter-fallback census: compile every corpus program (test/cases, bash tests,
-- each oil spec case) and tally what still runs through the interpreter — programs the
-- emitter refuses (`curse-nocompile:`, incl. cx.refuse's "no compiled form" by statement
-- kind), generated code that LOADFAILs, and interpreter entry points the generated code
-- calls. The goal is zero refusals.
--   build/luajit tools/delegate-census.lua [KEY]   (KEY: list the programs hitting it)
package.path = "lua/?.lua;" .. package.path
local P = require("parser")
local E = require("emit")
local progs = {}
local function slurp(p) local f = io.open(p) if not f then return nil end local s = f:read("*a") f:close() return s end
for p in io.popen("ls test/cases/*.sh subprojects/bash-5.2.21/tests/*.tests subprojects/bash-5.2.21/tests/*.sub"):lines() do
  progs[#progs+1] = { p, slurp(p) }
end
for p in io.popen("ls subprojects/oil/spec/*.test.sh"):lines() do
  local s = slurp(p); local n = 0; local cur
  for line in (s .. "\n"):gmatch("(.-)\n") do
    if line:match("^#### ") then
      if cur then progs[#progs+1] = { p .. "#" .. n, table.concat(cur, "\n") } end
      n = n + 1; cur = {}
    elseif cur then cur[#cur+1] = line end
  end
  if cur then progs[#progs+1] = { p .. "#" .. n, table.concat(cur, "\n") } end
end
local why, where, refs = {}, {}, {}
local nprog, nnoc, nlm = 0, 0, 0
for _, pr in ipairs(progs) do
  nprog = nprog + 1
  local okp, ast = pcall(P.parse, pr[2])
  if okp then
    local ok, err = pcall(E.emit, ast)
    if not ok and tostring(err):find("curse%-nocompile: line%-mode") and ast.lines then
      -- line mode (tier.lm_exec): each logical line compiles on its own at run time —
      -- tally the lines that can't (by reason)
      local bad
      for _, lg in ipairs(ast.lines) do
        if #lg.stmts > 0 then
          local lok, lerr = pcall(E.emit, { stmts = lg.stmts }, { fragment = true, lm = true })
          if not lok then bad = bad or tostring(lerr) end
        end
      end
      if bad then
        err = bad
      else
        ok, err = true, ""
        nlm = nlm + 1
      end
    end
    if ok and err ~= "" and not load(err) then -- (generated Lua that doesn't even load: a codegen bug)
      local k = "LOADFAIL " .. select(2, load(err)):sub(1, 50)
      why[k] = (why[k] or 0) + 1; where[k] = where[k] or {}; table.insert(where[k], pr[1])
    end
    if ok and type(err) == "string" then -- interpreter entry points in the generated code itself
      for ref in err:gmatch("[%w_]*[%.:]?[%w_]+%f[(]") do
        if ref:match("^I%.") or ref == "sh:capture_src" or ref == "rt.run_lazy" then
          local k = "emitted " .. ref
          refs[k] = (refs[k] or 0) + 1; where[k] = where[k] or {}; table.insert(where[k], pr[1])
        end
      end
    end
    if not ok then
      local r = tostring(err):match("curse%-nocompile: ([^\n]*)") or ("ERROR " .. tostring(err):sub(1, 60))
      nnoc = nnoc + 1; why[r] = (why[r] or 0) + 1; where[r] = where[r] or {}; table.insert(where[r], pr[1])
    end
  end
end
local function dump(t, title, lim)
  local ks = {} for k in pairs(t) do ks[#ks+1] = k end
  table.sort(ks, function(a, b) return t[a] > t[b] end)
  print("== " .. title)
  for i, k in ipairs(ks) do if i > (lim or 1e9) then break end
    print(("%6d %4d  %-36s e.g. %s"):format(t[k], #(where[k] or {}), k, (where[k] or {})[1] or "")) end
end
print(("programs %d  nocompile %d  line-mode %d"):format(nprog, nnoc, nlm))
dump(why, "nocompile reasons (programs)")
dump(refs, "interpreter calls in generated code")
if arg[1] then print("== programs for " .. arg[1]) for _, w in ipairs(where[arg[1]] or {}) do print(w) end end
