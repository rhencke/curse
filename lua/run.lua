-- curse LuaJIT-backend entry point.
--   luajit lua/run.lua <script.sh> [tiered|compiled|interp]
-- Modes:
--   tiered   (default) interpret from t=0 while a detached process transpiles,
--            then OSR into the compiled Lua. Needs $CURSE_LUAJIT (or "luajit").
--   compiled transpile + load + run (no interpreter window) — steady-state speed.
--   interp   pure tree-walking interpreter.
-- Prefer a precompiled bytecode bundle (one file open, no source parsing —
-- ~1ms/invocation faster). Fall back to loading modules from source if the
-- bundle is absent or unloadable (e.g. built for a different LuaJIT).
local bundle = os.getenv("CURSE_BUNDLE") or "dist/curse.bc"
local bf = io.open(bundle, "rb")
if bf then
  bf:close()
  if not pcall(function() assert(loadfile(bundle))() end) then
    package.path = "lua/?.lua;" .. package.path
  end
else
  package.path = "lua/?.lua;" .. package.path
end
local T = require("tier")

local sh

-- Collect leading shell options (as `sh -e -u -o NAME -O NAME` before -c/script).
local ai, presets = 1, {}
local rcfile, norc -- --rcfile FILE / --norc: an interactive shell sources FILE first
while true do
  local a = arg[ai]
  if a == "-e" or a == "+e" then presets[#presets + 1] = { f = "opt_e", on = a == "-e" }; ai = ai + 1
  elseif a == "-i" then presets[#presets + 1] = { f = "opt_i", on = true }; ai = ai + 1
  elseif a == "-x" or a == "+x" then presets[#presets + 1] = { f = "opt_x", on = a == "-x" }; ai = ai + 1
  elseif a == "-l" or a == "--login" or a == "-v" or a == "+v"
    or a == "-s" or a == "-B" or a == "+B" or a == "-h" or a == "+h" then ai = ai + 1 -- accepted, no-op
  elseif a == "--help" then
    io.write("curse: a bash-compatible shell.\nusage: curse [options] [script [args]]\n"); os.exit(0)
  elseif a == "--" or a == "-" then ai = ai + 1; break -- end of options (script/args follow)
  elseif a == "-u" or a == "+u" then presets[#presets + 1] = { f = "opt_u", on = a == "-u" }; ai = ai + 1
  elseif a == "-C" or a == "+C" then presets[#presets + 1] = { f = "opt_C", on = a == "-C" }; ai = ai + 1
  elseif a == "-o" or a == "+o" then presets[#presets + 1] = { o = arg[ai + 1], on = a == "-o" }; ai = ai + 2
  elseif a == "-O" or a == "+O" then presets[#presets + 1] = { shopt = arg[ai + 1], on = a == "-O" }; ai = ai + 2
  elseif a == "--norc" or a == "--noprofile" then norc = true; ai = ai + 1
  elseif a == "--rcfile" then rcfile = arg[ai + 1]; ai = ai + 2
  elseif a and a:match("^%-[eiuxCoOlvsBh]+$") and #a > 2 then
    -- bundled short flags: `-eu`, `-oo errexit noglob`, `-ex` … (bash bundles
    -- single-char options; each `o`/`O` in the bundle takes the NEXT word as its
    -- argument, consumed left-to-right).
    local wi = ai
    for k = 2, #a do
      local f = a:sub(k, k)
      if f == "e" then presets[#presets + 1] = { f = "opt_e", on = true }
      elseif f == "u" then presets[#presets + 1] = { f = "opt_u", on = true }
      elseif f == "x" then presets[#presets + 1] = { f = "opt_x", on = true }
      elseif f == "C" then presets[#presets + 1] = { f = "opt_C", on = true }
      elseif f == "i" then presets[#presets + 1] = { f = "opt_i", on = true }
      elseif f == "o" then wi = wi + 1; presets[#presets + 1] = { o = arg[wi], on = true }
      elseif f == "O" then wi = wi + 1; presets[#presets + 1] = { shopt = arg[wi], on = true }
      end -- l/v/s/B/h: accepted no-ops
    end
    ai = wi + 1
  else break end
end
-- `-o NAME` / `+o NAME`: same long-option names as the `set -o` builtin.
local OMAP = { errexit = "opt_e", errtrace = "opt_errtrace", functrace = "opt_functrace",
  hashall = "opt_h", histexpand = "opt_H", history = "opt_history", ignoreeof = "opt_ignoreeof",
  ["interactive-comments"] = "opt_icomments", keyword = "opt_k", monitor = "opt_m",
  noclobber = "opt_C", noexec = "opt_n", noglob = "opt_f", nolog = "opt_nolog",
  notify = "opt_b", nounset = "opt_u", onecmd = "opt_t", physical = "opt_P",
  pipefail = "opt_pipefail", posix = "opt_posix", privileged = "opt_p", verbose = "opt_v",
  vi = "opt_vi", xtrace = "opt_x" }
-- Which shell are we mimicking? By our invocation basename, like busybox/bash
-- (bash run as `sh` goes posix). The wrapper/launcher forwards its $0 as
-- CURSE_ARGV0; absent that, we default to bash. Drives \s (prompt) and, for a
-- posix-named invocation, posix mode.
local SHELLNAME = (os.getenv("CURSE_ARGV0") or "bash"):match("[^/]+$") or "bash"
local SH_IS_POSIX = SHELLNAME == "sh" or SHELLNAME == "dash" or SHELLNAME == "ash"
local function apply(s)
  s.shellname = SHELLNAME
  if SH_IS_POSIX then s.opt_posix = true end
  -- Options inherited via an exported $SHELLOPTS (set by a parent shell): enable
  -- each named set -o option we recognize, so e.g. cross-process `set -x` traces.
  if s.shellopts_import then
    for name in s.shellopts_import:gmatch("[^:]+") do if OMAP[name] then s[OMAP[name]] = true end end
  end
  for _, p in ipairs(presets) do
    if p.f then s[p.f] = p.on
    elseif p.o and OMAP[p.o] then s[OMAP[p.o]] = p.on
    elseif p.shopt then s.shopt[p.shopt] = p.on end
  end
end

-- An interactive shell sources --rcfile (unless --norc) before running -c/REPL; a
-- real `exit` in the rc file ends the whole shell here (skipping -c), like bash.
local function source_rc(sh)
  if not (sh.opt_i and rcfile and not norc) then return end
  local ok, err = pcall(T.interp.source_file, sh, rcfile)
  if not ok then
    if type(err) == "table" and err.__curse_exit then io.flush(); os.exit(err.__curse_exit)
    else error(err) end
  end
end

-- Consume one option token into `presets`; returns tokens consumed, or 0 if `a`
-- is not a recognized option (bash accepts these both leading and after -c).
local function opt_consume(a, nexta)
  if a == "-e" or a == "+e" then presets[#presets + 1] = { f = "opt_e", on = a == "-e" }; return 1
  elseif a == "-u" or a == "+u" then presets[#presets + 1] = { f = "opt_u", on = a == "-u" }; return 1
  elseif a == "-C" or a == "+C" then presets[#presets + 1] = { f = "opt_C", on = a == "-C" }; return 1
  elseif a == "-i" then presets[#presets + 1] = { f = "opt_i", on = true }; return 1
  elseif a == "-x" or a == "+x" then presets[#presets + 1] = { f = "opt_x", on = a == "-x" }; return 1
  elseif a == "-l" or a == "--login" or a == "-v" or a == "+v"
    or a == "-s" or a == "-B" or a == "+B" or a == "-h" or a == "+h" then return 1 -- accepted, no-op
  elseif a == "-o" or a == "+o" then presets[#presets + 1] = { o = nexta, on = a == "-o" }; return 2
  elseif a == "-O" or a == "+O" then presets[#presets + 1] = { shopt = nexta, on = a == "-O" }; return 2
  elseif a == "--norc" or a == "--noprofile" then return 1
  elseif a == "--rcfile" then return 2 end
  return 0
end

-- `-c CODE [name [args…]]` — run a command string like `sh -c` (`+c` is accepted).
if arg[ai] == "-c" or arg[ai] == "+c" then
  -- bash keeps parsing options after -c until a non-option word (the command
  -- string) or a terminator (`-`/`--`); an unrecognized option is a usage error.
  local j = ai + 1
  while true do
    local a = arg[j]
    if a == nil then io.stderr:write("curse: -c: option requires an argument\n"); io.flush(); os.exit(2)
    elseif a == "--" or a == "-" then j = j + 1; break
    elseif a:sub(1, 1) == "-" or a:sub(1, 1) == "+" then
      local n = opt_consume(a, arg[j + 1])
      if n == 0 then io.stderr:write("curse: " .. a .. ": invalid option\n"); io.flush(); os.exit(2) end
      j = j + n
    else break end -- the command string
  end
  local code = arg[j]
  if code == nil then io.stderr:write("curse: -c: option requires an argument\n"); io.flush(); os.exit(2) end
  sh = T.rt.Shell.new(); apply(sh); sh.opt_c = true
  -- an interactive shell sets $HISTFILE (bash), even for `-i -c`
  if sh.opt_i and sh.vars.HISTFILE == nil then sh:set_str("HISTFILE", (os.getenv("HOME") or "") .. "/.bash_history"); sh.histfile_default = true end
  sh.argv0 = arg[j + 1] or SHELLNAME -- $0 defaults to the shell name (bash), not "curse"
  for k = j + 2, #arg do sh.nparams = sh.nparams + 1; sh.params[sh.nparams] = arg[k] end
  source_rc(sh) -- interactive: --rcfile is sourced before the command string
  T.interp.run_lazy(sh, code)
  io.flush(); os.exit(sh.status or 0)
end

-- No script argument. With a tty on stdin (or -i) start the REPL; otherwise read
-- commands from stdin and run them non-interactively (e.g. `echo cmd | sh`).
if arg[ai] == nil then
  sh = T.rt.Shell.new(); apply(sh); sh.argv0 = SHELLNAME -- $0 = the shell name (bash)
  local istty = require("ffi").C.isatty(0) == 1
  if sh.opt_i or istty then
    sh.opt_i = true
    if sh.vars.HISTFILE == nil then sh:set_str("HISTFILE", (os.getenv("HOME") or "") .. "/.bash_history"); sh.histfile_default = true end
    source_rc(sh) -- --rcfile sourced before the interactive session
    require("repl").run(sh)
  else
    local src = io.read("*a") or ""
    T.interp.run_lazy(sh, src)
  end
  io.flush(); os.exit(sh.status or 0)
end

local script = arg[ai] or error("usage: run.lua <script.sh> [tiered|compiled|interp] | -c CODE | -i")
-- arg[ai+1] is the execution mode ONLY if it's a known mode keyword; otherwise it
-- (and the rest) are the script's positional parameters ($1, $2, …), like bash.
local MODES = { tiered = true, compiled = true, interp = true, cached = true }
local mode, pstart = "tiered", ai + 1
if arg[ai + 1] and MODES[arg[ai + 1]] then mode = arg[ai + 1]; pstart = ai + 2 end
-- A missing/unreadable script is exit 127 (bash), not a Lua assert crash.
do local sf = io.open(script, "r"); if sf then sf:close() else
  io.stderr:write("curse: " .. script .. ": No such file or directory\n"); io.flush(); os.exit(127) end end
local function setparams(s) for k = pstart, #arg do s.nparams = s.nparams + 1; s.params[s.nparams] = arg[k] end end
if mode == "cached" then
  -- persistent artifact cache: warm hit skips parse+emit; cold compiles+stores;
  -- any cache failure falls back to running uncached. This is the CLI/build/boot
  -- path (one-shot invocations that recur), reported on stderr for visibility.
  local Cache = require("cache")
  local f = assert(io.open(script, "r")); local src = f:read("*a"); f:close()
  sh = T.rt.Shell.new(); apply(sh); sh.argv0 = script; setparams(sh)
  local _, how = Cache.run(src, sh)
  if os.getenv("CURSE_CACHE_DEBUG") then io.stderr:write("[cache: " .. how .. "]\n") end
elseif mode == "tiered" then
  sh = T.rt.Shell.new(); apply(sh); sh.argv0 = script; setparams(sh)
  T.run_background(script, { luajit = os.getenv("CURSE_LUAJIT") or "luajit", sh = sh })
else
  local f = assert(io.open(script, "r")); local src = f:read("*a"); f:close()
  sh = T.rt.Shell.new(); apply(sh); sh.argv0 = script; setparams(sh)
  if mode == "compiled" then
    local mod = T.compile(T.parser.parse(src))
    T.interp.finish_run(sh, function() T.run_compiled(mod, sh, nil) end)
  elseif mode == "interp" then
    T.interp.run_lazy(sh, src) -- lazy: instant start, never parses past exit
  else
    error("unknown mode: " .. mode)
  end
end

-- Propagate $? as the process exit code (so `exit N`, `false`, etc. are visible
-- to the caller — and to the spec runner). Flush buffered stdout first.
io.flush()
os.exit(sh and sh.status or 0)
