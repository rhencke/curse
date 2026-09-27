-- Build reproducibility and compile-cache identity:
--  * lua/build.lua is deterministic — the same sources give the same bundle bytes, C array
--    and build id on every run (LuaJIT seeds its string hash per process; a plain
--    string.dump writes template tables in hash-node order);
--  * a syntax error's message (which compiled code embeds) carries no Lua source position,
--    so an artifact doesn't depend on where curse was built;
--  * a dev (from-sources) run's cache stamp covers deparse.lua, whose text compiled code
--    embeds (command text for $BASH_COMMAND, jobs, xtrace).
-- Run from the repo root with the built luajit (tools/run-lua.sh).
package.path = "lua/?.lua;" .. package.path
local lj = arg[-1] or "luajit"
if lj:find("/") and lj:sub(1, 1) ~= "/" then -- (the stamp check runs it from another dir)
	lj = os.getenv("PWD") .. "/" .. lj
end
local tmp = os.getenv("XDG_CACHE_HOME") or "/tmp"
local fails = 0
local function check(ok, what)
	if not ok then
		fails = fails + 1
		io.stderr:write("FAIL: " .. what .. "\n")
	end
end
local function slurp(p)
	local f = io.open(p, "rb")
	local s = f and f:read("*a")
	if f then
		f:close()
	end
	return s
end
local function sh(cmd)
	return os.execute(cmd) == 0
end

-- 1. two bundle builds, byte-identical (and the C array too)
for i = 1, 2 do
	check(sh(("%q lua/build.lua %q %q >/dev/null"):format(lj, tmp .. "/b" .. i .. ".bc", tmp .. "/b" .. i .. ".c")),
		"build.lua run " .. i)
end
local b1, b2 = slurp(tmp .. "/b1.bc"), slurp(tmp .. "/b2.bc")
check(b1 and b1 == b2, "bundle bytecode differs between two builds")
check(slurp(tmp .. "/b1.c") == slurp(tmp .. "/b2.c"), "bundle C array differs between two builds")

-- 2. parse_error messages carry no Lua position
local P = require("parser")
for _, src in ipairs({ "if then fi\n", "echo ${\n", "case x in\n", "f() { echo; \n", "for ((;;\n", "select\n" }) do
	local r = P.parse(src)
	local found = false
	for _, st in ipairs(r.stmts) do
		if st.t == "parse_error" then
			found = true
			check(not tostring(st.msg):find("%.lua:%d+:") and not tostring(st.msg):find("^[^ ]*:%d+: "),
				("parse_error message has a Lua position: %q -> %s"):format(src, tostring(st.msg)))
		end
	end
	check(found, ("no parse_error for %q"):format(src))
end

-- 3. the dev cache stamp changes when deparse.lua does (a copy of lua/ with it edited)
local function stamp_of(dir)
	local cmd = ("cd %q && XDG_CACHE_HOME=/c %q -e %q"):format(dir, lj,
		'package.path="./?.lua;"..package.path; io.write(require("cache").artifact_path("x"))')
	local p = io.popen(cmd)
	local s = p:read("*a")
	p:close()
	return s:match("^/c/curse/([^/]+)/")
end
local d1, d2 = tmp .. "/lua1", tmp .. "/lua2"
check(sh(("rm -rf %q %q && cp -r lua %q && cp -r lua %q"):format(d1, d2, d1, d2)), "copy lua/")
local f = io.open(d2 .. "/deparse.lua", "a")
f:write("\n-- edited\n")
f:close()
local s1, s2 = stamp_of(d1), stamp_of(d2)
check(s1 ~= nil and s2 ~= nil, "no cache stamp")
check(s1 ~= s2, "dev cache stamp ignores deparse.lua")
check(stamp_of(d1) == s1, "dev cache stamp not stable")

-- 4. main-chunk local headroom: LuaJIT caps a function at 200 locals, and a module's
-- top level at the cap can't take one more `local` (every fix that adds one fails to
-- load). Each core module must still load with HEADROOM extra top-level locals added
-- before its final `return`.
local HEADROOM = 10
local mods = io.popen("ls lua/*.lua")
for path in mods:lines() do
	if not path:find("^lua/test_") then
		local src = slurp(path)
		-- (before the last top-level `return`, which may span lines: `return function …`)
		local at = 0
		for i in src:gmatch("()\nreturn[%s({]") do
			at = i
		end
		local head, tail = src, ""
		if at > 0 then
			head, tail = src:sub(1, at), src:sub(at + 1)
		end
		local pad = {}
		for i = 1, HEADROOM do
			pad[i] = ("local __headroom%d = %d\n"):format(i, i)
		end
		local f, err = loadstring(head .. table.concat(pad) .. tail, "=" .. path)
		check(f ~= nil, ("%s: fewer than %d main-chunk locals of headroom (%s)"):format(path, HEADROOM, tostring(err)))
	end
end
mods:close()

if fails > 0 then
	os.exit(1)
end
print("ok")
