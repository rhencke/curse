-- Proves the tiered-execution spine: the interpreter can hand off to compiled
-- Lua at ANY safepoint — a top-level statement boundary or, crucially for the
-- no-function hot-loop case, a loop back-edge mid-iteration — and produce a
-- bit-identical result, because both tiers mutate the same `sh`.
--   run:  luajit lua/test_tier.lua
package.path = "lua/?.lua;" .. package.path
local T = require("tier")

local N = 500000
local src = ("sum=0\nfor ((i=1; i<=%d; i++)); do sum=$((sum + i * 2 - 1)); done\necho $sum\n"):format(N)
local expect = tostring(N * N)

local function run(opts)
	opts = opts or {}
	local sh = T.rt.Shell.new()
	local buf = {}
	sh.out = function(s)
		buf[#buf + 1] = s
	end
	opts.sh = sh
	local t0 = os.clock()
	local _, how = T.run(src, opts)
	return (table.concat(buf):gsub("\n", "")), how, os.clock() - t0
end

print("=== OSR handoff correctness (expect " .. expect .. ") ===")
local cases = {
	{ "pure interpreter", {} },
	{ "switch at stmt boundary", { switch_after = 2 } },
	{ "switch mid-loop ~iter 1000", { switch_after = 1000 } },
	{ "switch mid-loop ~halfway", { switch_after = math.floor(N / 2) } },
	{ "switch after loop finished", { switch_after = N + 5 } },
}
local allok = true
for _, c in ipairs(cases) do
	local got, how, dt = run(c[2])
	local ok = got == expect
	allok = allok and ok
	print(("  %-28s %-15s %-14s %6.3fs  %s"):format(c[1], how, got, dt, ok and "OK" or "*** MISMATCH ***"))
end

print("\n=== tier speed on this loop (best of 3) ===")
local function best(opts)
	local b = math.huge
	for _ = 1, 3 do
		local _, _, dt = run(opts)
		if dt < b then
			b = dt
		end
	end
	return b
end
local ti = best({}) -- never switches -> pure interp
local tc = best({ switch_after = 1 }) -- switch immediately -> ~all compiled
print(("  interpreter : %6.3fs  (%.0f ns/iter)"):format(ti, ti / N * 1e9))
print(("  compiled    : %6.3fs  (%.0f ns/iter)  %.1fx vs interp"):format(tc, tc / N * 1e9, ti / tc))

-- Line mode compiles each line under the running script: it must not write a Lua global
-- (a leaked one is shared by every shell a daemon worker runs). The script text is unique
-- per run, so its lines miss the disk cache and really compile.
print("\n=== line mode writes no Lua globals ===")
do
	local sh = T.rt.Shell.new()
	local buf = {}
	sh.out = function(s)
		buf[#buf + 1] = s
	end
	local tag = ("%d%s"):format(os.time(), tostring({}):match("0x%x+") or "")
	local lsrc = "shopt -s expand_aliases\nalias say='echo'\nsay one " .. tag
		.. "\nfor i in 1 2; do say $i; done\n"
	setmetatable(_G, { __newindex = function(_, k)
		error("global write: " .. tostring(k), 2)
	end })
	local ok, err = pcall(T.run_lm, sh, lsrc)
	setmetatable(_G, nil)
	local got = table.concat(buf)
	local lok = ok and got == "one " .. tag .. "\n1\n2\n"
	allok = allok and lok
	print(("  %s  %s"):format(lok and "OK" or "*** FAIL ***", ok and got:gsub("\n", "|") or tostring(err)))
end

-- A compiled `$(…)` whose fd-level sink has no temp file (no writable $TMPDIR or /tmp:
-- rt.mktmpfd fails) captures into a Lua buffer: a builtin whose stdout is redirected
-- (`echo hi >&2`) must write the redirected fd, not that buffer (fuzz F22: `[hi]`).
print("\n=== compiled $(…) without a temp file: redirected builtin output ===")
do
	local rt = T.rt
	local sh = rt.Shell.new()
	local buf = {}
	sh.out = function(s)
		buf[#buf + 1] = s
	end
	local src = 'x=$(echo hi 2>/dev/null >&2); echo "[$x]"\n'
		.. 'f() { echo fn; }; y=$(f 2>/dev/null >&2); echo "[$y]"\n'
		.. 'z=$(echo a; echo b >/dev/null; echo c); echo "[$z]"\n'
		.. 'w=$(echo p; { echo q; } >/dev/null); echo "[$w]"\n'
	local mod = T.compile(require("parser").parse(src))
	local real = rt.mktmpfd
	rt.mktmpfd = function()
		return -1
	end
	local ok, err = pcall(T.run_compiled, mod, sh, nil)
	rt.mktmpfd = real
	local got = table.concat(buf)
	local want = "[]\n[]\n[a\nc]\n[p]\n"
	local cok = ok and got == want
	allok = allok and cok
	print(("  %s  %s"):format(cok and "OK" or "*** FAIL ***", ok and got:gsub("\n", "|") or tostring(err)))
end

if not allok then
	os.exit(1)
end
print("\nALL MATCH")
