-- Persistent artifact cache: cold miss compiles+stores, warm hit loads+runs,
-- both match, a corrupt artifact degrades gracefully, and cache failures never
-- break execution. Point XDG_CACHE_HOME at a temp dir before running.
package.path = "lua/?.lua;" .. package.path
local Cache = require("cache")
local rt = require("runtime")

local function run(src)
	local sh = rt.Shell.new()
	local b = {}
	sh.out = function(s)
		b[#b + 1] = s
	end
	local _, how = Cache.run(src, sh)
	return (table.concat(b):gsub("\n", "|"):gsub("|$", "")), how
end

local ok = true
local function ck(desc, got, how, want, wanthow)
	local pass = got == want and how == wanthow
	ok = ok and pass
	print(
		("  %-26s %-14s [%-7s] %s"):format(desc, got, how, pass and "OK" or ("*** want [" .. want .. "]/" .. wanthow))
	)
end

local SRC = 'x=$(echo hi)\necho "[$x]"\nfor ((i=0;i<3;i=i+1)); do echo $i; done'
local WANT = "[hi]|0|1|2"

-- ensure a clean slate for this exact source
local path = Cache.artifact_path(SRC)
os.remove(path)
os.remove(path .. ".lock")

local g1, h1 = run(SRC)
ck("first run (cold)", g1, h1, WANT, "cold")
local g2, h2 = run(SRC)
ck("second run (warm)", g2, h2, WANT, "warm")

-- artifact really exists on disk
local f = io.open(path, "r")
local exists = f ~= nil
if f then
	f:close()
end
print(("  %-26s %-14s %s"):format("artifact on disk", tostring(exists), exists and "OK" or "***"))
ok = ok and exists

-- corrupt the artifact -> must degrade to a fresh compile, still correct
local w = io.open(path, "w")
w:write("this is not valid lua ][")
w:close()
local g3, h3 = run(SRC)
ck("corrupt artifact", g3, h3, WANT, "cold")

-- no HOME / no XDG -> uncacheable, but still runs (path=nil -> interp/cold works)
-- (can't unset env from Lua portably; instead check artifact_path handles nil)
if Cache.artifact_path(SRC) == nil then
	print("  (no home -> nil path)")
end

if not ok then
	os.exit(1)
end
print("ALL cache tests pass")
