-- A signal preempts a JIT-compiled loop, whatever shape its machine code has: the async
-- handler (lib_cursesig.c) schedules a VM hook, which only fires in the interpreter, and
-- patches every jump that can close a cycle through the running trace so the trace
-- exits (curse.patch, curse_sig_patch_trace). A daemon worker is always catching the
-- terminating signals the client forwards, so a loop that never exits never ends the
-- script: `read -r x </dev/zero` outlived HUP/INT/TERM (stress daemon-client-kill).
-- Each loop below spins until a SIGALRM arrives (from a helper process, after 50ms) and
-- its handler raises; a loop that doesn't stop is SIGKILLed by a watchdog after 5s.
--   inverted_short/long  the loop's last guard is its back-edge (`jcc loop; jmp exit`),
--                        the realigned rel8 form and the rel32 one
--   side_exit            every iteration leaves through a side exit whose side trace
--                        links back to the root trace's head: the loop is never
--                        entered again
--   ffi_read             byte-at-a-time C.read of /dev/zero, as the `read` builtin does
package.path = "lua/?.lua;" .. package.path
local ffi = require("ffi")
require("runtime") -- (declares curse_sig_catch/curse_sig_default)
local C = ffi.C
pcall(ffi.cdef, "int getpid(void); int kill(int pid, int sig);")
local SIGALRM, SIGKILL = 14, 9
local me = tonumber(C.getpid())
-- a helper process that sends us `sig` after `secs`; its pid
local function after(secs, sig)
	local h = io.popen(string.format("(sleep %s; kill -%d %d) >/dev/null 2>&1 & echo $!", secs, sig, me))
	local pid = tonumber(h:read("*l"))
	h:close()
	return pid
end
C.curse_sig_catch(SIGALRM)
_G.__curse_sigrun = function(s)
	error({ sig = s }, 0)
end

local loops = {}
loops.inverted_short = function()
	local i = 0
	while i < 1e15 do
		i = i + 1
	end
	return i
end
loops.inverted_long = function()
	local i, a, b, c, d = 0, 1, 2, 3, 4
	while i < 1e15 do
		i = i + 1
		a = bit.bxor(a * 3 + b, c)
		b = bit.bxor(b * 5 + c, d)
		c = bit.bxor(c * 7 + d, a)
		d = bit.bxor(d * 11 + a, b)
		a = bit.band(a + b, 0xffff)
		b = bit.band(b + c, 0xffff)
		c = bit.band(c + d, 0xffff)
		d = bit.band(d + a, 0xffff)
		a = bit.bxor(a * 13 + b, c)
		b = bit.bxor(b * 17 + c, d)
		c = bit.bxor(c * 19 + d, a)
		d = bit.bxor(d * 23 + a, b)
		a = bit.band(a + b, 0xffff)
		b = bit.band(b + c, 0xffff)
		c = bit.band(c + d, 0xffff)
		d = bit.band(d + a, 0xffff)
	end
	return i + a + b + c + d
end
loops.side_exit = function()
	local n, a, b = 0, 0, 0
	while true do
		n = n + 1
		if n > 1000 then -- (recorded while n <= 1000: the other way from then on)
			b = b + 1
		else
			a = a + 1
		end
	end
end
loops.ffi_read = function()
	local fd = C.open("/dev/zero", 0, 0)
	local buf = ffi.new("char[1]")
	local got = 0
	local ok, e = pcall(function()
		while true do
			local n = C.read(fd, buf, 1)
			if n == 1 then
				got = got + 1
			elseif n < 0 then
				break
			end
		end
	end)
	C.close(fd)
	if not ok then
		error(e, 0)
	end
	return got
end

-- A counting handler preempts numeric `for` loops (inverted: the loop's last guard is
-- its FORL check) about every 200us; each must still run every iteration. The exit
-- taken on a signal must be the LOOP snapshot's: that guard's own exit resumes after
-- the loop (a FORL is not re-run), so taking it while the loop goes on ends it early —
-- as preempting via the guard's exit did (sig-hammer: a scheduler `for fd = lo, 9`
-- cut short left nils behind: "attempt to compare number with nil", double frees).
pcall(ffi.cdef, [[
struct curse_tsj_itv { long is, iu, vs, vu; };
int setitimer(int, const struct curse_tsj_itv *, struct curse_tsj_itv *);
]])
local function every(us)
	C.setitimer(0, ffi.new("struct curse_tsj_itv", 0, us, 0, us), nil)
