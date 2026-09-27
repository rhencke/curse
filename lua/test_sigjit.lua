-- A signal preempts a JIT-compiled loop: the async handler (lib_cursesig.c) schedules a
-- VM hook, which only fires in the interpreter, and repoints the running trace's loop
-- back-edge so the trace exits (curse.patch, curse_sig_patch_trace). A daemon worker is
-- always catching the terminating signals the client forwards, so a loop that doesn't
-- exit never ends the script: `read -r x </dev/zero` outlived HUP/INT/TERM (stress
-- daemon-client-kill). Each loop below spins until a SIGALRM arrives (from a helper
-- process, after 50ms) and its handler raises; a loop that doesn't stop is SIGKILLed by
-- a watchdog after 5s — the test fails.
--   inverted_checked  an inverted loop (its last guard is its back-edge: nothing to
--                     repoint) that calls rt.sig_check each round, as `read` does
--   side_exit         every iteration leaves through a side exit whose side trace links
--                     back to the root trace's head: the back-edge itself is never
--                     reached again (the trace link's hook check)
--   ffi_read          byte-at-a-time C.read of /dev/zero
package.path = "lua/?.lua;" .. package.path
local ffi = require("ffi")
local rt = require("runtime") -- (declares curse_sig_catch/curse_sig_default)
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
loops.inverted_checked = function() -- (a loop the patch can't break: rt.sig_check)
	local i = 0
	while i < 1e15 do
		i = i + 1
		C.getpid() -- (a C call each round, as `read` makes: see rt.sig_check)
		rt.sig_check()
	end
	return i
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
for _, name in ipairs(arg and arg[1] and { arg[1] } or { "inverted_checked", "side_exit", "ffi_read" }) do
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
