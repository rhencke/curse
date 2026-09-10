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

local script = arg[1] or error("usage: run.lua <script.sh> [tiered|compiled|interp]")
local mode = arg[2] or "tiered"

local sh
if mode == "cached" then
  -- persistent artifact cache: warm hit skips parse+emit; cold compiles+stores;
  -- any cache failure falls back to running uncached. This is the CLI/build/boot
  -- path (one-shot invocations that recur), reported on stderr for visibility.
  local Cache = require("cache")
  local f = assert(io.open(script, "r")); local src = f:read("*a"); f:close()
  sh = T.rt.Shell.new(); sh.argv0 = script
  local _, how = Cache.run(src, sh)
  if os.getenv("CURSE_CACHE_DEBUG") then io.stderr:write("[cache: " .. how .. "]\n") end
elseif mode == "tiered" then
  sh = T.run_background(script, { luajit = os.getenv("CURSE_LUAJIT") or "luajit" })
else
  local f = assert(io.open(script, "r")); local src = f:read("*a"); f:close()
  sh = T.rt.Shell.new(); sh.argv0 = script
  if mode == "compiled" then
    T.compile(T.parser.parse(src)).run(sh, nil)
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
