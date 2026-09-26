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

-- Parsed single-line eval strings (a loop's `eval "$x=…"` re-parses the same text
-- every pass). Keyed on everything the parse depends on: text, line, extglob,
-- posix; skipped while aliases are live (the parse would depend on the table) and
-- for heredocs (the parse may warn). Values: the list of line groups.
local eval_cache, eval_n = {}, 0
local function eval_groups(sh, code, ln)
	if code:find("\n", 1, true) or code:find("<<", 1, true) or #code > 2048
		or (sh.shopt and sh.shopt.expand_aliases and sh.aliases and next(sh.aliases)) then
		return nil
	end
	local key = code .. "\0" .. ln .. (sh.shopt and sh.shopt.extglob and "x" or "-") .. (sh.opt_posix and "p" or "-")
	local lgs = eval_cache[key]
	if not lgs then
		lgs = {}
		local nextf = P.open(code, sh, ln > 0 and ln or nil)
		while true do
			local lg = nextf()
			if lg == nil then
				break
			end
			lgs[#lgs + 1] = lg
		end
		if eval_n >= 256 then
			eval_cache, eval_n = {}, 0
		end
		eval_cache[key], eval_n = lgs, eval_n + 1
	end
	local i = 0
	return function()
		i = i + 1
		return lgs[i]
	end
end

return function(sh, cmd, args, hook, tcb)
	if cmd == "eval" then
		sh.shlvl_tail = nil -- (a builtin: the code it runs isn't exec'd in place)
		-- eval [--]: join args, parse, run in the CURRENT shell (return/exit propagate).
		if args[2] == "--help" then -- (CASE_HELPOPT: the builtin's help, status 2)
			return rt.builtin_help(sh, "eval")
		elseif args[2] and args[2] ~= "-" and args[2] ~= "--" and args[2]:sub(1, 1) == "-" then
			io.stderr:write("curse: eval: " .. args[2]:sub(1, 2) .. ": invalid option\n" .. rt.usage("eval"))
			sh.status = 2
			sh.spb_err = 2 -- (EX_USAGE: rt.spb_run)
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
				local badsyntax -- (EX_BADSYNTAX: like EX_USAGE from a special builtin — rt.spb_run)
				local ran = false -- (a command ran before the error: not fatal — rt.perr_lead)
				-- (parse_and_execute's restore_lastcom: after the code, $BASH_COMMAND is the eval
				-- again — an ERR trap the eval's failure fires reads `eval …`)
				local scc = sh.cur_cmd
				-- (run errexit-exempt — an `if`/`&&`/`!` context — eval clears -e for what it runs:
				-- execute_builtin's exit_immediately_on_error = 0, so a report_error doesn't exit)
				local iee = sh.ign_ee
				sh.ign_ee = iee or sh.noerr > 0
				local ok, err = pcall(function()
					local ln = rt.current_line(sh)
					local nextf = eval_groups(sh, code, ln) or P.open(code, sh, ln > 0 and ln or nil)
					local vst = {}
					while true do
						local lg = nextf()
						if lg == nil then
							require("interp").v_echo(sh, code, nil, vst)
							break
						end
						if sh.jobs_waited then -- (reading a line: notify_and_cleanup — rt.job_waited)
							rt.jobs_cleanup_waited(sh)
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
							if not lg.perr.recoverable then
								sh.status = lg.perr.status or 2
								badsyntax = not ran
								return
							end -- (a recoverable one dropped its line: the eval goes on, status 1)
						end
						for _, st in ipairs(lg.stmts) do
							ran = ran or not rt.perr_neutral(st)
							local ne0 = sh.noerr
							local sok, serr = pcall(exec_list, sh, { st }, hook, false) -- errexit + signals incl.
							if not sok then
								if type(serr) == "table" and serr.__curse_lineabort and not serr.__curse_discard then
									if rt.lineabort_exits(sh, serr) then
										error(serr)
									end
									sh.status, sh.noerr = 1, ne0
									break -- div0/failglob: abort the rest of this line
								else
									error(serr)
								end
							end
						end
					end
				end)
				sh.xdepth, sh.cur_cmd, sh.ign_ee = sxd, scc, iee
				sh.spb_err = badsyntax and 2 or nil -- (a builtin the code ran flagged its own: not eval's)
				if not ok then
					error(err)
				end -- control-flow (exit/return/…) or a real error
			else
				sh.status = 0
			end
		end
	end
end
