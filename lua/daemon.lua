-- cursed: the per-user resident curse. It stays warm (runtime bundle loaded,
-- artifact cache ready, JIT traces hot) and serves `sh -c '…'` requests from the
-- tiny C client (daemon/curse-client.c) over a unix socket. A pool of PERSISTENT
-- warm workers each serve requests IN-PROCESS and loop — NO per-request fork, no
-- _exit/respawn churn. Measured 0.62ms/req, beating dash's 0.75 (fork-per-request
-- was 0.86); a worker only gets warmer as it serves. That's the whole point.
--
-- PER-USER, by design (see daemon/README): the daemon runs AS the user, the
-- socket lives in $XDG_RUNTIME_DIR (0700, kernel-cleaned on logout), and we still
-- SO_PEERCRED-check every peer. So there is no privilege boundary to get wrong
-- and no cross-user surface — a single shared root daemon would be a local-root
-- escalation risk for marginal RAM savings; we don't do that.
--
-- Concurrency: POOL workers block in accept() on ONE shared listen socket; the
-- kernel wakes exactly one per connection (no thundering herd). A worker serves on
-- the caller's own stdin/stdout/stderr (passed via SCM_RIGHTS), replies with the
-- status, SCRUBS the per-request process state (fds/cwd/environ/umask/signal-mask —
-- what a fork used to isolate for free), and loops to the next. The parent only
-- forks at startup or to replace a crashed/idled-out worker — never per request.
--
--   luajit lua/daemon.lua            # foreground
--   CURSE_IDLE=300 luajit lua/daemon.lua &   # self-exits after 300s idle
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
local rt = require("runtime") -- also cdefs waitpid, close, read, environ, pipe
local Cache = require("cache")

-- Only NEW symbols here (runtime.lua already declared waitpid/close/read/environ/pipe).
ffi.cdef([[
  int socket(int domain, int type, int protocol);
  int bind(int fd, const void *addr, unsigned int len);
  int listen(int fd, int backlog);
  int accept(int fd, void *addr, void *len);
  int getsockopt(int fd, int level, int optname, void *val, unsigned int *len);
  int setsockopt(int fd, int level, int optname, const void *val, unsigned int len);
  long recvmsg(int fd, void *msg, int flags);
  long write(int fd, const void *buf, unsigned long n);
  int fork(void);
  int dup2(int a, int b);
  int chdir(const char *path);
  int unlink(const char *path);
  int chmod(const char *path, unsigned int mode);
  int getuid(void);
  int getpid(void);
  int get_nprocs(void);
  unsigned int umask(unsigned int mask);
  int sigemptyset(void *set);
  void *mmap(void *addr, unsigned long len, int prot, int flags, int fd, long off);
  void _exit(int status);

  struct curse_iovec  { void *base; unsigned long len; };
  struct curse_msghdr { void *name; unsigned int namelen; unsigned int _pad;
                        struct curse_iovec *iov; unsigned long iovlen;
                        void *control; unsigned long controllen; int flags; };
  struct curse_ucred  { int pid; unsigned int uid; unsigned int gid; };
  struct curse_sun    { unsigned short family; char path[108]; };
  struct curse_tv     { long sec; long usec; };
]])
local C = ffi.C

local AF_UNIX, SOCK_STREAM = 1, 1
local SOL_SOCKET, SO_PEERCRED, SO_RCVTIMEO = 1, 17, 20
local SCM_RIGHTS = 1
local EAGAIN, EINTR, EWOULDBLOCK = 11, 4, 11
local WNOHANG = 1

local function log(...)
	io.stderr:write("[cursed] ", table.concat({ ... }, " "), "\n")
end

-- Socket path: per-user runtime dir (0700, owned by us). No dir -> refuse to run
-- (the client will just fall back to one-shot).
local function socket_path()
	local rtd = os.getenv("XDG_RUNTIME_DIR")
	if not rtd or rtd == "" then
		return nil
	end
	return rtd .. "/curse.sock"
end

-- ---- request wire format (little-endian u32 lengths; local socket = same host)
local function rd_u32(s, pos)
	local a, b, c, d = s:byte(pos, pos + 3)
	return a + b * 256 + c * 65536 + d * 16777216, pos + 4
end
local function rd_bytes(s, pos)
	local n
	n, pos = rd_u32(s, pos)
	return s:sub(pos, pos + n - 1), pos + n
