-- A trapped signal must preempt JIT machine code of every cycle shape (the custom
-- LuaJIT preemption patch, CURSE_SIG_DESTRUCTIVE). The shape that used to hang: a
-- root loop trace whose guard fails on every iteration after warm-up, so the running
-- cycle is root entry -> failing guard -> side trace -> tail jmp to the root entry,
-- and the root's own back-edge is never reached (stress sig-preempt: a nested daemon
-- `trap … USR2; while :; do :; done` that never exited). Also: tail recursion (a tail
-- jmp to the trace itself), and exact state after many preemptions of such a cycle.
-- Each scenario runs in a child luajit under `timeout`, so a hang is a failure.
local ffi = require("ffi")
pcall(ffi.cdef, [[
int curse_sig_catch(int);
struct curse_itv { long is, iu, vs, vu; };
int setitimer(int, const struct curse_itv *, struct curse_itv *);
]])

local function arm(first_us, every_us) -- SIGALRM after first_us, then every every_us
	local v = ffi.new("struct curse_itv", 0, every_us, 0, first_us)
	ffi.C.setitimer(0, v, nil)
end

local mode = arg[1]
if mode then
	ffi.C.curse_sig_catch(14)
	local stop, hits = false, 0
	_G.__curse_sigrun = function()
		stop, hits = true, hits + 1
	end
	if mode == "side" then
		-- fresh traces per delay, so the signal lands in the root or in the side trace
		for d = 1, 40 do
			local f = assert(loadstring([[
				local stopf = ...
				local n, x = 0, 0
				while not stopf() do
					n = n + 1
					if n > 100 then x = x + 1 else x = x - 1 end
				end
				return n]]))
			stop = false
			arm(d * 700, 0)
			f(function()
				return stop
			end)
		end
		print("side: ok")
	elseif mode == "tailrec" then
		for d = 1, 20 do
			local f = assert(loadstring([[
				local stopf = ...
				local function tr(k) if stopf() then return k end return tr(k + 1) end
				return tr(0)]]))
			stop = false
			arm(d * 900, 0)
			f(function()
				return stop
			end)
		end
		print("tailrec: ok")
	elseif mode == "inverted" then
		-- a loop whose last guard is its own condition: LuaJIT inverts it (the jcc jumps
		-- back to the loop, a jmp to the exit follows) -- there is no back-edge jmp
		for d = 1, 20 do
			local f = assert(loadstring([[
				local lim = 1e15
				_G.__curse_sigrun = function() lim = 0 end
				local i = 0
				while i < lim do i = i + 1 end
				return i]]))
			arm(d * 900, 0)
			f()
		end
		print("inverted: ok")
	elseif mode == "exact" then
		-- a counting trap preempts the cycle ~every 200us; the arithmetic must be exact
		_G.__curse_sigrun = function()
			hits = hits + 1
		end
		arm(200, 200)
		local N = 40000000
		local n, x, y = 0, 0, 0
		while n < N do
			n = n + 1
			if n > 200 then x = x + 3 else x = x - 1 end
			y = y + n % 7
		end
		arm(0, 0)
		local ey = 0
		for i = 1, N do
			ey = ey + i % 7
		end
		print("exact: " .. tostring(x == (N - 200) * 3 - 200 and y == ey) .. " preempted: " .. tostring(hits > 10))
	end
	os.exit(0)
end

local lj = arg[-1] or "luajit"
local want = { side = "side: ok", tailrec = "tailrec: ok", inverted = "inverted: ok", exact = "exact: true preempted: true" }
local fails = 0
for _, m in ipairs({ "side", "tailrec", "inverted", "exact" }) do
	local p = io.popen("timeout 30 '" .. lj .. "' lua/test_sigpreempt.lua " .. m .. " 2>&1; echo \"st=$?\"")
	local out = p:read("*a")
	p:close()
	local exp = want[m] .. "\nst=0\n"
	if out ~= exp then
		fails = fails + 1
		io.write("FAIL ", m, ": got ", string.format("%q", out), " want ", string.format("%q", exp), "\n")
	else
		io.write("ok ", m, "\n")
	end
end
os.exit(fails == 0 and 0 or 1)
