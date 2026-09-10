-- Per-case timing: for every spec case that PASSES (curse-interp output+status ==
-- bash), measure wall time under bash / curse-interp / curse-tiered / curse-compiled.
-- Reports the aggregate distribution and the cases where compiled most beats interp.
--
--   luajit lua/bench_cases.lua [reps] [file-substr…]
local ffi = require("ffi")
ffi.cdef [[ struct timespec { long tv_sec; long tv_nsec; }; int clock_gettime(int, struct timespec*); ]]
local ts = ffi.new("struct timespec[1]")
local function now() ffi.C.clock_gettime(1, ts); return tonumber(ts[0].tv_sec) * 1e9 + tonumber(ts[0].tv_nsec) end

local REPS = tonumber(arg[1]) or 3
local filters = {}
for k = 2, #arg do filters[#filters + 1] = arg[k] end

local ROOT = (io.popen("pwd"):read("*a") or ""):gsub("%s+$", "")
local SPEC = ROOT .. "/reference/oil/spec"
local LUAJIT = ROOT .. "/.bench-lua/luajit"
local RUNLUA = ROOT .. "/lua/run.lua"
local BUNDLE = ROOT .. "/dist/curse.bc"
local BINPATH = SPEC .. "/bin:" .. ROOT .. "/.bench-lua/shim"
local TMP = (os.getenv("TMPDIR") or "/tmp") .. "/curse-bench-" .. tostring(os.time())
os.execute("mkdir -p " .. TMP)
local cwd = TMP .. "/cwd"; os.execute("mkdir -p " .. cwd)
local codep = TMP .. "/case.sh"
local outp, stp = TMP .. "/out", TMP .. "/st"

local function readfile(p) local f = io.open(p, "r"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function writefile(p, s) local f = io.open(p, "w"); f:write(s); f:close() end

local function parse_cases(text)
  local cases, cur, inMeta = {}, nil, false
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local name = line:match("^#### (.*)")
    if name then
      if cur then cases[#cases + 1] = { name = cur.name, code = table.concat(cur.code, "\n") } end
      cur = { name = name, code = {} }; inMeta = false
    elseif cur then
      if line == "##" or line:sub(1, 3) == "## " then inMeta = true
      elseif not inMeta then cur.code[#cur.code + 1] = line end
    end
  end
  if cur then cases[#cases + 1] = { name = cur.name, code = table.concat(cur.code, "\n") } end
  local out = {}
  for _, c in ipairs(cases) do if c.code:match("%S") then out[#out + 1] = c end end
  return out
end

-- run one command string; return output, status
local function run(cmdstr, shval)
  os.execute("rm -rf " .. cwd .. "/* 2>/dev/null; cd " .. cwd ..
    " && { export LC_ALL=C TMP=" .. cwd .. " TMPDIR=" .. cwd .. " SH='" .. shval ..
    "' CURSE_BUNDLE=" .. BUNDLE .. " CURSE_LUAJIT=" .. LUAJIT .. " PATH=" .. BINPATH ..
    ":$PATH; timeout 10 " .. cmdstr .. " ; } >" .. outp .. " 2>/dev/null; echo $? >" .. stp)
  return readfile(outp) or "", tonumber((readfile(stp) or "0"):match("%d+") or "0")
end
-- best-of-REPS wall time (ns) for a command
local function timeit(cmdstr, shval)
  local best = math.huge
  for _ = 1, REPS do local t = now(); run(cmdstr, shval); local d = now() - t; if d < best then best = d end end
  return best
end

local bashcmd = "bash " .. codep
local curse = function(mode) return LUAJIT .. " " .. RUNLUA .. " " .. codep .. " " .. mode end

local files = {}
do
  local p = io.popen("ls " .. SPEC .. "/*.test.sh 2>/dev/null")
  if p then for line in p:lines() do files[#files + 1] = line end p:close() end
end
if #filters > 0 then
  local kept = {}
  for _, f in ipairs(files) do
    for _, s in ipairs(filters) do if f:find(s, 1, true) then kept[#kept + 1] = f; break end end
  end
  files = kept
end

-- accumulate timings for passing cases
local modes = { "bash", "interp", "tiered", "compiled" }
local samples = {} -- mode -> list of ns
for _, m in ipairs(modes) do samples[m] = {} end
local rows = {} -- {name, bash, interp, tiered, compiled}
local npass, ntotal = 0, 0

for _, path in ipairs(files) do
  for _, c in ipairs(parse_cases(readfile(path) or "")) do
    writefile(codep, c.code)
    local bout, bst = run(bashcmd, "bash")
    local iout, ist = run(curse("interp"), LUAJIT .. " " .. RUNLUA)
    ntotal = ntotal + 1
    if bout == iout and bst == ist then -- a passing case
      npass = npass + 1
      local tb = timeit(bashcmd, "bash")
      local ti = timeit(curse("interp"), LUAJIT .. " " .. RUNLUA)
      local tt = timeit(curse("tiered"), LUAJIT .. " " .. RUNLUA)
      local tc = timeit(curse("compiled"), LUAJIT .. " " .. RUNLUA)
      samples.bash[#samples.bash + 1] = tb
      samples.interp[#samples.interp + 1] = ti
      samples.tiered[#samples.tiered + 1] = tt
      samples.compiled[#samples.compiled + 1] = tc
      rows[#rows + 1] = { name = (path:match("[^/]+$") .. ": " .. c.name), bash = tb, interp = ti, tiered = tt, compiled = tc }
    end
  end
end

local function pctile(t, p)
  local s = {}; for i = 1, #t do s[i] = t[i] end; table.sort(s)
  if #s == 0 then return 0 end
  return s[math.max(1, math.floor(#s * p + 0.5))]
end
local function ms(ns) return ("%.2f"):format(ns / 1e6) end

io.write(("\nPer-case wall time over %d PASSING cases (best-of-%d), ms:\n"):format(npass, REPS))
io.write(("  %-10s %8s %8s %8s %8s\n"):format("mode", "min", "median", "p90", "max"))
for _, m in ipairs(modes) do
  local t = samples[m]
  io.write(("  %-10s %8s %8s %8s %8s\n"):format(m, ms(pctile(t, 0)), ms(pctile(t, 0.5)), ms(pctile(t, 0.9)), ms(pctile(t, 1.0))))
end

-- cases where compiled most beats bash (the compute-heavy ones)
table.sort(rows, function(a, b) return (a.bash / a.compiled) > (b.bash / b.compiled) end)
io.write("\nTop cases by bash/compiled speedup (compute-heavy):\n")
for i = 1, math.min(8, #rows) do
  local r = rows[i]
  io.write(("  %5.1fx  bash=%sms interp=%sms tiered=%sms compiled=%sms  %s\n")
    :format(r.bash / r.compiled, ms(r.bash), ms(r.interp), ms(r.tiered), ms(r.compiled), r.name:sub(1, 50)))
end
os.execute("rm -rf " .. TMP)
