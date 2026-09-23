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
local exec_list = I.exec_list

return function(sh, cmd, args, hook, tcb)
	if cmd == "eval" then
		-- eval [--]: join args, parse, run in the CURRENT shell (return/exit propagate).
		if args[2] and args[2] ~= "-" and args[2] ~= "--" and args[2]:sub(1, 1) == "-" then
			io.stderr:write("curse: eval: " .. args[2]:sub(1, 2) .. ": invalid option\n" .. rt.usage("eval"))
			sh.status = 2
		else
			local start = (args[2] == "--") and 3 or 2
			local code = table.concat({ unpack(args, start) }, " ")
			if code:match("%S") then
				-- Parse+run in the CURRENT shell, LAZILY (like the shell's own input) so an
				-- alias defined by one statement expands in the next; a syntax error stops
				-- at that point after the valid prefix has run (bash), and return/exit/
				-- break/continue propagate out. Alias expansion sees the live table (sh).
				local sxd = sh.xdepth -- (eval'd commands trace one level deeper: `++ cmd`, bash)
				sh.xdepth = (sxd or 0) + 1
				local ok, err = pcall(function()
					local ln = rt.current_line(sh)
					local nextf = P.open(code, sh, ln > 0 and ln or nil)
					local vst = {}
					while true do
						local lg = nextf()
						if lg == nil then
							require("interp").v_echo(sh, code, nil, vst)
							break
						end
						if sh.opt_v and lg.pline then
							require("interp").v_echo(sh, code, lg.pline - (ln > 0 and ln or 1) + 1, vst)
						end
						if lg.perr then -- syntax error on the line: run nothing on it (bash), status 2
							-- (reported as the shell's own syntax errors are, labelled `eval:`)
							sh.perr_label = "eval"
							local pok, perr = pcall(require("interp").exec_stmt, sh, lg.perr, hook)
							sh.perr_label = nil
							if not pok and not (type(perr) == "table" and perr.__curse_parseerr) then
								error(perr)
							end
							sh.status = 2
							return
						end
						for _, st in ipairs(lg.stmts) do
							local sok, serr = pcall(exec_list, sh, { st }, hook, false) -- errexit + signals incl.
							if not sok then
								if type(serr) == "table" and serr.__curse_lineabort then
									if sh.opt_e then
										error(serr)
									end
									sh.status = 1
									break -- div0/failglob: abort the rest of this line
								else
									error(serr)
								end
							end
						end
					end
				end)
				sh.xdepth = sxd
				if not ok then
					error(err)
				end -- control-flow (exit/return/…) or a real error
			else
				sh.status = 0
			end
		end
	end
end
