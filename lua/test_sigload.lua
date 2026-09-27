-- A trapped signal arriving while a Lua module loads — a lazy builtin, the compiler —
-- waits until the load is done: the trap's handler may need that very module, and a
-- nested require of a module still loading is LuaJIT's "loop or previous error loading
-- module" (stress sig-hammer: a trap firing while `tier` was being required). Here the
-- `ulimit` builtin's module signals the shell as it loads, and the USR1 trap runs
-- `ulimit` itself: the trap must run once, after the load, with no error.
package.path = "lua/?.lua;" .. package.path
local ffi = require("ffi")
local T = require("tier")
pcall(ffi.cdef, "int kill(int pid, int sig); int getpid(void);")
local sh = T.rt.Shell.new()
local b = {}
sh.out = function(s)
	b[#b + 1] = s
end
package.loaded.b_ulimit = nil
package.preload.b_ulimit = function(...)
	ffi.C.kill(ffi.C.getpid(), 10) -- SIGUSR1, mid-load
	local s = 0
	for i = 1, 200000 do -- (VM safepoints: the hook fires here, while still loading)
		s = s + i % 7
	end
	package.preload.b_ulimit = nil
	return dofile("lua/b_ulimit.lua")
end
local ok, err = pcall(T.interp.run, sh, T.parser.parse(
	"n=0\ntrap 'n=$((n+1)); ulimit -S -c 0; echo \"trap ran: $n st=$?\"' USR1\nulimit -S -c 0\necho \"after: n=$n\"\ntrap - USR1\n"))
local out = table.concat(b)
local want = "trap ran: 1 st=0\nafter: n=1\n"
print(ok and out or ("error: " .. tostring(err)))
if not ok or out ~= want then
	print("*** want:\n" .. want)
	os.exit(1)
end
print("OK")
