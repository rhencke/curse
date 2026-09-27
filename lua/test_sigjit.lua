-- A signal preempts a JIT-compiled loop, whatever shape its machine code has: the async
-- handler (lib_cursesig.c) schedules a VM hook, which only fires in the interpreter, and
-- repoints the running trace's loop back-edge so the trace exits (curse.patch,
-- curse_sig_patch_trace). A daemon worker is always catching the terminating signals the
-- client forwards, so a loop the patch can't break never ends the script: `read -r x
-- </dev/zero` outlived HUP/INT/TERM (stress daemon-client-kill). Each loop below spins
-- until a SIGALRM arrives (ITIMER_REAL, 50ms) and its handler raises; a loop that doesn't
-- stop is killed by SIGPROF (the default action) after 5s of CPU — the test fails.
--   inverted     the loop's last guard is its back-edge (`jcc loop; jmp exit`), both the
--                realigned short form and the rel32 one
--   side-exit    every iteration leaves through a side exit whose side trace links back
--                to the root trace's head: the back-edge itself is never reached again
--   ffi-read     byte-at-a-time C.read of /dev/zero, as the `read` builtin does
package.path = "lua/?.lua;" .. package.path
local ffi = require("ffi")
require("runtime") -- (declares curse_sig_catch/curse_sig_default)
local C = ffi.C
pcall(ffi.cdef, [[
struct curse_tsj_itv { long is, ius, vs, vus; };
int setitimer(int which, const struct curse_tsj_itv *nv, struct curse_tsj_itv *old);
int open(const char *path, int flags, ...);
long read(int fd, void *buf, unsigned long n);
int close(int fd);
]])
local SIGALRM, ITIMER_REAL, ITIMER_PROF = 14, 0, 2
local function arm(which, secs)
	local t = ffi.new("struct curse_tsj_itv")
	local whole = math.floor(secs)
	t.vs, t.vus = whole, math.floor((secs - whole) * 1e6)
	C.setitimer(which, t, nil)
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

local fails = 0
for _, name in ipairs(arg and arg[1] and { arg[1] } or { "inverted_short", "inverted_long", "side_exit", "ffi_read" }) do
	arm(ITIMER_PROF, 5) -- the watchdog
	arm(ITIMER_REAL, 0.05)
	local ok, e = pcall(loops[name])
	arm(ITIMER_REAL, 0)
	arm(ITIMER_PROF, 0)
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
