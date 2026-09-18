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
local sherr = I.sherr

return function(sh, cmd, args, hook, tcb)
	if cmd == "pushd" or cmd == "popd" or cmd == "dirs" then
		sh.dirstack = sh.dirstack or { sh:pwd() }
		local function cd_to(p)
			C.chdir(p)
			sh:export_str("PWD", p)
		end
		local ds = sh.dirstack
		-- collapse a leading $HOME to ~ only at a path boundary (not a mere prefix:
		-- HOME=/a/b must NOT turn /a/bc into ~c).
		local function tilde(p)
			local h = sh:get("HOME")
			if h ~= "" and p:sub(1, #h) == h and (#p == #h or p:sub(#h + 1, #h + 1) == "/") then
				return "~" .. p:sub(#h + 1)
			end
			return p
		end
		if cmd == "dirs" then
			local vflag, pflag, lflag = false, false, false
			for j = 2, #args do
				local a = args[j]
				if a == "-c" then
					sh.dirstack = { sh:pwd() }
					ds = sh.dirstack
				elseif a == "-v" then
					vflag = true
				elseif a == "-p" then
					pflag = true
				elseif a == "-l" then
					lflag = true
				elseif a:match("^[+-]%d+$") then -- +N / -N select one entry (accepted)
				else
					io.stderr:write("curse: dirs: " .. a .. ": invalid option\n")
					sh.status = 2
					return
				end
			end
			if not args[2] or not args[2]:find("c") or vflag or pflag or lflag then
				local parts = {}
				for k = 1, #ds do
					parts[k] = lflag and ds[k] or tilde(ds[k])
				end
				if vflag then
					for k = 1, #parts do
						sh:echo(("%2d  %s"):format(k - 1, parts[k]))
					end
				elseif pflag then
					for k = 1, #parts do
						sh:echo(parts[k])
					end
				else
					sh:echo(table.concat(parts, " "))
				end
			end
			sh.status = 0
		elseif cmd == "pushd" then
			local target, nops = nil, 0
			for j = 2, #args do
				local a = args[j]
				if a == "--" then
					target = args[j + 1]
					nops = nops + (args[j + 1] and 1 or 0)
					break
				elseif a:sub(1, 1) == "-" and a ~= "-" and not a:match("^[+-]%d+$") then
					io.stderr:write("curse: pushd: " .. a .. ": invalid option\n")
					sh.status = 2
					return
				else
					nops = nops + 1
					if not target then
						target = a
					end
				end
			end
			if nops > 1 then
				io.stderr:write("curse: pushd: too many arguments\n")
				sh.status = 1
				return
			end
			if not target then -- swap top two
				if #ds < 2 then
					io.stderr:write("curse: pushd: no other directory\n")
					sh.status = 1
					return
				end
				local prev = sh:pwd()
				ds[1], ds[2] = ds[2], ds[1]
				cd_to(ds[1])
				sh:set_str("OLDPWD", prev)
			else
				local prev = sh:pwd()
				if C.chdir(target) ~= 0 then
					io.stderr:write("curse: pushd: " .. target .. ": No such file or directory\n")
					sh.status = 1
					return
				end
				local np = sh:phys_cwd()
				sh:set_str("OLDPWD", prev)
				sh:export_str("PWD", np)
				table.insert(ds, 1, np)
			end
			local parts = {}
			for k = 1, #ds do
				parts[k] = tilde(ds[k])
			end
			sh:echo(table.concat(parts, " "))
			sh.status = 0
		else -- popd
			for j = 2, #args do
				local a = args[j]
				if a == "--" then -- ok
				elseif a:sub(1, 1) == "-" and a ~= "-" and not a:match("^[+-]%d+$") then
					io.stderr:write("curse: popd: " .. a .. ": invalid option\n")
					sh.status = 2
					return
				elseif a ~= "-" then
					io.stderr:write("curse: popd: " .. a .. ": invalid argument\n")
					sh.status = 2
					return
				end
			end
			if #ds < 2 then
				sherr(sh, "curse: popd: directory stack empty\n")
				sh.status = 1
				return
			end
			table.remove(ds, 1)
			cd_to(ds[1])
			local parts = {}
			for k = 1, #ds do
				parts[k] = tilde(ds[k])
			end
			sh:echo(table.concat(parts, " "))
			sh.status = 0
		end
	end
end
