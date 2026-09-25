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
local job_resolve = I.job_resolve

-- bash's decode_signal (trap.c): a legal_number 0..64, [SIG]RTMIN+N, or a name — any case
-- (DSIG_NOCASE); with or without SIG unless `prefix` is off (posix mode drops
-- DSIG_SIGPREFIX: only the bare name); EXIT, DEBUG, ERR, RETURN are 0, 65, 66, 67.
local PSEUDO = { EXIT = 0, DEBUG = 65, ERR = 66, RETURN = 67 }
local function decode_signal(s, prefix)
	local n = rt.legal_number(s)
	if n then
		return (n >= 0 and n <= 64) and n or nil
	end
	local u = s:upper()
	local rtn = u:match("^SIGRTMIN%+(.*)$") or u:match("^RTMIN%+(.*)$")
	if rtn then
		n = rt.legal_number(rtn)
		return n and n >= 0 and n <= 30 and SIGNUM.RTMIN + n or nil
	end
	if PSEUDO[u] then
		return PSEUDO[u]
	end
	if u:sub(1, 3) == "SIG" then
		return prefix and SIGNUM[u:sub(4)] or nil
	end
	return SIGNUM[u]
end
-- display_signal_list (builtins/common.c) for `kill -l`/`-L`: the table, or each word's
-- translation — a number (less 128 when above) to its name without SIG, a name to its number
local function signal_list(sh, args, k)
	if not args[k] then
		if sh.opt_posix then -- (the names, SIG-less, on one line)
			local t = {}
			for n = 1, 64 do
				if NUMSIG[n] then
					t[#t + 1] = NUMSIG[n]
				end
			end
			sh.out(table.concat(t, " ") .. "\n")
		else
			sh.out(rt.signal_list(NUMSIG))
		end
		return 0
	end
	local st = 0
	for i = k, #args do
		local a = args[i]
		local n = rt.legal_number(a)
		if n then
			if n > 128 then
				n = n - 128
			end
			if n < 0 or n > 64 then
				io.stderr:write("curse: kill: " .. a .. ": invalid signal specification\n")
				st = 1
			elseif n == 0 then
				sh:echo("EXIT")
			elseif NUMSIG[n] then -- (32, 33 have no name: nothing)
				sh:echo(NUMSIG[n])
			end
		else
			n = decode_signal(a, not sh.opt_posix)
			if n then
				sh:echo(tostring(n))
			else
				io.stderr:write("curse: kill: " .. a .. ": invalid signal specification\n")
				st = 1
			end
		end
	end
	return st
end

-- kill_pid for a job (jobs.c): each of its processes that's still alive gets the signal; one
-- that has ended is skipped, and that is success
local function kill_job(sh, jb, sig)
	if jb.done then
		return true
	end
	local t = rt.vpid_tasks[jb.pid]
	if t then -- (an in-process job)
		return rt.task_kill_job(t, sig) or t.done or false
	elseif rt.vpid_ctx[jb.pid] then
		return rt.vkill(sh, jb.pid, sig)
	end
	if C.kill(jb.pid, sig) ~= 0 then
		return ffi.errno() == 3 -- (ESRCH: it ended, just not reaped yet)
	end
	return true
end

return function(sh, cmd, args, hook, tcb)
	if cmd == "kill" then
		-- kill.def: options until the first operand — -l/-L (listing), -s SIG / -n NUM (also
		-- glued, `-sTERM` `-n9`), `--`, `-?`, and the FIRST -SIGSPEC; a later `-word` is an
		-- operand (a process group), never a second signal
		if not args[2] then
			io.stderr:write(rt.usage("kill"))
			sh.status = 2
			return
		end
		if args[2] == "--help" then -- (CHECK_HELPOPT)
			return rt.builtin_help(sh, "kill")
		end
		local prefix = not sh.opt_posix
		local j, sig, spec, listing, saw = 2, 15, "TERM", false, false
		while args[j] do
			local a = args[j]
			if a == "-l" or a == "-L" then
				listing = true
				j = j + 1
			elseif a == "-s" or a == "-n" then
				if args[j + 1] == nil then
					io.stderr:write("curse: kill: " .. a .. ": option requires an argument\n")
					sh.status = 1
					return
				end
				spec = args[j + 1]
				sig = spec == "0" and 0 or decode_signal(spec, prefix)
				saw = true
				j = j + 2
			elseif a:match("^%-s%a") or a:match("^%-n%d") then
				spec = a:sub(3)
				sig = spec == "0" and 0 or decode_signal(spec, prefix)
				saw = true
				j = j + 1
			elseif a == "--" then
				j = j + 1
				break
			elseif a == "-?" then
				io.stderr:write(rt.usage("kill"))
				sh.status = 2
				return
			elseif a:sub(1, 1) == "-" and not saw then
				spec = a:sub(2)
				sig = decode_signal(spec, prefix)
				saw = true
				j = j + 1
			else
				break
			end
		end
		if listing then
			sh.status = signal_list(sh, args, j)
			return
		end
		if sig == nil or sig > 64 then -- (the trap-only DEBUG/ERR/RETURN aren't signals)
			io.stderr:write("curse: kill: " .. spec .. ": invalid signal specification\n")
			sh.status = 1
			return
		end
		if args[j] == nil then
			io.stderr:write(rt.usage("kill"))
			sh.status = 2
			return
		end
		-- CONTINUE_AFTER_KILL_ERROR: every operand is tried; success if any one succeeded
		local any = false
		for k = j, #args do
			local target = args[k]
			-- (legal_number, and it must fit a pid_t — bash: `pid_value == (pid_t)pid_value`;
			-- else a huge number cast to 0 or -1 would signal our group or everything)
			local pid = (target:gsub("^%-", "") ~= "") and rt.legal_number(target)
			if pid and (pid > 2147483647 or pid < -2147483648) then
				pid = nil
			end
			if pid and (rt.vpid_ctx[pid] or rt.vpid_tasks[pid]) then -- an in-process subshell or job
				if rt.vkill(sh, pid, sig) then
					any = true
				else
					io.stderr:write("curse: kill: (" .. pid .. ") - No such process\n")
				end
			elseif pid then
				if pid == C.getpid() and sig ~= 0 then -- (to ourselves: taken once kill is done)
					rt.self_sig_hold(sig)
				end
				if C.kill(pid, sig) ~= 0 then
					io.stderr:write("curse: kill: (" .. pid .. ") - " .. ffi.string(C.strerror(ffi.errno())) .. "\n")
				else
					any = true
				end
			elseif target ~= "" and target:sub(1, 1) ~= "%" then
				io.stderr:write("curse: kill: " .. target .. ": arguments must be process or job IDs\n")
			elseif target:gsub("^%-", "") ~= "" then -- %-jobspec: signal the job's processes
				local jb, dup = job_resolve(sh, target, "kill")
				if jb then
					if kill_job(sh, jb, sig) then
						any = true
					else
						io.stderr:write("curse: kill: (" .. jb.pid .. ") - No such process\n")
					end
				elseif not dup then
					io.stderr:write("curse: kill: " .. target .. ": no such job\n")
				end
			else
				io.stderr:write("curse: kill: `" .. target .. "': not a pid or valid job spec\n")
			end
		end
		sh.status = any and 0 or 1
		rt.self_sig_release(sh)
	end
end
