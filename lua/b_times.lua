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
	if cmd == "times" then
		local a2 = args[2] -- (bash's no_options: no option letters, `--help` is help)
		if a2 == "--help" then
			return rt.builtin_help(sh, "times")
		elseif a2 and a2 ~= "--" and a2:match("^%-.") then
			return rt.bad_option(sh, "times", a2:sub(1, 2))
		end
		-- Two lines: shell user/sys, then children user/sys, each `%dm%.3fs`.
		local function ct(s)
			return ("%dm%.3fs"):format(math.floor(s / 60), s % 60)
		end
		local c = os.clock()
		sh:echo(ct(c) .. " " .. ct(0))
		sh:echo(ct(0) .. " " .. ct(0))
		sh.status = 0
	end
end
