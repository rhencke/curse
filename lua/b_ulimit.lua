-- Lazily-loaded builtin feature module (see BUILTIN_LAZY in interp.lua). Its own
-- module -- no grab bags -- so a script loads only the builtin it uses. Internals
-- aliased to interp's names so the branch body is a verbatim copy.
local ffi = require("ffi")
local rt = require("runtime")
local M = require("interp")
local I = M._int
local exec_simple, expand_part_str, tilde_word_initial, file_test, sq =
	I.exec_simple, I.expand_part_str, I.tilde_word_initial, I.file_test, I.sq
local BUILTINS, KEYWORDS, SETOPTS, SHOPT_ORDER = I.BUILTINS, I.KEYWORDS, I.SETOPTS, I.SHOPT_ORDER
local parse_umask, umask_symbolic = I.parse_umask, I.umask_symbolic
local job_reap, block_sig, canon_sig, sig_order = I.job_reap, I.block_sig, I.canon_sig, I.sig_order
local find_all_in_path, name_type, SIGNUM, NUMSIG = I.find_all_in_path, I.name_type, I.SIGNUM, I.NUMSIG
local array_key, sh_printf, fd_getc, fd_ready, read_split =
	I.array_key, I.sh_printf, I.fd_getc, I.fd_ready, I.read_split
local do_arrayassign, eval, fmt_decl, fmt_set_var = I.do_arrayassign, I.eval, I.fmt_decl, I.fmt_set_var
local C, P = I.C, I.P

