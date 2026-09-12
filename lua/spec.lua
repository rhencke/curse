-- Oils spec-test conformance runner for the LuaJIT backend (progress scoreboard,
-- the analogue of test/spec/run.mts for the TS backend). Parses Oils'
-- spec/*.test.sh cases and runs each snippet through real bash (the oracle) and
-- through curse-Lua, comparing stdout + exit status. Most cases fail until the
-- matching feature lands; the pass-rate is the scoreboard.
--
--   luajit lua/spec.lua [--interp|--compiled|--cached] [--verbose] [file-substr…]
--
-- Runs each case as a SUBPROCESS with a timeout, so a hanging/exiting/crashing
-- case can't take down the runner (correctness of the scoreboard first; speed
-- of the runner second).
local mode = "interp"
local verbose = false
local diff = false
local filters = {}
for _, a in ipairs(arg) do
  if a == "--interp" or a == "--compiled" or a == "--cached" then mode = a:sub(3)
  elseif a == "--verbose" then verbose = true
  elseif a == "--diff" then verbose = true; diff = true
  elseif a:sub(1, 2) == "--" then -- ignore unknown flags
  else filters[#filters + 1] = a end
end

-- Absolute paths: each case runs in its own cwd, so the luajit binary, run.lua,
-- and the bundle must be absolute or they'd resolve against the case's cwd.
local ROOT = (io.popen("pwd"):read("*a") or ""):gsub("%s+$", "")
local SPEC = ROOT .. "/reference/oil/spec"
local LUAJIT = ROOT .. "/.bench-lua/luajit"
local RUNLUA = ROOT .. "/lua/run.lua"
local BUNDLE = ROOT .. "/dist/curse.bc"
local TIMEOUT = 2 -- cases are tiny; this only bounds hangs (e.g. `while true`)

-- temp workspace (per run); each case gets a fresh cwd so file side effects don't
-- leak between cases (matches run.mts).
local TMP = (os.getenv("TMPDIR") or "/tmp") .. "/curse-spec-" .. tostring(os.time())
os.execute("mkdir -p " .. TMP)

-- $SH must be a SINGLE command for tests that use it quoted (`"$SH" -c …`), like
-- Oils' single-binary shells. curse is `luajit run.lua`, so wrap it in a tiny
-- exec script and hand tests that path.
--
-- We NAME that wrapper after the shell curse is impersonating (`bash`). Oils'
-- suite branches per shell via `case $SH in …`; the glob arms (`*bash|*osh`)
-- key off $SH ENDING in the shell name, so a wrapper at `…/bash` takes bash's
-- branch — the correct branch for a bash-compatible shell — instead of falling
-- to `*)`. The harness still INVOKES curse explicitly (curse_cmd, below), so
-- $SH is only the identity string test code sees; `"$SH" -c …` runs this
-- wrapper (= curse) and a hardcoded `bash` in a test body still runs real bash.
-- (Point SHNAME at "dash"/"sh" to run the suite as those shells later.)
local SHNAME = "bash"
local SH = TMP .. "/" .. SHNAME
do
  local f = io.open(SH, "w")
  f:write("#!/bin/sh\nexport CURSE_BUNDLE=" .. BUNDLE .. "\nexec " .. LUAJIT .. " " .. RUNLUA .. ' "$@"\n')
  f:close(); os.execute("chmod +x " .. SH)
end

local function readfile(p) local f = io.open(p, "r"); if not f then return nil end local s = f:read("*a"); f:close(); return s end

-- A case is OSH/YSH-specific — NOT a bash-behavior test — when its `case $SH in
-- … esac` guard sends bash to exit/return (bash skips the whole case). curse
-- targets bash only, so such cases are excluded from the scoreboard (like the
-- ysh-*/hay* files). Detected by: a guard clause whose pattern matches "bash"
-- and whose body begins with exit/return.
local function osh_only(code)
  for seg in code:gmatch("case%s+%$SH%s+in(.-)esac") do
    for pats, bw in seg:gmatch("([%w%*%?@_%-%.:| ]+)%)%s*(%a+)") do
      if bw == "exit" or bw == "return" then
        for alt in (pats .. "|"):gmatch("%s*([%w%*%?@_%-%.:]+)%s*|") do
          local pat = "^" .. alt:gsub("[%.%-]", "%%%0"):gsub("%*", ".*"):gsub("%?", ".") .. "$"
          if ("bash"):match(pat) then return true end
        end
      end
    end
  end
  return false
end

