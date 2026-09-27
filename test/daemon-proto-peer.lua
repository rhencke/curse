-- A raw peer for the daemon's wire protocol (test/daemon-protocol.sh), speaking any
-- version's framing — what an old or a future curse-client / cursed would send:
--   luajit daemon-proto-peer.lua client SOCK v1|v2|vN   -- one `sh -c 'exit 7'` request;
--       prints "served N" (N the exit status) or "refused" (closed before any frame)
--   luajit daemon-proto-peer.lua olddaemon SOCK         -- a v1-only daemon: listens, takes
--       one connection, and (as v1 cursed does with a header it doesn't know) closes it
local ffi = require("ffi")
local C = ffi.C
ffi.cdef([[
struct dpp_sockaddr_un { unsigned short family; char path[108]; };
struct dpp_iovec { void *base; size_t len; };
struct dpp_msghdr { void *name; unsigned int namelen; struct dpp_iovec *iov; size_t iovlen;
	void *control; size_t controllen; int flags; };
int socket(int, int, int);
int connect(int, const void *, unsigned int);
int bind(int, const void *, unsigned int);
int listen(int, int);
int accept(int, void *, void *);
long sendmsg(int, const struct dpp_msghdr *, int);
long read(int, void *, unsigned long);
int close(int);
int unlink(const char *);
]])
local mode, sock, ver = arg[1], arg[2], arg[3]

local function addr()
	local a = ffi.new("struct dpp_sockaddr_un")
	a.family = 1 -- AF_UNIX
	ffi.copy(a.path, sock)
	return a
end
local function u32(n)
	return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256,
		math.floor(n / 16777216) % 256)
end
local function bytes(s)
	return u32(#s) .. s
end

if mode == "client" then
	local fd = C.socket(1, 1, 0)
	if C.connect(fd, addr(), ffi.sizeof("struct dpp_sockaddr_un")) ~= 0 then
		print("no daemon")
		os.exit(1)
	end
	local head
	if ver == "v1" then
		head = u32(0x43555253) -- "CURS": argv follows at once
	else
		head = u32(0x43555256) .. u32(tonumber(ver:sub(2))) .. u32(0) -- "CURV", version, closed fds
	end
	local req = head .. u32(3) .. bytes("sh") .. bytes("-c") .. bytes("exit 7") .. bytes("/")
		.. u32(1) .. bytes("PATH=/usr/bin:/bin") .. u32(0) .. u32(0)
	local buf = ffi.new("char[?]", #req)
	ffi.copy(buf, req, #req)
	local iov = ffi.new("struct dpp_iovec[1]")
	iov[0].base, iov[0].len = buf, #req
	-- one SCM_RIGHTS cmsghdr: len (size_t), level, type, then fds 0,1,2
	local ctl = ffi.new("char[40]")
	ffi.cast("size_t *", ctl)[0] = 16 + 12
	ffi.cast("int *", ctl + 8)[0] = 1 -- SOL_SOCKET
	ffi.cast("int *", ctl + 12)[0] = 1 -- SCM_RIGHTS
	local fds = ffi.cast("int *", ctl + 16)
	fds[0], fds[1], fds[2] = 0, 1, 2
	local msg = ffi.new("struct dpp_msghdr")
	msg.iov, msg.iovlen, msg.control, msg.controllen = iov, 1, ctl, 32
	if C.sendmsg(fd, msg, 0x4000) < 0 then -- MSG_NOSIGNAL
		print("send failed")
		os.exit(1)
	end
	local frame, frames = ffi.new("int32_t[1]"), 0
	while true do
		local n = tonumber(C.read(fd, frame, 4))
		if n ~= 4 then
			print(frames == 0 and "refused" or "cut off")
			break
		end
		frames = frames + 1
		if frame[0] >= 0 then
			print("served " .. frame[0])
			break
		end
	end
	C.close(fd)
elseif mode == "olddaemon" then
	local fd = C.socket(1, 1, 0)
	C.unlink(sock)
	if C.bind(fd, addr(), ffi.sizeof("struct dpp_sockaddr_un")) ~= 0 or C.listen(fd, 4) ~= 0 then
		os.exit(1)
	end
	print("listening")
	io.stdout:flush()
	local cfd = C.accept(fd, nil, nil)
	local b = ffi.new("char[65536]")
	C.read(cfd, b, 65536) -- (the request: its magic isn't "CURS" — dropped, as v1 cursed does)
	C.close(cfd)
	C.close(fd)
	C.unlink(sock)
end
