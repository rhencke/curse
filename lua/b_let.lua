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
	if cmd == "let" then
		-- let EXPR…: evaluate each as arithmetic (assignments take effect). Status is
		-- 0 if the LAST expression is non-zero, else 1; a bad/empty expression or no
		-- args is also status 1 (an arith error is non-fatal, like `(( ))`).
		if args[2] == "--" then -- (a leading `--` is skipped: ISOPTION)
			table.remove(args, 2)
		end
		if #args < 2 then
			io.stderr:write("curse: let: expression expected\n")
			sh.status = 1
		else
			local last, failed = 0, false
			local sv, sl = P.arith_cmd, sh.arith_let
			P.arith_cmd = "let" -- (bash's this_command_name in the error text)
			sh.arith_let = true -- (its text is already expanded: see arith_key)
			for k = 2, #args do
				local ok, v = pcall(function()
					local pok, ast = pcall(P.arith, args[k], "let") -- (args are already expanded)
					if not pok then
						I.arith_pre(sh, ast) -- (what bash evaluated before the error sticks)
						io.stderr:write("curse: " .. P.arith_errmsg(args[k], ast) .. "\n")
						error({ __curse_exit = 1, __curse_matherr = true })
					end
					return eval(sh, ast)
				end)
				if not ok then
					if not (type(v) == "table" and v.__curse_matherr) then
						P.arith_cmd, sh.arith_let = sv, sl
						error(v)
					end
					failed = true -- an arith error ends let (status 1), like bash's longjmp
					break
				end
				last = tonumber(rt.i64_to_str(v)) or 0
			end
			P.arith_cmd, sh.arith_let = sv, sl
			sh.status = (not failed and last ~= 0) and 0 or 1
		end
	end
end
