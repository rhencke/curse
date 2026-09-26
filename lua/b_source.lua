-- Lazily-loaded builtin feature module (see BUILTIN_LAZY in interp.lua). Its own
-- module -- no grab bags -- so a script loads only the builtin it uses. Internals
-- it needs are aliased from interp's _int under their interp names.
local rt = require("runtime")
local M = require("interp")
local I = M._int
local file_test = I.file_test
local P = I.P
local exec_list = I.exec_list
local run_trap = I.run_trap

return function(sh, cmd, args, hook, tcb)
	if cmd == "source" or cmd == "." then
		sh.shlvl_tail = nil -- (a builtin: the code it runs isn't exec'd in place)
		-- source FILE [args]: run FILE in the current shell; a `return` ends the file.
		-- A name with no slash is looked up in $PATH (files only, dirs skipped), then
		-- falls back to the bare name; `--` ends options.
		local j = 2
		local usage = cmd .. ": usage: " .. cmd .. " filename [arguments]\n"
		if args[j] == "--" then
			j = j + 1
		elseif args[j] == "--help" then -- (no_options: the builtin's help, status 2)
			return rt.builtin_help(sh, cmd)
		elseif args[j] and args[j]:match("^%-.") then -- (bash's no_options: no option letters)
			io.stderr:write("curse: " .. cmd .. ": " .. args[j]:sub(1, 2) .. ": invalid option\n" .. usage)
			sh.status = 2
			sh.spb_err = 2 -- (EX_USAGE: rt.spb_run)
			return
		end
		local name = args[j]
		if name and name:find("/", 1, true) and rt.restricted(sh, cmd .. ": " .. name .. ": restricted") then
			return
		end
		local file = name and rt.source_path(sh, name)
		-- `.`/source fires the RETURN trap when it returns — for EVERY outcome except
		-- the no-argument usage error (directory/not-found/syntax-error/success all
		-- fire), regardless of functrace; an `exit` in the file propagates and skips it.
		local do_return = name ~= nil
		local dsave -- (the DEBUG trap, hidden while the file runs: rt.source_debug_hide)
		local e0 = sh.traps and sh.traps.ERR -- (the ERR trap before it: rt.source_err_sample)
		local rret -- (a `return N` ending the file: $? once the RETURN trap has run)
		if not name then
			io.stderr:write("curse: " .. cmd .. ": filename argument required\n" .. usage)
			sh.status = 2
			sh.spb_err = 2 -- (EX_USAGE: rt.spb_run)
		elseif file_test("-d", file) then
			io.stderr:write("curse: " .. cmd .. ": " .. name .. ": is a directory\n")
			sh.status = 1
		else
			local pre = sh.source_preread -- (the compiled tier's rt.source already read it)
			sh.source_preread = nil
			local f = pre and pre.file == file and { read = function() return pre.code end, close = function() end }
				or rt.open_read(file)
			if not f then -- (bash names just the file; in posix mode it's fatal — a special
				-- builtin, unless run through `command` — and a $PATH miss is "file not found")
				if sh.opt_posix and not name:find("/", 1, true) then
					io.stderr:write("curse: " .. cmd .. ": " .. name .. ": file not found\n")
				else
					io.stderr:write("curse: " .. name .. ": No such file or directory\n")
				end
				sh.status = 1
				if sh.opt_posix and not sh.opt_i and not sh.via_command then
					error({ __curse_exit = 1 })
				end
			else
				local src = f:read("*a")
				f:close()
				if not pre then -- (rt.source noted it already)
					require("tier").note_text(sh, src) -- (what it reads joins the program's)
				end
				do
					local savep, savenp = sh.params, sh.nparams
					if #args > j then
						sh.params, sh.nparams = {}, 0
						for k = j + 1, #args do
							sh.nparams = sh.nparams + 1
							sh.params[sh.nparams] = args[k]
						end
					end
					local ownp = sh.params -- (a `set --` in the file replaces this table)
					sh.sourcedepth = (sh.sourcedepth or 0) + 1 -- a `return` is valid while sourcing
					local sframe = rt.source_enter(sh, file, nil, args, j) -- (BASH_SOURCE/BASH_LINENO/FUNCNAME frame:
					-- the file as found — `dir/NAME` for a $PATH hit)
					dsave = rt.source_debug_hide(sh)
					-- Run the file the way the shell runs its own input: LAZILY through the
					-- sh-aware parser, so aliases defined earlier expand later and a `return`
					-- ends the file. A syntax error stops after the valid prefix (bash),
					-- reported as status 2 without halting the shell.
					local sxd = sh.xdepth -- (a sourced file traces one level deeper, bash)
					sh.xdepth = (sxd or 0) + 1
					local scc = sh.cur_cmd -- (parse_and_execute's restore_lastcom: $BASH_COMMAND)
					local iee = sh.ign_ee -- (errexit-exempt: -e cleared for the file, as eval does)
					sh.ign_ee = iee or sh.noerr > 0
					local rok, err = pcall(function()
						local nextf = P.open(src, sh)
						local vst = {}
						local ran = false -- (a command ran before a syntax error: not fatal — rt.perr_lead)
						while true do
							local lg = nextf()
							if lg == nil then
								M.v_echo(sh, src, nil, vst)
								break
							end
							if sh.jobs_waited then -- (reading a line: notify_and_cleanup — rt.job_waited)
								rt.jobs_cleanup_waited(sh)
							end
							if sh.opt_v and lg.pline then
								M.v_echo(sh, src, lg.pline, vst)
							end
							if lg.perr then -- syntax error: reported (bash's message), source returns 2
								if lg.perr.recoverable then
									M.report_recoverable(sh, lg.perr)
								else
									local _, pe = pcall(I.exec_stmt, sh, lg.perr, hook) -- (it would exit: the file just ends)
									if type(pe) == "table" and pe.__curse_perrexit then
										error(pe, 0) -- (but `set -e`'s parser_error exit stands)
									end
									error({ __curse_parseerr = true, lead = not ran, __curse_exit = lg.perr.status })
								end
							end
							for _, st in ipairs(lg.stmts) do
								ran = ran or not rt.perr_neutral(st)
								local ne0 = sh.noerr
								local sok, serr = pcall(exec_list, sh, { st }, hook, false)
								if not sok then
									if type(serr) == "table" and serr.__curse_lineabort and not serr.__curse_discard then
										if rt.lineabort_exits(sh, serr) then
											error(serr)
										end
										sh.status, sh.noerr = 1, ne0
										break
									else
										error(serr)
									end
								end
							end
						end
					end)
					sh.xdepth, sh.ign_ee = sxd, iee
					sh.spb_err = nil -- (a builtin in the file flagged its own: not the source's)
					sh.cur_cmd = scc
					sh.sourcedepth = sh.sourcedepth - 1
					rt.source_leave(sh, sframe)
					-- (params the file SET itself stay — but not in a function: maybe_pop_dollar_vars)
					if #args > j and (sh.params == ownp or sh:in_function()) then
						sh.params, sh.nparams = savep, savenp
					end
					if rok and rt.source_empty(src) then
						sh.status = 0 -- (a file with no commands)
					end
					if not rok then
						if type(err) == "table" and err.__curse_return then
							rret = err.__curse_return
						elseif type(err) == "table" and err.__curse_parseerr then
							sh.status = err.__curse_exit or 2 -- a syntax error in the file: source returns 2, doesn't halt the shell (bash)
							sh.spb_err = err.lead and 2 or nil -- (EX_BADSYNTAX halts a posix one: rt.perr_lead)
						else
							rt.source_debug_restore(sh, dsave)
							error(err)
						end -- a real `exit` propagates (skips the RETURN trap)
					end
				end
			end
		end
		if do_return then
			local rh = sh.traps and sh.traps.RETURN
			if rh and rh ~= "" and not sh.in_return_trap and rt.pseudo_trapped(sh, "RETURN") then
				sh.in_return_trap = true
				local sv = sh.status
				run_trap(sh, rh)
				sh.status = sv
				sh.in_return_trap = false
			end
		end
		if rret then
			sh.status = rret
		end
		rt.source_debug_restore(sh, dsave)
		rt.source_err_sample(sh, e0)
	end
end
