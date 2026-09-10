-- curse LuaJIT-backend entry point.
--   luajit lua/run.lua <script.sh> [tiered|compiled|interp]
-- Modes:
--   tiered   (default) interpret from t=0 while a detached process transpiles,
--            then OSR into the compiled Lua. Needs $CURSE_LUAJIT (or "luajit").
--   compiled transpile + load + run (no interpreter window) — steady-state speed.
--   interp   pure tree-walking interpreter.
package.path = "lua/?.lua;" .. package.path
local T = require("tier")

local script = arg[1] or error("usage: run.lua <script.sh> [tiered|compiled|interp]")
local mode = arg[2] or "tiered"

if mode == "cached" then
  -- persistent artifact cache: warm hit skips parse+emit; cold compiles+stores;
  -- any cache failure falls back to running uncached. This is the CLI/build/boot
  -- path (one-shot invocations that recur), reported on stderr for visibility.
  local Cache = require("cache")
  local f = assert(io.open(script, "r")); local src = f:read("*a"); f:close()
  local sh = T.rt.Shell.new()
  local _, how = Cache.run(src, sh)
  if os.getenv("CURSE_CACHE_DEBUG") then io.stderr:write("[cache: " .. how .. "]\n") end
elseif mode == "tiered" then
  T.run_background(script, { luajit = os.getenv("CURSE_LUAJIT") or "luajit" })
else
  local f = assert(io.open(script, "r")); local src = f:read("*a"); f:close()
  local ast = T.parser.parse(src)
  local sh = T.rt.Shell.new()
  if mode == "compiled" then
    T.compile(ast).run(sh, nil)
  elseif mode == "interp" then
    T.interp.run(sh, ast)
  else
    error("unknown mode: " .. mode)
  end
end