-- ---- case parser (mirrors test/spec/run.mts exactly) ----
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
  for _, c in ipairs(cases) do
    if c.code:match("%S") and not osh_only(c.code) then out[#out + 1] = c end
  end
  return out
end

-- Run `argv` (a shell command string) with a timeout in `cwd`, capturing stdout
-- and the exit status; stderr is discarded (we compare stdout+status like run.mts).
local outp = TMP .. "/out"
local stp = TMP .. "/st"
-- The Oils harness puts spec/bin (argv.py etc.) on PATH; mirror that so
-- argv.py-based cases are meaningful for both bash and curse.
local BINPATH = SPEC .. "/bin:" .. ROOT .. "/.bench-lua/shim" -- argv.py + python2 shim
-- Cap captured stdout: an unbounded producer (`yes`, `cat /dev/zero`) streams
-- forever, so pipe through `head -c` — bounding the file AND closing the pipe
-- early (SIGPIPE) so the case terminates fast instead of running to `timeout`.
-- The cap is far larger than any real spec output, and applied identically to
-- both shells, so it never changes a comparison. `$?` is recorded to a separate
-- file (not the piped stdout) so the real exit status survives the `| head`.
local CAP = 4000000
local function run(cmdstr, cwd, shval)
  os.execute("cd " .. cwd .. " && { export LC_ALL=C TMP=" .. cwd .. " TMPDIR=" .. cwd ..
    " SH='" .. shval .. "' CURSE_BUNDLE=" .. BUNDLE .. " PATH=" .. BINPATH .. ":$PATH; timeout " .. TIMEOUT ..
    " " .. cmdstr .. " ; echo $? >" .. stp .. "; } 2>/dev/null | head -c " .. CAP .. " >" .. outp)
  return readfile(outp) or "", tonumber((readfile(stp) or "0"):match("%d+") or "0")
end

-- ---- list spec files ----
local files = {}
do
  local p = io.popen("ls " .. SPEC .. "/*.test.sh 2>/dev/null")
  if p then for line in p:lines() do files[#files + 1] = line end p:close() end
end
-- OSH's spec suite bundles YSH (Oil's OWN language) tests — ysh-*, hay*, tea*.
-- curse targets BASH compatibility ONLY (it does not implement the YSH language),
-- so the default scoreboard runs just the bash-compat files. An explicit
-- file-substring filter can still select an excluded file, for debugging.
local function is_oil(path)
  local b = path:match("[^/]+$") or ""
  return b:match("^ysh%-") or b:match("^hay") or b:match("^tea")
    or b:match("^osh%-") or b:match("%-osh%.test") -- OSH-specific files (errexit-osh, osh-bugs)
end
if #filters > 0 then
  local kept = {}
  for _, f in ipairs(files) do
    for _, s in ipairs(filters) do if f:find(s, 1, true) then kept[#kept + 1] = f; break end end
  end
  files = kept
else
  local kept = {}
  for _, f in ipairs(files) do if not is_oil(f) then kept[#kept + 1] = f end end
  files = kept
end

local codep = TMP .. "/case.sh"
local function write_code(code) local f = io.open(codep, "w"); f:write(code); f:close() end

-- curse invocation for the chosen mode (absolute paths; script-file form). Uses
-- `env` for the var so it survives the `timeout` wrapper (timeout would try to
-- exec a bare VAR=val assignment as a program).
local function curse_cmd()
  local envp = (io.open(BUNDLE, "r") and ("env CURSE_BUNDLE=" .. BUNDLE .. " ") or "")
  return envp .. LUAJIT .. " " .. RUNLUA .. " " .. codep .. " " .. mode
end

local total, totalPass = 0, 0
local perFile = {}
for _, path in ipairs(files) do
  local cases = parse_cases(readfile(path) or "")
  local cwd = TMP .. "/cwd"; os.execute("rm -rf " .. cwd .. "; mkdir -p " .. cwd)
  local pass = 0
  for _, c in ipairs(cases) do
    write_code(c.code)
    local bout, bst = run("bash " .. codep, cwd, "bash")
    os.execute("rm -rf " .. cwd .. "/*  2>/dev/null")
    local cout, cst = run(curse_cmd(), cwd, SH)
    os.execute("rm -rf " .. cwd .. "/* 2>/dev/null")
    if bout == cout and bst == cst then
      pass = pass + 1
    elseif verbose then
      io.write(("  FAIL %s: %s\n"):format(path:match("[^/]+$"), c.name))
      if diff then
        io.write(("    CODE: %s\n    bash=[%s](%d)  curse=[%s](%d)\n")
          :format(c.code:gsub("\n", "\\n"), bout:gsub("\n", "\\n"), bst, cout:gsub("\n", "\\n"), cst))
      end
    end
    total = total + 1
  end
  totalPass = totalPass + pass
  perFile[#perFile + 1] = { file = path:match("[^/]+$"), pass = pass, n = #cases }
end

table.sort(perFile, function(a, b) return a.n > b.n end)
io.write("\nper-file (pass/total):\n")
for _, f in ipairs(perFile) do
  local pct = f.n == 0 and 0 or math.floor(f.pass / f.n * 100 + 0.5)
  io.write(("  %3d/%3d  %3d%%  %s\n"):format(f.pass, f.n, pct, f.file))
end
local pct = total == 0 and "0" or ("%.1f"):format(totalPass / total * 100)
io.write(("\nspec conformance (%s vs bash): %d/%d cases (%s%%) across %d files\n")
  :format(mode, totalPass, total, pct, #files))
os.execute("rm -rf " .. TMP)
