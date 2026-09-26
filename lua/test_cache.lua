-- Persistent artifact cache, driven the way the daemon drives it (tier.run_tiered): a cold
-- miss runs interpreted and defers its compile, the deferred compile stores the artifact,
-- a warm run uses it with nothing left to compile, a corrupt artifact degrades to a miss,
-- and cache failures never break execution. Point XDG_CACHE_HOME at a temp dir first.
package.path = "lua/?.lua;" .. package.path
local Cache = require("cache")
local T = require("tier")

local function run(src)
	local sh = T.rt.Shell.new()
	local b = {}
	sh.out = function(s)
		b[#b + 1] = s
	end
	T.run_tiered(src, sh)
	return (table.concat(b):gsub("\n", "|"):gsub("|$", ""))
end

local ok = true
local function ck(desc, pass)
	ok = ok and pass
	print(("  %-34s %s"):format(desc, pass and "OK" or "***"))
end
local function exists(path)
	local f = io.open(path, "r")
	if f then
		f:close()
	end
	return f ~= nil
end

local SRC = 'x=$(echo hi)\necho "[$x]"\nfor ((i=0;i<3;i=i+1)); do echo $i; done'
local WANT = "[hi]|0|1|2"

-- ensure a clean slate for this exact source
local path = Cache.artifact_path(SRC)
os.remove(path)
os.remove(path .. ".lock")

ck("first run (cold) output", run(SRC) == WANT)
ck("cold run defers its compile", T.has_deferred() and not exists(path))
T.compile_deferred()
ck("deferred compile stores artifact", exists(path) and Cache.load(path) ~= nil)
ck("second run (warm) output", run(SRC) == WANT)
ck("warm run compiles nothing", not T.has_deferred())

-- a corrupt artifact is a clean miss, never an error
local w = io.open(path, "w")
w:write("this is not valid lua ][")
w:close()
ck("corrupt artifact loads as nil", Cache.load(path) == nil)
-- an unwritable cache location fails the store, quietly
ck("unwritable store is false", Cache.store("/proc/curse-no-such/x.bc", "return {}") == false)

if not ok then
	os.exit(1)
end
print("ALL cache tests pass")
