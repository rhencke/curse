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
local run_trap = I.run_trap

return function(sh, cmd, args, hook, tcb)
	if cmd == "source" or cmd == "." then
		-- source FILE [args]: run FILE in the current shell; a `return` ends the file.
		-- A name with no slash is looked up in $PATH (files only, dirs skipped), then
		-- falls back to the bare name; `--` ends options.
		local j = 2
		local usage = cmd .. ": usage: " .. cmd .. " filename [arguments]\n"
		if args[j] == "--" then
			j = j + 1
		elseif args[j] and args[j]:match("^%-.") then -- (bash's no_options: no option letters)
			io.stderr:write("curse: " .. cmd .. ": " .. args[j]:sub(1, 2) .. ": invalid option\n" .. usage)
			sh.status = 2
			return
		end
		local name = args[j]
		if name and name:find("/", 1, true) and rt.restricted(sh, cmd .. ": " .. name .. ": restricted") then
			return
		end
		local file = name
		if name and not name:find("/", 1, true) then
			for dir in (sh:get("PATH") .. ":"):gmatch("([^:]*):") do
				local cand = (dir == "" and "." or dir) .. "/" .. name
				if file_test("-f", cand) then
					file = cand
					break
				end
			end
		end
		-- `.`/source fires the RETURN trap when it returns — for EVERY outcome except
		-- the no-argument usage error (directory/not-found/syntax-error/success all
		-- fire), regardless of functrace; an `exit` in the file propagates and skips it.
		local do_return = name ~= nil
		local dsave -- (the DEBUG trap, hidden while the file runs: rt.source_debug_hide)
		if not name then
			io.stderr:write("curse: " .. cmd .. ": filename argument required\n" .. usage)
			sh.status = 2
		elseif file_test("-d", file) then
			io.stderr:write("curse: " .. cmd .. ": " .. name .. ": is a directory\n")
			sh.status = 1
		else
			local pre = sh.source_preread -- (the compiled tier's rt.source already read it)
			sh.source_preread = nil
			local f = pre and pre.file == file and { read = function() return pre.code end, close = function() end }
				or io.open(file, "r")
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
					local sframe = rt.source_enter(sh, name) -- (BASH_SOURCE/BASH_LINENO/FUNCNAME frame)
					dsave = rt.source_debug_hide(sh)
					-- Run the file the way the shell runs its own input: LAZILY through the
					-- sh-aware parser, so aliases defined earlier expand later and a `return`
					-- ends the file. A syntax error stops after the valid prefix (bash),
					-- reported as status 2 without halting the shell.
					local sxd = sh.xdepth -- (a sourced file traces one level deeper, bash)
					sh.xdepth = (sxd or 0) + 1
					local rok, err = pcall(function()
						local nextf = P.open(src, sh)
						while true do
							local lg = nextf()
							if lg == nil then
								break
							end
							if lg.perr then
								error({ __curse_parseerr = true })
							end -- syntax error: source returns 2
							for _, st in ipairs(lg.stmts) do
								local sok, serr = pcall(exec_list, sh, { st }, hook, false)
								if not sok then
									if type(serr) == "table" and serr.__curse_lineabort then
										if sh.opt_e then
											error(serr)
										end
										sh.status = 1
										break
									else
										error(serr)
									end
								end
							end
						end
					end)
					sh.xdepth = sxd
					sh.sourcedepth = sh.sourcedepth - 1
					rt.source_leave(sh, sframe)
					if #args > j and sh.params == ownp then -- (params the file SET itself stay: bash)
						sh.params, sh.nparams = savep, savenp
					end
					if not rok then
						if type(err) == "table" and err.__curse_return then
							sh.status = err.__curse_return
						elseif type(err) == "table" and err.__curse_parseerr then
							sh.status = 2 -- a syntax error in the file: source returns 2, doesn't halt the shell (bash)
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
			if rh and rh ~= "" and not sh.in_return_trap then
				sh.in_return_trap = true
				local sv = sh.status
				run_trap(sh, rh)
				sh.status = sv
				sh.in_return_trap = false
			end
		end
		rt.source_debug_restore(sh, dsave)
	end
end