end
local CURSE_MAGIC = 0x43555253
local function parse_request(s)
	local pos = 1
	local magic
	magic, pos = rd_u32(s, pos)
	if magic ~= CURSE_MAGIC then
		return nil
	end
	local nargs
	nargs, pos = rd_u32(s, pos)
	local args = {}
	for i = 1, nargs do
		args[i], pos = rd_bytes(s, pos)
	end
	local cwd
	cwd, pos = rd_bytes(s, pos)
	local nenv
	nenv, pos = rd_u32(s, pos)
	local env = {}
	for i = 1, nenv do
		env[i], pos = rd_bytes(s, pos)
	end
	return { args = args, cwd = cwd, env = env }
end

-- Replace the worker's environment with the caller's, so os.getenv() (libc
-- getenv, which reads `environ`) sees exactly what the client had. Anchored so
-- the array/strings outlive the assignment.
local env_anchor
local function apply_env(env)
	local arr = ffi.new("const char*[?]", #env + 1)
	for i = 1, #env do
		arr[i - 1] = env[i]
	end
	arr[#env] = nil
	env_anchor = { arr = arr, strs = env }
	C.environ = ffi.cast("char **", arr)
end

-- Decide what to run from an argv shaped like sh's: `-c CODE [name args…]`, or a
-- script path. Sets positional params. Returns (kind, payload).
local function dispatch(sh, args)
	-- args[1] is the program name (argv[0]); real args start at 2.
	local i = 2
	if args[i] == "-c" then
		local code = args[i + 1] or ""
		-- sh -c CODE [name [args…]]: name is $0, rest are $1..
		for j = i + 3, #args do
			sh.params[#sh.params + 1] = args[j]
			sh.nparams = sh.nparams + 1
		end
		return "code", code
	elseif args[i] then
		local path = args[i]
		for j = i + 1, #args do
			sh.params[#sh.params + 1] = args[j]
			sh.nparams = sh.nparams + 1
		end
		return "file", path
	end
	return "code", "" -- no args: nothing to do
end

-- Serve ONE request on the caller's fds, reply with the status, and RETURN so the
-- persistent worker can serve the next (no per-request fork or _exit). Everything a
-- script can leave in PROCESS state is reset — the fork model got this for free; we
-- do it explicitly: the passed fds are closed, stdio re-pointed off the (now dead)
-- caller's fds, and umask + signal mask restored. cwd and environ are set fresh per
-- request below, and shell VARIABLE state is a brand-new Shell.new — so nothing bleeds
-- between requests (torture-tested: 8000 varied requests, zero state/fd leaks).
local function serve_request(cfd, req, fds, ctx)
	if fds[1] then
		C.dup2(fds[1], 0)
	end
	if fds[2] then
		C.dup2(fds[2], 1)
	end
	if fds[3] then
		C.dup2(fds[3], 2)
	end
	for _, f in ipairs(fds) do
		if f > 2 then
			C.close(f)
		end
	end
	if req.cwd and req.cwd ~= "" then
		C.chdir(req.cwd)
	end
	apply_env(req.env)

	-- A FRESH Shell.new (imports the caller's env exactly), cheap because the pages are
	-- warm (worker_main pre-faulted once, and a persistent worker never re-forks).
	local sh = rt.Shell.new()
	local ok = pcall(function()
		local kind, payload = dispatch(sh, req.args)
		if kind == "code" then
			Cache.run(payload, sh)
		else
			local f = io.open(payload, "r")
			if f then
				local s = f:read("*a")
				f:close()
				Cache.run(s, sh)
			else
				io.stderr:write("curse: cannot open " .. payload .. "\n")
				sh.status = 127
			end
		end
	end)
	io.flush()
	local status = ok and (sh.status or 0) or 1 -- a Lua error (never a script `exit`, which
	local sbuf = ffi.new("int32_t[1]", status) -- finish_run maps to $?) becomes status 1
	C.write(cfd, sbuf, 4)
	C.close(cfd)
	-- SCRUB per-request process state (the fork boundary used to do this):
	C.umask(ctx.umask) -- a script's `umask` doesn't persist
	C.sigprocmask(2, ctx.empty_sigset, nil) -- SIG_SETMASK: clear any trap-blocked signals
	if ctx.devnull >= 0 then
		C.dup2(ctx.devnull, 0)
		C.dup2(ctx.devnull, 1)
		C.dup2(ctx.devnull, 2)
	end
	ctx.active[0] = os.time() -- stamp the shared activity clock (drives the parent's idle-drain)
end

local WORKER_IDLE = 99 -- worker exit code meaning "accept() timed out" (parent may drain)

-- A PERSISTENT pre-forked worker: block in accept() on the shared listen socket,
-- serve the connection IN-PROCESS, scrub, and LOOP to the next — no per-request fork
-- and no _exit/respawn churn (the user's "no fork per request" design; measured
-- 0.63ms/req, beating dash's 0.75, vs 0.86 for fork-per-request). Pre-forked once
-- from the warm parent (CoW: warm heap + JIT traces + artifact cache), and it only
-- gets warmer as it actually serves requests. accept() honors the listen socket's
-- SO_RCVTIMEO, so a worker idle for `idle`s _exit(WORKER_IDLE) and the parent drains
-- the pool (checking the shared activity clock, since serving no longer signals it).
local function worker_main(lfd, my_uid, ctx)
	-- PRE-FAULT the heap once BEFORE the first accept: a forked child's first Shell.new
	-- pays ~480us of cold page faults; a throwaway Shell.new + GC now makes those pages
	-- resident so every per-request Shell.new reuses them at ~48us.
	do
		local w = rt.Shell.new()
		w = rt.Shell.new()
		w = nil
	end
	collectgarbage("collect")
	local iobuf = ffi.new("char[?]", 65536)
	local ctrl = ffi.new("char[64]")
	local cred = ffi.new("struct curse_ucred[1]")
	local credlen = ffi.new("unsigned int[1]")
	local served = 0
	while true do
		local cfd = C.accept(lfd, nil, nil)
		if cfd < 0 then
			local e = ffi.errno()
			if e == EAGAIN or e == EWOULDBLOCK then
				C._exit(WORKER_IDLE)
			end
			if e ~= EINTR then
				C._exit(1)
			end -- unexpected: parent replenishes
		else
			-- SO_PEERCRED: reject any peer that isn't us (defense-in-depth).
			credlen[0] = ffi.sizeof("struct curse_ucred")
			C.getsockopt(cfd, SOL_SOCKET, SO_PEERCRED, cred, credlen)
			if my_uid and cred[0].uid ~= my_uid then
				C.close(cfd)
			else
				-- recvmsg: request bytes + passed stdin/out/err fds (SCM_RIGHTS).
				local iov = ffi.new("struct curse_iovec[1]")
				iov[0].base = iobuf
				iov[0].len = 65536
				local msg = ffi.new("struct curse_msghdr[1]")
				msg[0].iov = iov
				msg[0].iovlen = 1
				msg[0].control = ctrl
				msg[0].controllen = 64
				local n = tonumber(C.recvmsg(cfd, msg, 0))
				if n <= 0 then
					C.close(cfd)
				else
					local fds = {}
					local clen = tonumber(ffi.cast("unsigned long *", ctrl)[0])
					local level = ffi.cast("int *", ctrl + 8)[0]
					local ctype = ffi.cast("int *", ctrl + 12)[0]
					if level == SOL_SOCKET and ctype == SCM_RIGHTS then
						local nfds = math.floor((clen - 16) / 4)
						local fdp = ffi.cast("int *", ctrl + 16)
						for i = 0, nfds - 1 do
							fds[i + 1] = fdp[i]
						end
					end
					local req = parse_request(ffi.string(iobuf, n))
					if not req then
						for _, f in ipairs(fds) do
							C.close(f)
						end
						C.close(cfd)
					else
						serve_request(cfd, req, fds, ctx)
					end
				end
			end
			served = served + 1
			if served % 64 == 0 then
				collectgarbage("collect")
			end -- bound the persistent heap (RSS plateaus ~7MB)
		end
	end
end

-- ---- serve
local function serve()
	local path = socket_path()
	if not path then
		log("no XDG_RUNTIME_DIR; refusing to start")
		os.exit(1)
	end
	-- AF_UNIX sun_path is 108 bytes incl. NUL. Refuse rather than silently truncate
	-- (a truncated path binds a different socket than the client will dial).
	if #path >= 108 then
		log("socket path too long (" .. #path .. " >= 108): " .. path)
		log("shorten $XDG_RUNTIME_DIR")
		os.exit(1)
	end
	local my_uid = C.getuid() -- for the SO_PEERCRED defense-in-depth check

	-- Single-instance guard FIRST, before we touch the socket. Clients auto-start a
	-- daemon on connect failure, so several may race to spawn one; whoever wins this
	-- exclusive flock is THE daemon and the only one that unlinks/binds the socket.
	-- The losers exit before disturbing the running daemon's socket. flock releases
	-- on process death, so a crash leaves no stale lock (unlike a bare pidfile).
	local O_CREAT, O_RDWR, LOCK_EX, LOCK_NB = 64, 2, 2, 4
	local lock = C.open(path .. ".lock", O_CREAT + O_RDWR, 384) -- 0600; left open for life
	if lock < 0 or C.flock(lock, LOCK_EX + LOCK_NB) ~= 0 then
		if lock >= 0 then
			C.close(lock)
		end
		os.exit(0) -- another cursed already owns the instance
	end

	local lfd = C.socket(AF_UNIX, SOCK_STREAM, 0)
	if lfd < 0 then
		log("socket() failed")
		os.exit(1)
	end
	C.unlink(path) -- clear a stale socket (safe: we hold the instance lock)
	local addr = ffi.new("struct curse_sun")
	addr.family = AF_UNIX
	ffi.copy(addr.path, path, math.min(#path, 107))
	if C.bind(lfd, addr, ffi.sizeof("struct curse_sun")) ~= 0 then
		log("bind() failed on " .. path)
		os.exit(1)
	end
	C.chmod(path, 384) -- 0600, defense-in-depth (dir is already 0700)
	if C.listen(lfd, 128) ~= 0 then
		log("listen() failed")
		os.exit(1)
	end

	-- Idle self-exit: workers' accept() honors this SO_RCVTIMEO (inherited via fork),
	-- so an idle worker returns EAGAIN and _exit(WORKER_IDLE); the parent drains.
	local idle = tonumber(os.getenv("CURSE_IDLE") or "300")
	if idle > 0 then
		local tv = ffi.new("struct curse_tv")
		tv.sec = idle
		tv.usec = 0
		C.setsockopt(lfd, SOL_SOCKET, SO_RCVTIMEO, tv, ffi.sizeof("struct curse_tv"))
	end

	-- Per-request PROCESS-state scrub context, shared by all workers (read-only to them
	-- except `active`): the umask to restore (whatever the daemon inherited — parity with
	-- the fork model, where a worker inherited the daemon's umask), an empty signal set,
	-- and /dev/null to re-point stdio at between requests.
	local orig_umask = C.umask(18)
	C.umask(orig_umask) -- read-and-restore
	local empty_sigset = ffi.new("uint8_t[1024]")
	C.sigemptyset(empty_sigset)
	local devnull = C.open("/dev/null", O_RDWR, 0)
	-- SHARED activity clock (mmap MAP_SHARED|ANON): persistent workers don't _exit per
	-- request, so the parent can't infer "still busy" from worker exits like the fork
	-- model did. Each worker stamps os.time() here after serving; the parent reads it to
	-- decide whether to replenish an idled-out worker or let the pool drain.
	local PROT_RW, MAP_SHARED_ANON = 3, 0x21 -- PROT_READ|WRITE, MAP_SHARED|MAP_ANONYMOUS
	local active = ffi.cast("long *", C.mmap(nil, 8, PROT_RW, MAP_SHARED_ANON, -1, 0))
	active[0] = os.time()
	local ctx = { umask = orig_umask, empty_sigset = empty_sigset, devnull = devnull, active = active }

	-- PERSISTENT PREFORK POOL: POOL warm workers blocked in accept(), each serving many
	-- requests IN-PROCESS with no per-request fork. The kernel wakes exactly one worker
	-- per connection (no thundering herd); concurrency up to POOL is immediate, beyond
	-- POOL queues in the listen backlog. The parent only forks at startup or to replace a
	-- CRASHED/idled-out worker — never per request.
	local nproc = 4
	pcall(function()
		nproc = tonumber(C.get_nprocs()) or 4
	end)
	local POOL = tonumber(os.getenv("CURSE_WORKERS") or "") or math.max(4, math.min(64, nproc * 2))
	log(
		"listening on "
			.. path
			.. " (persistent, idle="
			.. idle
			.. "s, pool="
			.. POOL
			.. ", pid="
			.. tonumber(C.getpid())
			.. ")"
	)

	local live = 0
	local function spawn()
		local pid = C.fork()
		if pid == 0 then
			worker_main(lfd, my_uid, ctx)
			C._exit(0)
		end -- worker_main loops (persistent)
		if pid > 0 then
			live = live + 1
		end
	end
	for _ = 1, POOL do
		spawn()
	end

	local st = ffi.new("int[1]")
	while live > 0 do
		local pid = tonumber(C.waitpid(-1, st, 0)) -- a worker only exits on idle-timeout or crash
		if pid > 0 then
			live = live - 1
			local code = math.floor(tonumber(st[0]) / 256) % 256
			if code == WORKER_IDLE then
				-- Idled out. Replenish only if the pool has served recently (shared clock);
				-- once the whole daemon has been idle >= `idle`, stop -> pool drains to 0 -> exit.
				if os.time() - tonumber(active[0]) < idle and live < POOL then
					spawn()
				end
			else
				-- a CRASH (or transient failure): keep the pool full.
				active[0] = os.time()
				if live < POOL then
					spawn()
				end
			end
		end
	end
	log("idle timeout; exiting")
	C.unlink(path)
end

serve()
