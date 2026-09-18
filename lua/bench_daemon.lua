-- Measure the DAEMON CORE claim: from a warm process (runtime bundle loaded,
-- artifact cached, JIT traces warmed), fork a worker per request, run the script
-- in the child, reap. This is what a resident curse would do per `sh -c`. The
-- open question is whether forking a fat warm LuaJIT heap beats dash's tiny fork.
--   luajit lua/bench_daemon.lua <script.sh> [N]
local bundle = os.getenv("CURSE_BUNDLE") or "dist/curse.bc"
local bf = io.open(bundle, "rb")
if bf then
	bf:close()
	pcall(function()
		assert(loadfile(bundle))()
	end)
else
	package.path = "lua/?.lua;" .. package.path
end

local ffi = require("ffi")
ffi.cdef([[
  int fork(void);
  int waitpid(int pid, int *st, int opt);
  int pipe(int fds[2]);
  int close(int fd);
  int dup2(int a, int b);
  long read(int fd, void *buf, unsigned long n);
  void _exit(int status);
  struct td { long s; long us; };
  int gettimeofday(struct td *tv, void *tz);
]])
local C = ffi.C
local Cache = require("cache")
local rt = require("runtime")

local script = assert(arg[1], "usage: bench_daemon.lua <script.sh> [N]")
local N = tonumber(arg[2]) or 300
local f = assert(io.open(script, "r"))
local src = f:read("*a")
f:close()

-- Warm the parent: load the artifact into the cache and run enough times to let
-- LuaJIT trace the hot paths. Forked children inherit those traces via CoW.
do
	local devnull = function() end
	for _ = 1, 60 do
		local sh = rt.Shell.new()
		sh.out = devnull
		Cache.run(src, sh)
	end
end

local function now()
	local tv = ffi.new("struct td")
	C.gettimeofday(tv, nil)
	return tonumber(tv.s) + tonumber(tv.us) / 1e6
end

local st = ffi.new("int[1]")
local buf = ffi.new("char[8192]")
local t0 = now()
for _ = 1, N do
	local fds = ffi.new("int[2]")
	C.pipe(fds)
	local pid = C.fork()
	if pid == 0 then -- worker: run the script, output -> pipe
		C.dup2(fds[1], 1)
		C.close(fds[0])
		C.close(fds[1])
		local sh = rt.Shell.new()
		Cache.run(src, sh)
		io.flush()
		C._exit(0)
	end
	C.close(fds[1])
	while C.read(fds[0], buf, 8192) > 0 do
	end -- drain child stdout
	C.close(fds[0])
	C.waitpid(pid, st, 0)
end
local t1 = now()
io.write(("warm fork-per-request: %.3f ms/req (N=%d)\n"):format((t1 - t0) / N * 1000, N))
