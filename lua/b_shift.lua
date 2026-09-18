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
	if cmd == "shift" then
		if args[3] ~= nil or (args[2] and not tonumber(args[2])) then -- too many / non-numeric args
			io.stderr:write(
				"curse: shift: "
					.. (args[3] ~= nil and "too many arguments" or (args[2] .. ": numeric argument required"))
					.. "\n"
			)
			sh.status = 1
			if sh.opt_c then
				error({ __curse_exit = 1 })
			end
		else
			local nn = tonumber(args[2]) or 1
			if nn < 0 or nn > sh.nparams then
				sh.status = 1 -- out of range: no-op, status 1 (bash)
			else
				for k = 1, sh.nparams - nn do
					sh.params[k] = sh.params[k + nn]
				end
				for k = sh.nparams - nn + 1, sh.nparams do
					sh.params[k] = nil
				end
				sh.nparams = sh.nparams - nn
				sh.status = 0
			end
		end
	end
end
