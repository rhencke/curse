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
local opt_on, set_opt, SETOPT, SHOPT_DEFAULT, shopt_on = I.opt_on, I.set_opt, I.SETOPT, I.SHOPT_DEFAULT, I.shopt_on

return function(sh, cmd, args, hook, tcb)
	if cmd == "shopt" then
		-- shopt [-s|-u|-q|-p|-o] [names]: set/unset/query shell options (subset).
		local set_, unset_, quiet, oflag, pflag, badopt = false, false, false, false, false, false
		-- (options up to the first operand or `--`: bash's internal_getopt)
		local names = {}
		local k0 = 2
		while args[k0] and args[k0]:sub(1, 1) == "-" and #args[k0] > 1 and not badopt do
			local a = args[k0]
			k0 = k0 + 1
			if a == "--" then
				break
			elseif a:match("^-[suqpo]+$") then
				if a:find("s") then
					set_ = true
				end
				if a:find("u") then
					unset_ = true
				end
				if a:find("q") then
					quiet = true
				end
				if a:find("o") then
					oflag = true
				end
				if a:find("p") then
					pflag = true
				end
			else
				badopt = a -- (`-z`, and long opts, are invalid options — bash)
			end
		end
		for k = k0, #args do
			names[#names + 1] = args[k]
		end
		-- one option in the requested form (-p: a reusable command; else two columns)
		local function show(nm, on, cmdform)
			if pflag then
				sh.out(cmdform)
			else
				sh.out(("%-15s\t%s\n"):format(nm, on and "on" or "off"))
			end
		end
		if badopt then
			local bad = badopt:sub(1, 2) == "--" and badopt or ("-" .. (badopt:match("^%-[suqpo]*(.)") or ""))
			io.stderr:write("curse: shopt: " .. bad .. ": invalid option\n")
			io.stderr:write("shopt: usage: shopt [-pqsu] [-o] [optname ...]\n")
			sh.status = 2
		elseif set_ and unset_ then
			io.stderr:write("curse: shopt: cannot set and unset shell options simultaneously\n")
			sh.status = 1
		elseif oflag and #names == 0 then -- list the set -o options (-s/-u: only on/off ones)
			for _, ent in ipairs(SETOPTS) do
				local on = opt_on(sh, ent[2])
				if not (set_ and not on) and not (unset_ and on) then
					show(ent[1], on, ("set %so %s\n"):format(on and "-" or "+", ent[1]))
				end
			end
			sh.status = 0
		elseif oflag then -- shopt -o: the `set -o` options
			if set_ or unset_ then
				local allok = true
				for _, nm in ipairs(names) do
					if SETOPT[nm] then
						set_opt(sh, SETOPT[nm], set_)
					else
						io.stderr:write("curse: shopt: " .. nm .. ": invalid option name\n")
						allok = false
					end
				end
				sh.status = allok and 0 or 1
			elseif #names == 0 then -- list all set-o options
				for _, ent in ipairs(SETOPTS) do
					if pflag then
						sh.out(("set %so %s\n"):format(opt_on(sh, ent[2]) and "-" or "+", ent[1]))
					else
						sh.out(("%-15s\t%s\n"):format(ent[1], opt_on(sh, ent[2]) and "on" or "off"))
					end
				end
				sh.status = 0
			else
				local allok = true
				for _, nm in ipairs(names) do
					if not SETOPT[nm] then
						io.stderr:write("curse: shopt: " .. nm .. ": invalid option name\n")
						allok = false
					else
						local on = opt_on(sh, SETOPT[nm])
						if not on then
							allok = false
						end
						if not quiet then
							if pflag then
								sh.out(("set %so %s\n"):format(on and "-" or "+", nm))
							else
								sh.out(("%-15s\t%s\n"):format(nm, on and "on" or "off"))
							end
						end
					end
				end
				sh.status = allok and 0 or 1
			end
		elseif (set_ or unset_) and #names > 0 then
			-- -s/-u NAMES: unknown names error (status 1) but valid ones still apply.
			local allok = true
			for _, nm in ipairs(names) do
				if SHOPT_DEFAULT[nm] == nil then
					io.stderr:write("curse: shopt: " .. nm .. ": invalid shell option name\n")
					allok = false
				elseif nm:match("^compat%d%d$") then -- (set_compatibility_level: $BASH_COMPAT follows)
					local lvl, cur = tonumber(nm:sub(7)), rt.compat_level(sh)
					local new = set_ and lvl or ((cur ~= lvl and (cur <= 44 or cur < 52)) and cur or 52)
					sh:set_str("BASH_COMPAT", tostring(new))
				else
					sh.shopt[nm] = set_
					if nm == "extdebug" then -- (shopt.c shopt_set_debug_mode: function and error
						sh.opt_functrace, sh.opt_errtrace = set_, set_ -- tracing follow it)
					end
				end
			end
			sh.status = allok and 0 or 1
		elseif #names == 0 then -- list the options (-s/-u: only the on/off ones)
			for _, nm in ipairs(SHOPT_ORDER) do
				local on = shopt_on(sh, nm)
				if not (set_ and not on) and not (unset_ and on) then
					show(nm, on, ("shopt %s%s\n"):format(on and "-s " or "-u ", nm))
				end
			end
			sh.status = 0
		else -- query / print named: invalid names skipped, drop status to 1
			local allok = true
			for _, nm in ipairs(names) do
				if SHOPT_DEFAULT[nm] == nil then
					io.stderr:write("curse: shopt: " .. nm .. ": invalid shell option name\n")
					allok = false
				else
					local on = shopt_on(sh, nm)
					if not on then
						allok = false
					end
					if not quiet then
						if pflag then
							sh.out(("shopt %s%s\n"):format(on and "-s " or "-u ", nm))
						else
							sh.out(("%-15s\t%s\n"):format(nm, on and "on" or "off"))
						end
					end
				end
			end
			sh.status = allok and 0 or 1
		end
	end
end