return function(sh, cmd, args, hook, tcb)
	if cmd == "ulimit" then
		-- ulimit [-HSaflags] [limit]: get/set process resource limits (getrlimit/
		-- setrlimit). Reported/accepted in each resource's block unit; `unlimited`.
		local INF = 0xFFFFFFFFFFFFFFFFULL
		local RES = { -- flag -> { resource, bytes-per-unit, label, unit-name } (bash's limits[])
			R = { 15, 1, "real-time non-blocking time", "microseconds" },
			c = { 4, 512, "core file size", "blocks" },
			d = { 2, 1024, "data seg size", "kbytes" },
			e = { 13, 1, "scheduling priority", nil },
			f = { 1, 1024, "file size", "blocks" },
			i = { 11, 1, "pending signals", nil },
			l = { 8, 1024, "max locked memory", "kbytes" },
			m = { 5, 1024, "max memory size", "kbytes" },
			n = { 7, 1, "open files", nil },
			p = { -1, 512, "pipe size", "512 bytes" },
			q = { 12, 1, "POSIX message queues", "bytes" },
			r = { 14, 1, "real-time priority", nil },
			s = { 3, 1024, "stack size", "kbytes" },
			t = { 0, 1, "cpu time", "seconds" },
			u = { 6, 1, "max user processes", nil },
			v = { 9, 1024, "virtual memory", "kbytes" },
			x = { 10, 1, "file locks", nil },
		}
		local AORDER = { "R", "c", "d", "e", "f", "i", "l", "m", "n", "p", "q", "r", "s", "t", "u", "v", "x" }
		-- bash's printone: the description, then `(unit, -X) ` right-aligned in 20
		local function line(fl, v)
			local r = RES[fl]
			local us = r[4] and ("(%s, -%s) "):format(r[4], fl) or ("(-%s) "):format(fl)
			return ("%-20s %20s%s"):format(r[3], us, v)
		end
		local rl = ffi.new("struct curse_rlimit[1]")
		local hardflag, softflag = false, false
		-- GET one resource: -H reads the hard limit (rlim_max), else the soft (rlim_cur).
		local function report(fl)
			local r = RES[fl]
			if not r then
				return "unlimited"
			end
			if r[1] < 0 then
				return "8" -- (pipe size: PIPE_BUF 4096 in 512-byte units, as bash reports)
			end
			if C.getrlimit(r[1], rl) ~= 0 then
				return nil
			end
			local v = hardflag and (rt.iso_vhard(sh, r[1]) or rl[0].rlim_max) or rl[0].rlim_cur
			if v == INF then
				return "unlimited"
			end
			return (tostring(v / r[2]):gsub("[UuLl]+$", "")) -- drop LuaJIT's cdata "ULL" suffix
		end
		-- Options as bash's internal_getopt with ulimit's optstring: -a, -S/-H modifiers, and
		-- each resource letter taking an OPTIONAL argument — the rest of its word, or the next
		-- word unless that looks like an option (bash's `;`). Each (letter, arg) is a command.
		local cmds, allmode = {}, false
		local j = 2
		while args[j] and args[j]:sub(1, 1) == "-" and #args[j] > 1 do
			local a = args[j]
			j = j + 1
			if a == "--" then
				break
			end
			local k = 2
			while k <= #a do
				local f = a:sub(k, k)
				if f == "a" then
					allmode = true
				elseif f == "H" then
					hardflag = true
				elseif f == "S" then
					softflag = true
				elseif RES[f] then
					local arg
					if k < #a then
						arg, k = a:sub(k + 1), #a
					elseif args[j] and not (args[j]:sub(1, 1) == "-" and #args[j] > 1) then
						arg, j = args[j], j + 1
					end
					cmds[#cmds + 1] = { f = f, arg = arg }
				else
					return rt.bad_option(sh, "ulimit", "-" .. f, a)
				end
				k = k + 1
			end
		end
		if not allmode then
			if #cmds == 0 then -- (`ulimit N` is `ulimit -f N`)
				cmds[1] = { f = "f", arg = args[j] }
				j = j + 1
			elseif args[j] and cmds[#cmds].arg == nil then -- (posix: an operand is the last
				cmds[#cmds].arg = args[j] -- command's argument)
			end
		end
		-- SET one resource (bash's ulimit_internal): with neither -S nor -H both limits
		local function set_one(fl, value)
			local r = RES[fl]
			local setsoft, sethard = softflag or not hardflag, hardflag or not softflag
			local nv
			if value == "hard" or value == "soft" then
				if C.getrlimit(r[1], rl) ~= 0 then
					return false
				end
				nv = value == "hard" and (rt.iso_vhard(sh, r[1]) or rl[0].rlim_max) or rl[0].rlim_cur
			elseif value == "unlimited" then
				nv = INF
			elseif value:match("^%d+$") then
				local num = tonumber(value)
				if num == nil or num * r[2] > 9223372036854775807 then
					io.stderr:write("curse: ulimit: " .. value .. ": limit out of range\n")
					return false
				end
				nv = ffi.cast("uint64_t", num) * ffi.cast("uint64_t", r[2])
			else
				io.stderr:write("curse: ulimit: " .. value .. ": " .. rt.invalidnum_msg(value) .. "\n")
				return false
			end
			if r[1] < 0 or C.getrlimit(r[1], rl) ~= 0 then
				return false
			end
			-- in an in-process subshell a hard limit stays virtual (lowering the real one
			-- could never be undone); the soft limit is real, within it
			local ctx = rt.iso_cur(sh) and rt.iso_save_rlimits(sh)
			local vh = rt.iso_vhard(sh, r[1]) or rl[0].rlim_max
			local virt = ctx or sh.iso_vhard_base
			local err
			if setsoft then
				rl[0].rlim_cur = nv
			end
			if sethard and virt then
				if nv > vh and C.geteuid() ~= 0 then
					err = 1 -- EPERM
				elseif not setsoft and rl[0].rlim_cur > nv then
					err = 22 -- EINVAL
				end
			elseif sethard then
				rl[0].rlim_max = nv
			end
			if not err and virt and setsoft and rl[0].rlim_cur > (sethard and nv or vh) then
				err = 22
			end
			if not err and C.setrlimit(r[1], rl) ~= 0 then
				err = ffi.errno()
			end
			if err then
				io.stderr:write("curse: ulimit: " .. r[3] .. ": cannot modify limit: "
					.. ffi.string(C.strerror(err)) .. "\n")
				return false
			elseif ctx and sethard then
				ctx.vhard[r[1]] = nv
			end
			return true
		end
		if not allmode then
			sh.status = 0
			for _, c in ipairs(cmds) do -- (the first failure ends it: status 1)
				if c.arg ~= nil then
					if not set_one(c.f, c.arg) then
						sh.status = 1
						return
					end
				else
					local v = report(c.f)
					sh:echo(#cmds > 1 and line(c.f, v or "unlimited") or (v or "unlimited"))
				end
			end
			sh.write_err, sh.status = nil, 0 -- (ulimit.def: only the -a listing ends in sh_chkwrite)
		else -- -a: list all (a trailing value is ignored — bash prints all, status 0)
			for _, fl in ipairs(AORDER) do
				sh:echo(line(fl, report(fl) or "unlimited"))
			end
			sh.status = 0
		end
	end
end