end
local function for_exact()
	local hits = 0
	_G.__curse_sigrun = function()
		hits = hits + 1
	end
	every(200)
	local bad = 0
	for r = 1, 3000 do
		local n = 0
		for i = 1, 20000 do -- (short: a realigned rel8 back-edge)
			n = n + 1
		end
		local m, t = 0, 0
		for i = 1, 20000 do -- (longer: rel32)
			m = m + 1
			t = bit.bxor(t * 3 + i, m) % 65536
			t = bit.bxor(t * 5 + m, i) % 65536
			t = bit.bxor(t * 7 + i, m) % 65536
			t = bit.bxor(t * 11 + m, i) % 65536
			t = bit.bxor(t * 13 + i, m) % 65536
			t = bit.bxor(t * 17 + m, i) % 65536
		end
		if n ~= 20000 or m ~= 20000 then
			bad = bad + 1
		end
	end
	every(0)
	_G.__curse_sigrun = function(s)
		error({ sig = s }, 0)
	end
	return bad, hits
end

-- Preempted loops keep exact state: each workload runs once quietly (its traces get
-- compiled), then again under a counting handler every ~50us; the results must match.
-- Where the patch leaves a loop matters: at the back-edge, a PHI value the loop head
-- spills is one iteration stale in its slot, so leaving there through the loop
-- snapshot restored the previous `k` (wrong results in every run of these).
local function g(a, b)
	return (a * 31 + b) % 1000003
end
local work = {
	function(acc, r) -- repeat-until whose body inlines a call (k spilled at the head)
		local k = r
		repeat
			k = math.floor(k / 2)
			acc = g(acc, k)
		until k == 0
		return acc
	end,
	function(acc, r) -- a loop ending in plain arithmetic: a `jmp` back-edge
		local k, x = r, 0
		while true do
			k = math.floor(k / 2)
			acc = g(acc, k)
			if k == 0 then
				break
			end
			x = x + 1
		end
		return acc + x
	end,
	function(acc, r) -- string building and an iterator
		local s = ""
		for i = 1, 50 do
			s = s .. string.char(65 + (i + r) % 26)
		end
		for w in s:gmatch("[A-M]+") do
			acc = g(acc, #w)
		end
		return acc
	end,
}
local function state_exact()
	local bad = 0
	local hits = 0
	for n, f in ipairs(work) do
		local function run()
			local acc = 0
			for r = 1, 20000 do
				acc = f(acc, r)
			end
			return acc
		end
		_G.__curse_sigrun = function() end
		local want = run()
		_G.__curse_sigrun = function()
			hits = hits + 1
		end
		every(50)
		local got = run()
		every(0)
		if got ~= want then
			print(string.format("state_exact: workload %d: %s, want %s", n, got, want))
			bad = bad + 1
		end
	end
	_G.__curse_sigrun = function(s)
		error({ sig = s }, 0)
	end
	return bad, hits
end

local fails = 0
if not arg[1] or arg[1] == "state_exact" then
	local watchdog = after(60, SIGKILL)
	local bad, hits = state_exact()
	C.kill(watchdog, SIGKILL)
	print("state_exact: " .. (bad == 0 and "preempted loops computed exactly" or (bad .. " workloads wrong")) .. (hits > 20 and "" or " (NOT preempted: " .. hits .. ")"))
	if bad ~= 0 or hits <= 20 then
		fails = fails + 1
	end
end
if not arg[1] or arg[1] == "for_exact" then
	local watchdog = after(60, SIGKILL)
	local bad, hits = for_exact()
	C.kill(watchdog, SIGKILL)
	print("for_exact: " .. (bad == 0 and "every iteration ran" or (bad .. " loops cut short")) .. (hits > 20 and "" or " (NOT preempted: " .. hits .. ")"))
	if bad ~= 0 or hits <= 20 then
		fails = fails + 1
	end
end
for _, name in ipairs(arg and arg[1] and ((arg[1] == "for_exact" or arg[1] == "state_exact") and {} or { arg[1] }) or { "inverted_short", "inverted_long", "side_exit", "ffi_read" }) do
	local watchdog = after(5, SIGKILL)
	after(0.05, SIGALRM)
	local ok, e = pcall(loops[name])
	C.kill(watchdog, SIGKILL)
	if not ok and type(e) == "table" and e.sig == SIGALRM then
		print(name .. ": stopped by the signal")
	else
		print(name .. ": " .. (ok and "ended by itself" or ("error " .. tostring(e))))
		fails = fails + 1
	end
end
C.curse_sig_default(SIGALRM)
if fails > 0 then
	os.exit(1)
end
print("OK")
