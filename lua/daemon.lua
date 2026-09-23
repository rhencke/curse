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
local Tier = require("tier") -- cold requests tier (interp -> OSR + cache); warm ones load .bc
require("cache") -- for its open/flock/mkdir ffi cdefs (serve()'s instance lock uses C.open/C.flock)

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
  long syscall(long number, ...);
  typedef struct _IO_FILE curse_d_FILE;
  extern curse_d_FILE *stdin;
  void curse_d_fpurge(curse_d_FILE *fp) asm("__fpurge");
  void clearerr(curse_d_FILE *fp);
  struct curse_d_rlimit { unsigned long cur, max; };
  int curse_d_getrlimit(int res, struct curse_d_rlimit *r) asm("getrlimit");
  int curse_d_setrlimit(int res, const struct curse_d_rlimit *r) asm("setrlimit");
  struct curse_d_pollfd { int fd; short events; short revents; };
  int curse_d_poll(struct curse_d_pollfd *fds, unsigned long n, int timeout) asm("poll");
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

-- Keep the daemon's OWN descriptors out of the low range a script freely redirects.
-- A worker serves in-process (no per-request fork), so its lock / listen socket / /dev/null
-- / per-request control socket sit at fds 3-6 — exactly where scripts put their own
-- redirections (`exec 3<file`, `read <&6`). A script touching one corrupts the daemon: a
-- read on the live control socket consumed the reply protocol and hung the client for the
-- whole request timeout (oil redirect#2). Move each to a high, close-on-exec fd (F_DUPFD_
-- CLOEXEC = 1030; CLOEXEC also keeps it out of any external command the script execs).
-- fcntl (declared variadic by runtime.lua) needs its F_DUPFD arg as a REAL int: a bare Lua
-- number goes through a variadic call as a double, so F_DUPFD reads garbage for the minimum
-- and hands back a LOW fd — silently defeating the move. A boxed int cdata is passed as int.
local F_DUPFD_CLOEXEC = 1030 -- Linux: F_LINUX_SPECIFIC_BASE(1024)+6
-- The daemon's own few fds sit in [D_LO, D_HI), just under the shell's internal range
-- (rt.FD_BASE): far above anything a script redirects to or `{var}`-allocates.
local D_LO = math.max(3, rt.FD_BASE - 64)
local D_HI = rt.FD_BASE
local FD_HIGH_MIN = ffi.new("int", D_LO)
local function fd_move_high(fd)
	if fd < 0 then
		return fd
	end
	local hi = C.fcntl(fd, F_DUPFD_CLOEXEC, FD_HIGH_MIN)
	if hi >= 0 then
		C.close(fd)
		return hi
	end
	return fd
end

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
	-- optional trailer: the caller's IGNORED signals (bit n-1 = signal n) — a resident
	-- worker doesn't share the caller's dispositions, but the script must (bash: ignored
	-- at entry stays ignored, untrappable, and inherited by what it runs)
	local sigign = 0
	if pos + 3 <= #s then
		sigign, pos = rd_u32(s, pos)
	end
	-- optional trailer: the numbers of the extra inherited fds passed after 0,1,2
	local extra = {}
	if pos + 3 <= #s then
		local n
		n, pos = rd_u32(s, pos)
		for i = 1, n do
			extra[i], pos = rd_u32(s, pos)
		end
	end
	return { args = args, cwd = cwd, env = env, sigign = sigign, extra = extra }
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
-- The invocation's options, as run.lua takes them: `-c CODE [name [args…]]`, set flags
-- (`-e`/`+e`, `-o NAME`/`+o NAME`, `-O shopt`), `-i` (interactive), `-s`/no script (read the
-- program from stdin), `--posix`, rc-file flags (ignored), `--`, then SCRIPT [args…].
-- Returns kind ("code" | "file" | "stdin" | "repl"), payload.
local LONG_IGNORED = { ["--norc"] = 1, ["--noprofile"] = 1, ["--login"] = 1, ["-l"] = 1, ["--noediting"] = 1 }
local function dispatch(sh, args)
	-- args[1] is the program name (argv[0]); real args start at 2.
	local i, n = 2, #args
	local base = (args[1] or ""):match("[^/]+$")
	if base == "sh" or base == "dash" or base == "ash" then
		sh.opt_posix = true -- (invoked as sh: posix mode, as run.lua's SH_IS_POSIX)
	end
	local code, from_stdin = nil, false
	while i <= n do
		local a = args[i]
		if a == "--" then
			i = i + 1
			break
		elseif a == "-c" then
			code = args[i + 1] or ""
			i = i + 2
			break
		elseif LONG_IGNORED[a] then
			i = i + 1
		elseif a == "--posix" then
			sh.opt_posix = true
			i = i + 1
		elseif a == "--rcfile" or a == "--init-file" then
			i = i + 2
		elseif (a == "-o" or a == "+o") and args[i + 1] then
			local f = rt.SETOPT[args[i + 1]]
			if f then
				sh[f] = (a == "-o")
			end
			i = i + 2
		elseif (a == "-O" or a == "+O") and args[i + 1] then
			sh.shopt[args[i + 1]] = (a == "-O")
			i = i + 2
		elseif a:match("^[-+]%a+$") then -- clustered single-letter flags (-ex, +u, -i, -s)
			local on = a:sub(1, 1) == "-"
			for ch in a:sub(2):gmatch(".") do
				if ch == "i" then
					sh.opt_i = on
				elseif ch == "s" then
					from_stdin = true
				elseif ch == "c" then
					code = args[i + 1] or ""
				elseif rt.SETFLAG[ch] then
					sh[rt.SETFLAG[ch]] = on
				end
			end
			i = i + (a:find("c", 2, true) and 2 or 1)
			if code then
				break
			end
		else
			break
		end
	end
	if code then
		-- sh -c CODE [name [args…]]: name is $0, rest are $1..
		sh.opt_c = true -- (as run.lua: -c's exit statuses, no `main` FUNCNAME frame, …)
		-- $0 is the name argument, else the shell's own argv[0] (`exec -a NAME sh -c …`)
		sh.argv0 = args[i] or args[1] or sh.argv0
		for j = i + 1, n do
			sh.params[#sh.params + 1] = args[j]
			sh.nparams = sh.nparams + 1
		end
		return "code", code
	end
	if args[i] and not from_stdin then
		local path = args[i]
		sh.argv0 = path -- $0 is the script path (bash)
		for j = i + 1, n do
			sh.params[#sh.params + 1] = args[j]
			sh.nparams = sh.nparams + 1
		end
		return "file", path
	end
	-- no script: the program comes from stdin (positional args with -s)
	for j = i, n do
		sh.params[#sh.params + 1] = args[j]
		sh.nparams = sh.nparams + 1
	end
	if sh.opt_i or C.isatty(0) == 1 then
		sh.opt_i = true
		return "repl", nil
	end
	return "stdin", nil
end

-- Serve ONE request on the caller's fds, reply with the status, and RETURN so the
-- persistent worker can serve the next (no per-request fork or _exit). Everything a
-- script can leave in PROCESS state is reset — the fork model got this for free; we
-- do it explicitly: the passed fds are closed, stdio re-pointed off the (now dead)
-- caller's fds, and umask + signal mask restored. cwd and environ are set fresh per
-- request below, and shell VARIABLE state is a brand-new Shell.new — so nothing bleeds
-- between requests (torture-tested: 8000 varied requests, zero state/fd leaks).
local function serve_request(cfd, req, fds, ctx)
	rt.path_epoch = rt.path_epoch + 1 -- (the command-lookup cache re-checks PATH once per request)
	if fds[1] then
		C.dup2(fds[1], 0)
	end
	if fds[2] then
		C.dup2(fds[2], 1)
	end
	if fds[3] then
		C.dup2(fds[3], 2)
	end
	-- stdio's `stdin` buffer / EOF flag belong to the PREVIOUS caller's fd 0: drop them
	C.curse_d_fpurge(C.stdin)
	C.clearerr(C.stdin)
	-- the caller's other inherited fds go back to their own numbers (`cmd 3<&0`): park
	-- each received copy clear of the targets first, so none overwrites another
	local parked = {}
	for i, target in ipairs(req.extra or {}) do
		local f = fds[3 + i]
		if f then
			parked[i] = C.fcntl(f, F_DUPFD_CLOEXEC, ffi.new("int", 64))
		end
	end
	for _, f in ipairs(fds) do
		if f > 2 then
			C.close(f)
		end
	end
	for i, target in ipairs(req.extra or {}) do
		local t = parked[i]
		if t and t >= 0 then
			C.dup2(t, target) -- (dup2 clears close-on-exec: the script's commands inherit it)
			C.close(t)
		end
	end
	if req.cwd and req.cwd ~= "" then
		C.chdir(req.cwd)
	end
	apply_env(req.env)

	-- A FRESH Shell.new (imports the caller's env exactly), cheap because the pages are
	-- warm (worker_main pre-faulted once, and a persistent worker never re-forks).
	local sh = rt.Shell.new()
	-- $PPID is the CLIENT's parent (the shell that ran curse), not this worker's
	if ctx.client_pid and ctx.client_pid > 1 then
		local f = io.open("/proc/" .. ctx.client_pid .. "/stat", "r")
		local st = f and f:read("*l")
		if f then
			f:close()
		end
		local pp = st and st:match("%) %S+ (%d+)")
		if pp and sh.vars.PPID then
			sh.vars.PPID.s = pp
		end
	end
	if req.sigign ~= ctx.sigign then -- (the common case — same as the worker's — costs nothing)
		rt.sig_apply_mask(req.sigign)
	end
	rt.startup_ignored(sh, req.sigign)
	if sh.fimports then
		rt.import_functions(sh) -- exported functions (BASH_FUNC_name%%) from the caller's env
	end
	-- A Lua error escaping the run is a curse BUG: report it on the request's stderr
	-- (status 1) instead of failing silently.
	local ok = xpcall(function()
		local kind, payload = dispatch(sh, req.args)
		if kind == "repl" then
			if sh.vars.PS1 == nil then
				sh:set_str("PS1", "\\s-\\v\\$ ")
			end
			require("repl").run(sh)
		elseif kind == "stdin" then
			require("repl").run(sh) -- non-interactive: line at a time from fd 0 (bash)
		elseif kind == "code" then
			Tier.run_tiered(payload, sh)
		else
			-- (bash: a missing script is `ARGV0: PATH: No such file or directory`, 127; any
			-- other open failure 126, a directory labeled with the path itself; errexit: 1)
			local f, err, errno = io.open(payload, "r")
			local s = f and f:read("*a")
			if f then
				f:close()
			end
			if s then
				Tier.run_tiered(s, sh)
			else
				local label = f and payload or (req.args[1] or "bash")
				io.stderr:write(label .. ": " .. payload .. ": "
					.. (f and "Is a directory" or (err or ""):match(": ([^:]+)$") or "No such file or directory") .. "\n")
				sh.status = sh.opt_e and 1 or (not f and errno == 2) and 127 or 126
			end
		end
	end, function(e)
		io.stderr:write("curse: internal error: " .. tostring(e) .. "\n" .. debug.traceback() .. "\n")
		return e
	end)
	io.flush()
	local status = ok and (sh.status or 0) or 1 -- a Lua error (never a script `exit`, which
	-- A FORKED DESCENDANT of this worker (a subshell/stage child) must never get here: if
	-- one unwinds this far (e.g. a failed `exec` in a forked pipeline stage), it would
	-- answer the client and then loop back into accept() as an untracked rogue worker,
	-- corrupting the pool's busy accounting. It just ends, with its status.
	if tonumber(C.getpid()) ~= ctx.worker_pid then
		C._exit(status % 256)
	end
	-- A forked `&` job would have been running all along; ours only runs when the shell
	-- blocks. Give live jobs a short slice BEFORE the reply, so `echo a & echo b` has
	-- written both lines by the time the caller reads the output (as bash's child has).
	if rt.sched_live() then
		pcall(rt.sched_pump, { deadline = rt.wall_secs() + 0.002, untilf = function()
			return not rt.sched_live()
		end })
		io.flush()
	end
	local sbuf = ffi.new("int32_t[1]", status) -- finish_run maps to $?) becomes status 1
	C.write(cfd, sbuf, 4)
	C.close(cfd)
	-- Background jobs outlive the script (the client has its status): this worker finishes
	-- them, then RETIRES — its slot reads -1 meanwhile (busy for the pool's saturation
	-- count, so a replacement is spawned on demand; never "client gone", so not killed)
	local drained = false
	if rt.sched_live() then
		ctx.busy[ctx.slot] = -1
		pcall(rt.sched_drain)
		drained = true
	end
	-- SCRUB per-request process state (the fork boundary used to do this):
	C.umask(ctx.umask) -- a script's `umask` doesn't persist
	C.sigprocmask(2, ctx.empty_sigset, nil) -- SIG_SETMASK: clear any trap-blocked signals
	-- dispositions back to the worker's own (drops trap handlers) — only if touched
	if req.sigign ~= ctx.sigign or (sh.sigtraps and next(sh.sigtraps)) then
		rt.sig_apply_mask(ctx.sigign)
	end
	if ctx.devnull >= 0 then
		C.dup2(ctx.devnull, 0)
		C.dup2(ctx.devnull, 1)
		C.dup2(ctx.devnull, 2)
	end
	-- ...and every other fd: a user `exec 3>file` must not persist into the next request,
	-- nor may a shell-internal save (>= rt.FD_BASE) a raise skipped restoring. Everything
	-- but the daemon's own [D_LO, D_HI) goes.
	C.syscall(436, ffi.new("int", 3), ffi.new("int", D_LO - 1), ffi.new("int", 0)) -- close_range
	C.syscall(436, ffi.new("unsigned int", D_HI), ffi.new("unsigned int", 0xFFFFFFFF), ffi.new("int", 0))
	-- ...and resource limits: a script's `ulimit -n 6` would otherwise cap every later
	-- request on this worker (fds can't be moved high -> plumbing collides). A lowered
	-- SOFT limit is restored; a lowered HARD limit can't be raised again unprivileged, so
	-- the worker RETIRES after this request and the parent spawns a clean one.
	local retire = drained -- (a worker that ran leftover jobs retires: its state is theirs)
	local cur = ffi.new("struct curse_d_rlimit")
	for res, orig in pairs(ctx.rlimits) do
		if C.curse_d_getrlimit(res, cur) == 0 and (cur.cur ~= orig.cur or cur.max ~= orig.max) then
			if cur.max < orig.max then
				retire = true
			else
				C.curse_d_setrlimit(res, orig)
			end
		end
	end
	ctx.active[0] = os.time() -- stamp the shared activity clock (drives the parent's idle-drain)
	return retire
end

-- Warm the PARENT before the pool forks (the workers inherit it copy-on-write): load every
-- lazily-required module (a builtin's module would otherwise load on its first use in
-- EACH worker) and run a representative builtins-only script through the tiered path —
-- interpreted, switched, compiled and warm — so the hot paths already have JIT traces.
local WARM_SRC = [==[
f() { local i=0 s=0; while [ $i -lt 300 ]; do s=$((s+i%7)); i=$((i+1)); done; echo "$s"; }
f >/dev/null
a=(one two three); declare -A m=([k]=v [x]=y); a+=(four); echo "${a[@]} ${#a[@]} ${m[k]} ${!m[@]}" >/dev/null
for w in alpha beta gamma; do case $w in a*) x=${w^^};; b*) x=${w#b};; *) x=${w//a/A};; esac; done
s="hello world"; [[ $s == h* && ${#s} -gt 3 ]] && t=${s:2:3}; printf '%s-%d
' "$t" 42 >/dev/null
while read -r l; do n=$l; done <<< $'1
2
3'
x=$(echo sub; echo two); y=$( (echo inner) ); z=`echo bq`
echo "p" | { read q; echo "$q"; } >/dev/null; echo a b c | while read -a arr; do :; done
set -- p1 p2 p3; shift; for p; do :; done; OPTIND=1; while getopts "ab:" o -a -b v; do :; done
mapfile -t lines <<< $'x
y'; test -n "$x"; [ "$y" = inner ]; type echo >/dev/null; declare -p a >/dev/null
trap 'e=1' USR1; trap - USR1; (( j = 3 * 4 )); let k=j+1; export W=1; unset W; readonly R0=1 2>/dev/null
{ echo g; } 2>/dev/null >/dev/null; ( cd / && pwd ) >/dev/null; : ${u:-def} ${v:=set}
]==]
local function warm_parent()
	for _, m in pairs(rt.BUILTIN_LAZY or {}) do
		pcall(require, m)
	end
	for _, m in ipairs({ "deparse", "hist", "helpdata", "emit", "parser", "interp", "b_eval", "b_source" }) do
		pcall(require, m)
	end
	local dn = C.open("/dev/null", 2, 0)
	local sv = {}
	for fd = 0, 2 do -- (its output goes nowhere)
		sv[fd] = rt.save_fd(fd)
		if dn >= 0 then
			C.dup2(dn, fd)
		end
	end
	local cwd = rt.Shell.new():phys_cwd()
	for i = 1, 4 do
		local sh = rt.Shell.new()
		pcall(Tier.run_tiered, WARM_SRC .. "\n# warm " .. (i % 2), sh) -- (a miss, then warm hits)
		pcall(Tier.compile_deferred)
		pcall(rt.sched_drain)
		io.flush()
	end
	C.chdir(cwd)
	for fd = 0, 2 do
		if sv[fd] >= 0 then
			C.dup2(sv[fd], fd)
			C.close(sv[fd])
		end
	end
	if dn >= 0 then
		C.close(dn)
	end
	collectgarbage("collect")
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
local function worker_main(lfd, my_uid, ctx, slot)
	ctx.worker_pid = tonumber(C.getpid()) -- (see serve_request's forked-descendant guard)
	ctx.slot = slot
	rt.daemon_worker = true
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
	local ctrl = ffi.new("char[512]") -- (fds 0,1,2 + up to 64 inherited extras)
	local cred = ffi.new("struct curse_ucred[1]")
	local credlen = ffi.new("unsigned int[1]")
	local served = 0
	local idlepf = ffi.new("struct curse_d_pollfd[1]")
	while true do
		local retire = false
		-- idle time: compile what ran interpreted (tier.run_tiered), one at a time, only
		-- while no connection waits — a request never queues behind a compile
		pcall(Tier.flush_stores) -- (the modules compiled mid-run: written now, off its limits)
		while Tier.has_deferred() do
			idlepf[0].fd, idlepf[0].events, idlepf[0].revents = lfd, 1, 0
			if C.curse_d_poll(idlepf, 1, 0) > 0 then
				break
			end
			pcall(Tier.compile_deferred, true)
		end
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
			ctx.busy[slot] = 1 -- serving: the parent counts busy slots to detect saturation
			-- The accepted control socket lands low (the daemon's other fds are now high),
			-- so move it high too before recvmsg/serve: a script's `read <&6` on the live
			-- connection would otherwise corrupt the reply protocol and hang the client for the
			-- request timeout (oil redirect#2: 10s vs bash's 3ms).
			cfd = fd_move_high(cfd)
			-- SO_PEERCRED: reject any peer that isn't us (defense-in-depth).
			credlen[0] = ffi.sizeof("struct curse_ucred")
			C.getsockopt(cfd, SOL_SOCKET, SO_PEERCRED, cred, credlen)
			if cred[0].pid > 1 then
				ctx.busy[slot] = cred[0].pid -- (the parent kills this worker if that client dies)
			end
			ctx.client_pid = cred[0].pid
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
				msg[0].controllen = 512
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
						retire = serve_request(cfd, req, fds, ctx)
					end
				end
			end
			ctx.busy[slot] = 0
			if retire then
				C._exit(0) -- not WORKER_IDLE: the parent replenishes the pool
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
	lock = fd_move_high(lock) -- the flock rides the shared OFD, so it survives the dup+close

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
	lfd = fd_move_high(lfd) -- workers (forked) inherit the high listen fd and accept() on it

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
	local devnull = fd_move_high(C.open("/dev/null", O_RDWR, 0))
	-- SHARED activity clock (mmap MAP_SHARED|ANON): persistent workers don't _exit per
	-- request, so the parent can't infer "still busy" from worker exits like the fork
	-- model did. Each worker stamps os.time() here after serving; the parent reads it to
	-- decide whether to replenish an idled-out worker or let the pool drain.
	local PROT_RW, MAP_SHARED_ANON = 3, 0x21 -- PROT_READ|WRITE, MAP_SHARED|MAP_ANONYMOUS
	local active = ffi.cast("long *", C.mmap(nil, 8, PROT_RW, MAP_SHARED_ANON, -1, 0))
	active[0] = os.time()
	-- SHARED per-worker busy flags (one slot per worker, single writer each): lets the
	-- parent see when EVERY worker is serving, so a nested request isn't stranded.
	local MAXW = 256
	local busy = ffi.cast("int *", C.mmap(nil, 4 * MAXW, PROT_RW, MAP_SHARED_ANON, -1, 0))
	-- The resource limits every request starts from (RLIMIT_CPU .. RLIMIT_RTTIME).
	local rlimits = {}
	for res = 0, 15 do
		local r = ffi.new("struct curse_d_rlimit")
		if C.curse_d_getrlimit(res, r) == 0 then
			rlimits[res] = r
		end
	end
	local ctx = {
		umask = orig_umask,
		empty_sigset = empty_sigset,
		sigign = rt.sig_ign_mask(), -- the worker's own ignored signals (restored per request)
		devnull = devnull,
		active = active,
		busy = busy,
		rlimits = rlimits,
	}

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

	-- ELASTIC beyond POOL: a script running in a worker can itself run curse (`$THIS_SH`,
	-- `sh -c` with curse as sh, a curse-shebang script) — that nested request needs ANOTHER
	-- worker while its parent's worker waits on it. With every worker busy the connection
	-- would sit in the backlog forever (a deadlock at nesting depth >= POOL, e.g. the bash
	-- suite's alias1.sub under a 1-worker pool). So the parent watches the listen socket:
	-- a connection pending while every live worker is busy forks an OVERFLOW worker (up to
	-- MAXW). Overflow workers idle out like any other and aren't replenished past POOL, so
	-- the pool shrinks back on its own.
	local live, pidslot, used = 0, {}, {}
	-- A pidfd per worker (readable once it exits), polled with the listen socket, so a worker
	-- that exits — retired after a request lowered a hard rlimit, crashed — is replaced RIGHT
	-- AWAY instead of on the next connection (which would otherwise wait for the fork).
	local pidfds = {} -- slot -> pidfd
	local function spawn()
		local slot
		for i = 0, MAXW - 1 do
			if not used[i] then
				slot = i
				break
			end
		end
		if not slot then
			return
		end
		busy[slot] = 0
		local pid = C.fork()
		if pid == 0 then
			for _, pfd in pairs(pidfds) do -- siblings' pidfds are the parent's business
				C.close(pfd)
			end
			worker_main(lfd, my_uid, ctx, slot)
			C._exit(0)
		end -- worker_main loops (persistent)
		if pid > 0 then
			live = live + 1
			used[slot], pidslot[pid] = true, slot
			local pfd = tonumber(C.syscall(434, ffi.new("int", pid), ffi.new("unsigned int", 0))) -- pidfd_open
			if pfd and pfd >= 0 then
				pidfds[slot] = pfd
			end
		end
	end
	warm_parent()
	for _ = 1, POOL do
		spawn()
	end

	local st = ffi.new("int[1]")
	local lp = ffi.new("struct curse_d_pollfd[?]", MAXW + 1)
	while live > 0 do
		while true do -- reap exited workers (a worker only exits on idle-timeout or crash)
			local pid = tonumber(C.waitpid(-1, st, WNOHANG))
			if not pid or pid <= 0 then
				break
			end
			local slot = pidslot[pid]
			if slot then
				pidslot[pid], used[slot] = nil, nil
				if pidfds[slot] then
					C.close(pidfds[slot])
					pidfds[slot] = nil
				end
				busy[slot] = 0
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
		if live == 0 then
			break
		end
		lp[0].fd, lp[0].events, lp[0].revents = lfd, 1, 0
		local np = 1
		for _, pfd in pairs(pidfds) do
			lp[np].fd, lp[np].events, lp[np].revents = pfd, 1, 0
			np = np + 1
		end
		-- a worker exit (pidfd readable) just loops back to the reap/respawn above
		local pr = C.curse_d_poll(lp, np, 1000)
		-- A worker whose CLIENT has died (killed by a timeout, ^C…) is still running an
		-- abandoned request: kill it (the reap above respawns it) — otherwise it holds its
		-- slot, and every later request queues behind it.
		for pid, slot in pairs(pidslot) do
			local cpid = busy[slot]
			if cpid > 1 and C.kill(cpid, 0) ~= 0 and ffi.errno() == 3 then -- ESRCH
				busy[slot] = 0
				C.kill(pid, 9)
			end
		end
		if pr > 0 and lp[0].revents ~= 0 then -- a connection is pending
			local nbusy = 0
			for slot in pairs(used) do
				if busy[slot] ~= 0 then
					nbusy = nbusy + 1
				end
			end
			if nbusy >= live and live < MAXW then
				spawn() -- nobody free to accept it: grow
				C.curse_d_poll(nil, 0, 20) -- let the new worker reach accept()
			else
				C.curse_d_poll(nil, 0, 2) -- an idle worker is taking it; don't spin
			end
		end
	end
	log("idle timeout; exiting")
	C.unlink(path)
end

serve()
