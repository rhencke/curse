-- Persistent artifact cache, driven the way the daemon drives it (tier.run_tiered): a cold
-- miss runs interpreted and defers its compile, the deferred compile stores the artifact,
-- a warm run LOADS it from disk and runs it with nothing left to compile, a corrupt artifact
-- degrades to a miss that recompiles and replaces it, and cache failures never break
-- execution. Each warm step drops the in-process module cache first (T.drop_modcache), else
-- the worker's own copy would serve it and the disk would go untested; Cache.load is
-- counted to prove the stored artifact is what ran. Point XDG_CACHE_HOME at a temp dir first.
package.path = "lua/?.lua;" .. package.path
local Cache = require("cache")
local T = require("tier")

-- (disk loads that produced a module: tier calls Cache.load through this same table)
local hits = 0
local real_load = Cache.load
Cache.load = function(p)
	local m = real_load(p)
	hits = hits + (m and 1 or 0)
	return m
end

local function run(src)
	local sh = T.rt.Shell.new()
	local b = {}
	sh.out = function(s)
		b[#b + 1] = s
	end
	T.run_tiered(src, sh)
	return (table.concat(b):gsub("\n", "|"):gsub("|$", ""))
end
local function warm_run(src)
	T.drop_modcache()
	hits = 0
	return run(src)
end

local ok = true
local function ck(desc, pass)
	ok = ok and pass
	print(("  %-38s %s"):format(desc, pass and "OK" or "***"))
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
ck("warm run output", warm_run(SRC) == WANT)
ck("warm run loaded the stored artifact", hits == 1)
ck("warm run compiles nothing", not T.has_deferred())
-- (and what runs IS the file: a planted artifact's own output comes back)
Cache.store(path, 'return { run = function(sh) sh.out("from disk\\n") end }')
ck("warm run executes the file on disk", warm_run(SRC) == "from disk" and hits == 1)

-- a corrupt artifact is a clean miss, never an error: the run is correct, recompiles, and
-- the store replaces the corrupt file
local w = io.open(path, "w")
w:write("this is not valid lua ][")
w:close()
ck("corrupt artifact loads as nil", Cache.load(path) == nil)
ck("corrupt artifact: output", warm_run(SRC) == WANT)
ck("corrupt artifact: a miss, recompiled", hits == 0 and T.has_deferred())
T.compile_deferred()
ck("corrupt artifact replaced", Cache.load(path) ~= nil)
ck("then warm again from disk", warm_run(SRC) == WANT and hits == 1)
-- an unwritable cache location fails the store, quietly
ck("unwritable store is false", Cache.store("/proc/curse-no-such/x.bc", "return {}") == false)

if not ok then
	os.exit(1)
end
print("ALL cache tests pass")
