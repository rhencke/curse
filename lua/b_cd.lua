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
local logical_canon = I.logical_canon

return function(sh, cmd, args, hook, tcb)
	if cmd == "cd" then
		local prev = sh:pwd()
		-- parse leading -L/-P/-e/-@ flags and a `--`, then the directory operand.
		local operands, j, physical = {}, 2, false
		while args[j] do
			local a = args[j]
			if a == "--" then
				j = j + 1
				break
			elseif a == "-" then
				operands[#operands + 1] = a
				j = j + 1
			elseif a:match("^%-[LPe@]+$") then
				if a:find("P") then
					physical = true
				elseif a:find("L") then
					physical = false
				end
				j = j + 1
			else
				break
			end
		end
		for k = j, #args do
			operands[#operands + 1] = args[k]
		end
		if #operands > 1 then
			io.stderr:write("curse: cd: too many arguments\n")
			sh.status = 1
			return
		end
		local dir, print_dir = operands[1], false
		if dir == "-" then
			dir = sh:get("OLDPWD")
			if dir == "" then
				io.stderr:write("curse: cd: OLDPWD not set\n")
				sh.status = 1
				return
			end
			print_dir = true
		elseif dir == nil or dir == "" then
			dir = sh:get("HOME")
			if dir == "" then
				io.stderr:write("curse: cd: HOME not set\n")
				sh.status = 1
				return
			end
		elseif
			dir:sub(1, 1) ~= "/"
			and dir ~= "."
			and dir:sub(1, 2) ~= "./"
			and dir ~= ".."
			and dir:sub(1, 3) ~= "../"
		then
			-- CDPATH: a relative operand (not . / ..) is looked up under each entry.
			local cdpath = sh:get("CDPATH")
			if cdpath ~= "" then
				for entry in (cdpath .. ":"):gmatch("([^:]*):") do
					local cand = (entry == "" and "." or entry) .. "/" .. dir
					if C.chdir(cand) == 0 then
						dir = cand
						print_dir = true
						break
					end
				end
			end
		end
		-- logical target: resolve . and .. against $PWD textually (unless -P)
		local logical = logical_canon(dir:sub(1, 1) == "/" and dir or (prev .. "/" .. dir))
		-- bash chdir's the LITERAL operand first — this validates that every path
		-- component really exists, so `cd nonexistent/..` is an error even though `..`
		-- would textually cancel it. In logical mode it then moves to the canonicalized
		-- path so the process and $PWD agree logically (e.g. `cd symlink/..` lands in
		-- the symlink's textual parent, not its physical one).
		if C.chdir(dir) ~= 0 then
			io.stderr:write("curse: cd: " .. dir .. ": No such file or directory\n")
			sh.status = 1
			return
		end
		if not physical then
			C.chdir(logical)
		end
		sh.status = 0
		local newpwd = physical and sh:phys_cwd() or logical
		sh:export_str("OLDPWD", prev)
		sh:export_str("PWD", newpwd)
		if print_dir then
			sh:echo(newpwd)
		end
		if sh.dirstack then
			sh.dirstack[1] = newpwd
		end
	end
end
