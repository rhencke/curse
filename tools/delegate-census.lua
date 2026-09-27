-- Interpreter-fallback census: compile every corpus program (test/cases, bash tests,
-- each oil spec case, and synthetic programs past Lua's 200-locals / big-function limits)
-- and tally what still runs through the interpreter — programs the emitter refuses
-- (`curse-nocompile:`, incl. cx.refuse's "no compiled form" by statement kind), generated
-- code that LOADFAILs, and interpreter entry points the generated code calls. The goal is
-- zero refusals and zero LOADFAILs.
--
-- Every program is emitted as a whole program AND, with --modes, as a fragment in each of
-- the emit modes the tier asks for (tier.emit_opts: the letters trap_mode and
-- try_fragment build): every subset of E (ERR trap) D (DEBUG trap) H (trap handler line
-- numbering) L (trap LINENO), plus T B P F X V one at a time. A LOADFAIL is keyed by its
-- mode ("LOADFAIL [D] …"; "lm[…]" for a line-mode line).
--
--   build/luajit tools/delegate-census.lua [--modes] [--shard I/N] [--check FILE] [KEY]
--   KEY: list the programs hitting it.  --shard: only programs I, I+N, … (1-based).
--   --check FILE: exit 1 unless nocompile is 0 and every LOADFAIL/refusal key is one of
--   FILE's known entries ("COUNT<TAB>KEY  # work item" lines) with that count (a shard
--   only checks the keys). The meson test `census-N` runs --modes --check in shards.
package.path = "lua/?.lua;" .. package.path
local P = require("parser")
local E = require("emit")
local T = require("tier")
local MODES, SHARD_I, SHARD_N, CHECK, KEY = false, 1, 1, nil, nil
do
  local k = 1
  while arg[k] do
    local a = arg[k]
    if a == "--modes" then MODES = true
    elseif a == "--shard" then
      k = k + 1
      local i, n = (arg[k] or ""):match("^(%d+)/(%d+)$")
      SHARD_I, SHARD_N = tonumber(i), tonumber(n)
      assert(SHARD_I and SHARD_N and SHARD_I >= 1 and SHARD_I <= SHARD_N, "--shard I/N")
    elseif a == "--check" then k = k + 1; CHECK = arg[k]
    else KEY = a end
    k = k + 1
  end
end
local progs = {}
local function slurp(p) local f = io.open(p) if not f then return nil end local s = f:read("*a") f:close() return s end
for p in io.popen("ls test/cases/*.sh subprojects/bash-5.2.21/tests/*.tests subprojects/bash-5.2.21/tests/*.sub 2>/dev/null"):lines() do
  progs[#progs+1] = { p, slurp(p) }
end
for p in io.popen("ls subprojects/oil/spec/*.test.sh 2>/dev/null"):lines() do
  local s = slurp(p); local n = 0; local cur
  for line in (s .. "\n"):gmatch("(.-)\n") do
    if line:match("^#### ") then
      if cur then progs[#progs+1] = { p .. "#" .. n, table.concat(cur, "\n") } end
      n = n + 1; cur = {}
    elseif cur then cur[#cur+1] = line end
  end
  if cur then progs[#progs+1] = { p .. "#" .. n, table.concat(cur, "\n") } end
end
-- Synthetic programs past the limits a big script hits (Lua: 200 locals per function,
-- 255 registers, 60 upvalues): 250 top-level statements (assignments, lifted to locals),
-- 250 functions defined and each called in a loop body, one function of 250 statements
-- called 200 times, and all three in one program.
do
  local a, b, c = {}, { "for ((i = 0; i < 3; i++)); do" }, { "big() {" }
  for i = 1, 250 do
    a[#a+1] = ("v%d=%d; echo \"$v%d\""):format(i, i, i)
    b[#b+1] = ("  f%d() { echo %d; }; f%d"):format(i, i, i)
    c[#c+1] = ("  w%d=$((w%d + %d)); [ \"$w%d\" ] && x=$w%d"):format(i, i, i, i, i)
  end
  b[#b+1] = "done"
  c[#c+1] = "}"; c[#c+1] = "for ((j = 0; j < 200; j++)); do big; done"
  progs[#progs+1] = { "synthetic#250-statements", table.concat(a, "\n") }
  progs[#progs+1] = { "synthetic#250-calls-in-a-loop", table.concat(b, "\n") }
  progs[#progs+1] = { "synthetic#250-statement-function", table.concat(c, "\n") }
  progs[#progs+1] = { "synthetic#all", table.concat(a, "\n") .. "\n" .. table.concat(b, "\n") .. "\n" .. table.concat(c, "\n") }
end
-- the fragment modes swept with --modes
local modes = {}
if MODES then
  for m = 0, 15 do
    local s = ""
    for bit, l in ipairs({ "E", "D", "H", "L" }) do
      if math.floor(m / 2 ^ (bit - 1)) % 2 == 1 then s = s .. l end
    end
    modes[#modes+1] = s
  end
  for _, l in ipairs({ "T", "B", "P", "F", "X", "V" }) do modes[#modes+1] = l end
end
local why, where, refs = {}, {}, {}
local nprog, nnoc, nlm, nemit = 0, 0, 0, 0
local function note(t, k, p) k = k:gsub("%s+$", ""); t[k] = (t[k] or 0) + 1; where[k] = where[k] or {}; table.insert(where[k], p) end
local function loadfail(code, p, tag) -- (generated Lua that doesn't even load: a codegen bug)
  local f, e = load(code)
  if not f then note(why, "LOADFAIL " .. tag .. tostring(e):gsub("^%b[]:%d+: ", ""):sub(1, 50), p) end
end
for idx, pr in ipairs(progs) do
  if (idx - SHARD_I) % SHARD_N == 0 then
    nprog = nprog + 1
    local okp, ast = pcall(P.parse, pr[2])
    if okp then
      nemit = nemit + 1
      local ok, err = pcall(E.emit, ast)
      if not ok and tostring(err):find("curse%-nocompile: line%-mode") and ast.lines then
        -- line mode (tier.lm_exec): each logical line compiles on its own at run time —
        -- tally the lines that can't (by reason)
        local bad
        for _, lg in ipairs(ast.lines) do
          if #lg.stmts > 0 then
            local lok, lerr = pcall(E.emit, { stmts = lg.stmts }, { fragment = true, lm = true })
            if not lok then bad = bad or tostring(lerr) end
            if lok and lerr ~= "" then loadfail(lerr, pr[1], "lm ") end
            if lok and MODES then
              for _, m in ipairs(modes) do
                local mok, mcode = pcall(E.emit, { stmts = lg.stmts }, T.emit_opts(m, { fragment = true, lm = true }))
                nemit = nemit + 1
                if mok then loadfail(mcode, pr[1], "lm[" .. m .. "] ") end
              end
            end
          end
        end
        if bad then
          err = bad
        else
          ok, err = true, ""
          nlm = nlm + 1
        end
      end
      if ok and err ~= "" then loadfail(err, pr[1], "") end
      if ok and type(err) == "string" then -- interpreter entry points in the generated code itself
        for ref in err:gmatch("[%w_]*[%.:]?[%w_]+%f[(]") do
          if ref:match("^I%.") or ref == "sh:capture_src" or ref == "rt.run_lazy" then
            note(refs, "emitted " .. ref, pr[1])
          end
        end
      end
      if not ok then
        local r = tostring(err):match("curse%-nocompile: ([^\n]*)") or ("ERROR " .. tostring(err):sub(1, 60))
        nnoc = nnoc + 1; note(why, r, pr[1])
      end
      -- the whole program as a fragment, in every mode (a fresh parse: emit annotates the AST)
      if ok and err ~= "" and MODES then
        for _, m in ipairs(modes) do
          local okq, a2 = pcall(P.parse, pr[2])
          if okq then
            nemit = nemit + 1
            local mok, mcode = pcall(E.emit, a2, T.emit_opts(m, { fragment = true }))
            if mok then
              loadfail(mcode, pr[1], "[" .. m .. "] ")
            else
              local r = tostring(mcode):match("curse%-nocompile: ([^\n]*)")
              note(why, "fragment[" .. m .. "] " .. (r or ("ERROR " .. tostring(mcode):sub(1, 60))), pr[1])
            end
          end
        end
      end
    end
  end
end
local function dump(t, title, lim)
  local ks = {} for k in pairs(t) do ks[#ks+1] = k end
  table.sort(ks, function(a, b) if t[a] ~= t[b] then return t[a] > t[b] end return a < b end)
  print("== " .. title)
  for i, k in ipairs(ks) do if i > (lim or 1e9) then break end
    print(("%6d %4d  %-36s e.g. %s"):format(t[k], #(where[k] or {}), k, (where[k] or {})[1] or "")) end
end
print(("programs %d  nocompile %d  line-mode %d  emits %d%s"):format(nprog, nnoc, nlm, nemit,
  MODES and ("  (modes: whole program + fragment in " .. #modes .. " modes)") or ""))
dump(why, "nocompile reasons / LOADFAILs (programs)")
dump(refs, "interpreter calls in generated code")
if KEY then print("== programs for " .. KEY) for _, w in ipairs(where[KEY] or {}) do print(w) end end
if CHECK then
  -- known entries (a ratchet: each names the work item that removes it); anything new,
  -- or a count that moved, fails — update the file when a fix lands
  local known, bad = {}, nnoc > 0
  for line in io.lines(CHECK) do
    local c, k = line:match("^(%d+)\t(.-)%s*$")
    if c then known[(k:gsub("%s*#[^#]*$", ""))] = tonumber(c) end
  end
  for k, n in pairs(why) do
    if not known[k] then print(("census: NEW %s (%d)"):format(k, n)); bad = true
    elseif SHARD_N == 1 and known[k] ~= n then print(("census: %s: %d, known %d"):format(k, n, known[k])); bad = true end
  end
  if SHARD_N == 1 then
    for k, n in pairs(known) do
      if not why[k] then print(("census: %s: gone (known %d) — remove it from %s"):format(k, n, CHECK)); bad = true end
    end
  end
  print(bad and "census: FAIL" or "census: ok")
  os.exit(bad and 1 or 0)
end
