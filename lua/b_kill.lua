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

return function(sh, cmd, args, hook, tcb)
	if cmd == "kill" then
		if args[2] == "-l" or args[2] == "-L" then -- list / translate signal names<->numbers
			if #args == 2 then
				sh.out(rt.signal_list(NUMSIG))
				sh.status = 0
			else
				local allok = true
				for k = 3, #args do
					local a = args[k]
					local n = tonumber(a)
					if n then
						if n > 128 then
							n = n - 128
						end
						local nm = n == 0 and "EXIT" or NUMSIG[n] -- signal 0 is the pseudo-signal EXIT
						if nm then
							sh:echo(nm)
						else
							allok = false
							io.stderr:write("curse: kill: " .. a .. ": invalid signal specification\n")
						end
					elseif a:upper():gsub("^SIG", "") == "EXIT" then
						sh:echo("0") -- name EXIT maps back to 0
					else
						local num = SIGNUM[a:gsub("^SIG", "")]
						if num then
							sh:echo(tostring(num))
						else
							allok = false
							io.stderr:write("curse: kill: " .. a .. ": invalid signal specification\n")
						end
					end
				end
				sh.status = allok and 0 or 1
			end
		else
			local j, sig, bad = 2, 15, nil -- default SIGTERM
			-- Resolve a signal spec to its number: a name (TERM/SIGTERM) via SIGNUM, or a
			-- number that names a real signal (or 0 = the null check). An unknown name or
			-- an out-of-range number (`kill -s 9999`) is invalid → status 1, not silently 15.
			local function resolve_sig(spec)
				local n = tonumber(spec)
				if n then
					return (n == 0 or NUMSIG[n]) and n or nil
				end
				return SIGNUM[(spec or ""):upper():gsub("^SIG", "")] -- names are case-insensitive
			end
			while args[j] and args[j]:match("^%-.") do -- (bash: options until a non-option)
				local a = args[j]
				if a == "--" then
					j = j + 1
					break
				elseif a == "-n" or a == "-s" then
					if args[j + 1] == nil then
						io.stderr:write("curse: kill: " .. a .. ": option requires an argument\n")
						sh.status = 1
						return
					end
					sig = resolve_sig(args[j + 1])
					bad = sig == nil and args[j + 1] or nil
					j = j + 2
				else
					sig = resolve_sig(a:sub(2))
					bad = sig == nil and a:sub(2) or nil
					j = j + 1
				end
				if bad then
					io.stderr:write("curse: kill: " .. bad .. ": invalid signal specification\n")
					sh.status = 1
					return
				end
			end
			if args[j] == nil then
				io.stderr:write(rt.usage("kill"))
				sh.status = 2
				return
			end
			local allok = true
			for k = j, #args do
				local target = args[k]
				local pid = target:match("^%s*[+-]?%d+%s*$") and tonumber(target)
				if pid and (rt.vpid_ctx[pid] or rt.vpid_tasks[pid]) then -- an in-process subshell or job
					if not rt.vkill(sh, pid, sig) then
						io.stderr:write("curse: kill: (" .. pid .. ") - No such process\n")
						allok = false
					end
				elseif pid then
					if C.kill(pid, sig) ~= 0 then
						io.stderr:write("curse: kill: (" .. pid .. ") - " .. ffi.string(C.strerror(ffi.errno())) .. "\n")
						allok = false
					end
				elseif target == "" then
					io.stderr:write("curse: kill: `': not a pid or valid job spec\n")
					allok = false
				elseif target:sub(1, 1) ~= "%" then
					io.stderr:write("curse: kill: " .. target .. ": arguments must be process or job IDs\n")
					allok = false
				else -- %-jobspec: resolve to its pid
					local jb = job_resolve(sh, target)
					if not jb then
						io.stderr:write("curse: kill: " .. target .. ": no such job\n")
						allok = false
					elseif rt.vpid_ctx[jb.pid] or rt.vpid_tasks[jb.pid] then -- (an in-process job)
						if not rt.vkill(sh, jb.pid, sig) then
							allok = false
						end
					elseif C.kill(jb.pid, sig) ~= 0 then
						allok = false
					end
				end
			end
			sh.status = allok and 0 or 1
		end
	end
end
