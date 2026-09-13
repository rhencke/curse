-- cursed: the per-user resident curse. It stays warm (runtime bundle loaded,
-- artifact cache ready, JIT traces hot) and serves `sh -c '…'` requests from the
-- tiny C client (daemon/curse-client.c) over a unix socket, forking a worker per
-- request. A worker inherits the warm heap+traces via CoW, so it runs shell work
-- FASTER than dash's fresh process (measured 0.56ms vs 0.76ms) — the whole point.
--
-- PER-USER, by design (see daemon/README): the daemon runs AS the user, the
-- socket lives in $XDG_RUNTIME_DIR (0700, kernel-cleaned on logout), and we still
-- SO_PEERCRED-check every peer. So there is no privilege boundary to get wrong
-- and no cross-user surface — a single shared root daemon would be a local-root
-- escalation risk for marginal RAM savings; we don't do that.
--
-- Concurrency: accept -> recvmsg (get fds + request) -> fork worker -> keep
-- accepting. The WORKER runs the script on the caller's own stdin/stdout/stderr
-- (passed via SCM_RIGHTS) and sends the exit status back itself, so the parent
-- never blocks on a running script; it reaps finished workers opportunistically.
--
--   luajit lua/daemon.lua            # foreground
--   CURSE_IDLE=300 luajit lua/daemon.lua &   # self-exits after 300s idle
local bundle = os.getenv("CURSE_BUNDLE") or "dist/curse.bc"
local bf = io.open(bundle, "rb")
if bf then bf:close(); pcall(function() assert(loadfile(bundle))() end)
else package.path = "lua/?.lua;" .. package.path end

local ffi = require("ffi")
local rt = require("runtime")     -- also cdefs waitpid, close, read, environ, pipe
local Cache = require("cache")

-- Only NEW symbols here (runtime.lua already declared waitpid/close/read/environ/pipe).
ffi.cdef [[
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
  void _exit(int status);

  struct curse_iovec  { void *base; unsigned long len; };
  struct curse_msghdr { void *name; unsigned int namelen; unsigned int _pad;
                        struct curse_iovec *iov; unsigned long iovlen;
                        void *control; unsigned long controllen; int flags; };
  struct curse_ucred  { int pid; unsigned int uid; unsigned int gid; };
  struct curse_sun    { unsigned short family; char path[108]; };
  struct curse_tv     { long sec; long usec; };
]]
local C = ffi.C

local AF_UNIX, SOCK_STREAM = 1, 1
local SOL_SOCKET, SO_PEERCRED, SO_RCVTIMEO = 1, 17, 20
local SCM_RIGHTS = 1
local EAGAIN, EINTR, EWOULDBLOCK = 11, 4, 11
local WNOHANG = 1

local function log(...) io.stderr:write("[cursed] ", table.concat({ ... }, " "), "\n") end

-- Socket path: per-user runtime dir (0700, owned by us). No dir -> refuse to run
-- (the client will just fall back to one-shot).
local function socket_path()
  local rtd = os.getenv("XDG_RUNTIME_DIR")
  if not rtd or rtd == "" then return nil end
  return rtd .. "/curse.sock"
end

-- ---- request wire format (little-endian u32 lengths; local socket = same host)
local function rd_u32(s, pos)
  local a, b, c, d = s:byte(pos, pos + 3)
  return a + b * 256 + c * 65536 + d * 16777216, pos + 4
end
local function rd_bytes(s, pos)
  local n; n, pos = rd_u32(s, pos)
  return s:sub(pos, pos + n - 1), pos + n
end
local CURSE_MAGIC = 0x43555253
local function parse_request(s)
  local pos = 1
  local magic; magic, pos = rd_u32(s, pos)
  if magic ~= CURSE_MAGIC then return nil end
  local nargs; nargs, pos = rd_u32(s, pos)
  local args = {}
  for i = 1, nargs do args[i], pos = rd_bytes(s, pos) end
  local cwd; cwd, pos = rd_bytes(s, pos)
  local nenv; nenv, pos = rd_u32(s, pos)
  local env = {}
  for i = 1, nenv do env[i], pos = rd_bytes(s, pos) end
  return { args = args, cwd = cwd, env = env }
end

