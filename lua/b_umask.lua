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
	if cmd == "umask" then
		-- umask [-S] [MODE]: print (octal or -S symbolic) or set the file-creation mask.
		local sflag, pflag, badflag, pos = false, false, false, {}
		for j = 2, #args do
			local a = args[j]
			if a == "-S" then
				sflag = true
			elseif a == "-p" then
				pflag = true -- print in a form that can be eval'd
			elseif a:sub(1, 1) == "-" and #a > 1 then
				badflag = true
			else
				pos[#pos + 1] = a
			end
		end
		local cur = tonumber(C.umask(0)) % 512
		C.umask(cur)
		if badflag then
			io.stderr:write("curse: umask: invalid option\n")
			sh.status = 1
		elseif #pos == 0 then -- bash ignores extra args; it uses only the first MODE
			local body = sflag and umask_symbolic(cur) or string.format("%04o", cur)
			sh:echo(pflag and ("umask " .. (sflag and "-S " or "") .. body) or body)
			sh.status = 0
		else
			local m = parse_umask(pos[1], cur)
			if m == nil then
				io.stderr:write("curse: umask: `" .. pos[1] .. "': invalid symbolic mode\n")
				sh.status = 1
			else
				C.umask(m)
				sh.status = 0
			end
		end
	end
end
