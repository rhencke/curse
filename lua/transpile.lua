-- Standalone transpiler: read a bash script, emit resumable Lua, write it out
-- atomically (temp + rename) so a poller never sees a partial file. Run detached
-- by the tier driver as the "compile in the background" process:
--   luajit lua/transpile.lua <script.sh> <out.lua>
package.path = "lua/?.lua;" .. package.path
local P, E = require("parser"), require("emit")

local script, out = arg[1], arg[2]
assert(script and out, "usage: transpile.lua <script.sh> <out.lua>")

local f = assert(io.open(script, "r"))
local src = f:read("*a"); f:close()

local code = E.emit(P.parse(src))

local tmp = out .. ".tmp." .. tostring(os.time()) .. tostring(math.random(1e6))
local o = assert(io.open(tmp, "w"))
o:write(code); o:close()
assert(os.rename(tmp, out)) -- atomic publish