-- Replace the worker's environment with the caller's, so os.getenv() (libc
-- getenv, which reads `environ`) sees exactly what the client had. Anchored so
-- the array/strings outlive the assignment.
local env_anchor
local function apply_env(env)
  local arr = ffi.new("const char*[?]", #env + 1)
  for i = 1, #env do arr[i - 1] = env[i] end
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
    for j = i + 3, #args do sh.params[#sh.params + 1] = args[j]; sh.nparams = sh.nparams + 1 end
    return "code", code
  elseif args[i] then
    local path = args[i]
    for j = i + 1, #args do sh.params[#sh.params + 1] = args[j]; sh.nparams = sh.nparams + 1 end
    return "file", path
  end
  return "code", "" -- no args: nothing to do
end

-- The worker: runs entirely in the forked child on the caller's fds, then sends
-- the exit status back over the connection and _exit()s. Must never return.
local function run_worker(cfd, req, fds)
  -- caller's stdin/stdout/stderr -> our 0/1/2
  if fds[1] then C.dup2(fds[1], 0) end
  if fds[2] then C.dup2(fds[2], 1) end
  if fds[3] then C.dup2(fds[3], 2) end
  for _, f in ipairs(fds) do if f > 2 then C.close(f) end end
  if req.cwd and req.cwd ~= "" then C.chdir(req.cwd) end
  apply_env(req.env)

  local sh = rt.Shell.new()
  -- sh.out defaults to io.write -> C stdout (fd 1, now the caller's). Flush before exit.
  local ok = pcall(function()
    local kind, payload = dispatch(sh, req.args)
    if kind == "code" then
      Cache.run(payload, sh)
    else
      local f = io.open(payload, "r")
      if f then local s = f:read("*a"); f:close(); Cache.run(s, sh)
      else io.stderr:write("curse: cannot open " .. payload .. "\n"); sh.status = 127 end
    end
  end)
  io.flush()
  local status = ok and (sh.status or 0) or 1
  local sbuf = ffi.new("int32_t[1]", status)
  C.write(cfd, sbuf, 4)
  C.close(cfd)
  -- The SCRIPT status went to the client via the socket; the worker's OWN exit code
  -- is a POOL signal to the parent (0 = served -> replenish). Never the script's
  -- status, which could collide with WORKER_IDLE.
  C._exit(0)
end

local WORKER_IDLE = 99 -- worker exit code meaning "accept() timed out" (parent may drain)

-- A one-shot pre-forked worker: block in accept() on the shared listen socket, serve
-- exactly one connection, then _exit. Pre-forked from the warm parent (CoW: warm
-- heap + JIT traces + artifact cache), so a request costs NO fork on its critical
-- path — the replacement fork happens in the parent after dispatch. accept() honors
-- the listen socket's SO_RCVTIMEO, so an idle worker _exit(WORKER_IDLE) and the
-- parent can drain the pool when the daemon has been idle.
local function worker_main(lfd, my_uid)
  local cfd
  while true do
    cfd = C.accept(lfd, nil, nil)
    if cfd >= 0 then break end
    local e = ffi.errno()
    if e == EAGAIN or e == EWOULDBLOCK then C._exit(WORKER_IDLE) end
    if e ~= EINTR then C._exit(1) end -- unexpected: let the parent replenish
  end
  -- SO_PEERCRED: reject any peer that isn't us (defense-in-depth).
  local cred = ffi.new("struct curse_ucred[1]")
  local credlen = ffi.new("unsigned int[1]"); credlen[0] = ffi.sizeof("struct curse_ucred")
  C.getsockopt(cfd, SOL_SOCKET, SO_PEERCRED, cred, credlen)
  if my_uid and cred[0].uid ~= my_uid then C.close(cfd); C._exit(0) end
  -- recvmsg: request bytes + passed stdin/out/err fds (SCM_RIGHTS).
  local iobuf = ffi.new("char[?]", 65536)
  local ctrl = ffi.new("char[64]")
  local iov = ffi.new("struct curse_iovec[1]"); iov[0].base = iobuf; iov[0].len = 65536
  local msg = ffi.new("struct curse_msghdr[1]"); msg[0].iov = iov; msg[0].iovlen = 1
  msg[0].control = ctrl; msg[0].controllen = 64
  local n = tonumber(C.recvmsg(cfd, msg, 0))
  if n <= 0 then C.close(cfd); C._exit(0) end
  local fds = {}
  local clen = tonumber(ffi.cast("unsigned long *", ctrl)[0])
  local level = ffi.cast("int *", ctrl + 8)[0]
  local ctype = ffi.cast("int *", ctrl + 12)[0]
  if level == SOL_SOCKET and ctype == SCM_RIGHTS then
    local nfds = math.floor((clen - 16) / 4)
    local fdp = ffi.cast("int *", ctrl + 16)
    for i = 0, nfds - 1 do fds[i + 1] = fdp[i] end
  end
  local req = parse_request(ffi.string(iobuf, n))
  if not req then for _, f in ipairs(fds) do C.close(f) end; C.close(cfd); C._exit(0) end
  run_worker(cfd, req, fds) -- serves on the caller's fds, replies, and _exit(0)s
end

-- ---- serve
local function serve()
  local path = socket_path()
  if not path then log("no XDG_RUNTIME_DIR; refusing to start"); os.exit(1) end
  -- AF_UNIX sun_path is 108 bytes incl. NUL. Refuse rather than silently truncate
  -- (a truncated path binds a different socket than the client will dial).
  if #path >= 108 then
    log("socket path too long (" .. #path .. " >= 108): " .. path)
    log("shorten $XDG_RUNTIME_DIR"); os.exit(1)
  end
  local my_uid = C.getuid() -- for the SO_PEERCRED defense-in-depth check

  local lfd = C.socket(AF_UNIX, SOCK_STREAM, 0)
  if lfd < 0 then log("socket() failed"); os.exit(1) end
  C.unlink(path) -- clear a stale socket
  local addr = ffi.new("struct curse_sun")
  addr.family = AF_UNIX
  ffi.copy(addr.path, path, math.min(#path, 107))
  if C.bind(lfd, addr, ffi.sizeof("struct curse_sun")) ~= 0 then
    log("bind() failed on " .. path); os.exit(1)
  end
  C.chmod(path, 384) -- 0600, defense-in-depth (dir is already 0700)
  if C.listen(lfd, 128) ~= 0 then log("listen() failed"); os.exit(1) end

  -- Idle self-exit: workers' accept() honors this SO_RCVTIMEO (inherited via fork),
  -- so an idle worker returns EAGAIN and _exit(WORKER_IDLE); the parent drains.
  local idle = tonumber(os.getenv("CURSE_IDLE") or "300")
  if idle > 0 then
    local tv = ffi.new("struct curse_tv"); tv.sec = idle; tv.usec = 0
    C.setsockopt(lfd, SOL_SOCKET, SO_RCVTIMEO, tv, ffi.sizeof("struct curse_tv"))
  end

  -- PREFORK POOL: keep POOL workers pre-forked and blocked in accept() so a request
  -- never waits for a fork (the ~500us fork is paid at startup + on replenish, off
  -- the critical path). Concurrency up to POOL is served immediately; beyond POOL,
  -- connections queue in the listen backlog (backpressure — never rejected). Plain
  -- accept() on a shared socket wakes exactly one worker (no thundering herd).
  local nproc = 4; pcall(function() nproc = tonumber(C.get_nprocs()) or 4 end)
  local POOL = tonumber(os.getenv("CURSE_WORKERS") or "") or math.max(4, math.min(64, nproc * 2))
  log("listening on " .. path .. " (idle=" .. idle .. "s, pool=" .. POOL ..
      ", pid=" .. tonumber(C.getpid()) .. ")")

  local live = 0
  local function spawn()
    local pid = C.fork()
    if pid == 0 then worker_main(lfd, my_uid); C._exit(0) end -- worker_main _exits
    if pid > 0 then live = live + 1 end
  end
  for _ = 1, POOL do spawn() end

  local st = ffi.new("int[1]")
  local last_active = os.time()
  while live > 0 do
    local pid = tonumber(C.waitpid(-1, st, 0)) -- block until a worker exits
    if pid > 0 then
      live = live - 1
      local code = math.floor(tonumber(st[0]) / 256) % 256
      if code == WORKER_IDLE then
        -- A worker idled out. Replenish only while there's been recent activity;
        -- once the daemon has been idle >= `idle`, stop -> the pool drains to 0 -> exit.
        if os.time() - last_active < idle and live < POOL then spawn() end
      else
        last_active = os.time() -- served (or a transient failure); keep the pool full
        if live < POOL then spawn() end
      end
    end
  end
  log("idle timeout; exiting")
  C.unlink(path)
end

serve()
