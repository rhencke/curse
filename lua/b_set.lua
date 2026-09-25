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
local opt_on, set_opt, SETFLAG, SETOPT = I.opt_on, I.set_opt, I.SETFLAG, I.SETOPT

-- `set -o` (aligned on/off) or `set +o` (reproducible `set ±o NAME`): list_minus_o_opts
local function list_o(sh, plus)
	for _, ent in ipairs(SETOPTS) do
		if plus then
			sh.out(("set %so %s\n"):format(opt_on(sh, ent[2]) and "-" or "+", ent[1]))
		else
			sh.out(("%-15s\t%s\n"):format(ent[1], opt_on(sh, ent[2]) and "on" or "off"))
		end
	end
end

local USAGE = "set: usage: set [-abefhkmnptuvxBCEHPT] [-o option-name] [--] [-] [arg ...]\n"

return function(sh, cmd, args, hook, tcb)
	if cmd == "set" then
		-- set [-e|+e|-o NAME|+o NAME|…] [--] [ARGS…]: options then positional params
		if #args == 1 then -- bare `set` (and bare `declare`): all shell variables, sorted by
			-- name, then — outside posix mode — every function's definition (bash's set_builtin)
			local names, virt = {}, {}
			for nm in pairs(sh.vars) do
				names[#names + 1] = nm
			end
			-- SHELLOPTS / BASHOPTS are derived live (not stored) but are listed
			for _, nm in ipairs({ "SHELLOPTS", "BASHOPTS" }) do
				if sh.vars[nm] == nil then
					virt[nm] = { s = sh:get(nm) }
					names[#names + 1] = nm
				end
			end
			table.sort(names)
			for _, nm in ipairs(names) do
				local b = sh.vars[nm] or virt[nm]
				-- (a declared-but-never-assigned array isn't listed either)
				if b and not (b.s == nil and b.n == nil and b.arr == nil) and not (b.empty_decl and b.arr and next(b.arr) == nil) then
					sh.out(fmt_set_var(nm, b) .. "\n")
				end
			end
			-- then the functions, outside posix mode (print_all_shell_variables)
			if not sh.opt_posix then
				names = {}
				for nm in pairs(sh.functions) do
					names[#names + 1] = nm
				end
				table.sort(names)
				for _, nm in ipairs(names) do
					local d = I.func_body_text(sh, nm)
					if d then
						sh.out(d .. "\n")
					end
				end
			end
			sh.status = 0
			if sh.out == io.write then
				rt.chkwrite(sh, "set") -- (sh_chkwrite: a closed stdout is status 1)
			end
			return
		end
		-- bash validates every flag argument first (internal_getopt over "+abefhikmnprtuvx
		-- BCEHPTo;"), so one bad letter anywhere applies none of them. `o` takes the rest
		-- of its word or a following non-option word as its (unchecked) name.
		local j = 2
		while j <= #args do
			local a = args[j]
			local c1 = a:sub(1, 1)
			if (c1 ~= "-" and c1 ~= "+") or #a == 1 or a == "--" then
				break
			elseif a == "--help" then
				return rt.builtin_help(sh, "set")
			end
			local nxt = j + 1
			for k = 2, #a do
				local f = a:sub(k, k)
				if f == "o" then
					if k == #a then
						local w = args[j + 1]
						if w and not ((w:sub(1, 1) == "-" or w:sub(1, 1) == "+") and #w > 1) then
							nxt = j + 2
						end
					end
					break
				elseif f == "i" or not SETFLAG[f] then
					-- `set -?` prints the usage but succeeds (list_optopt == '?')
					io.stderr:write("curse: set: " .. c1 .. f .. ": invalid option\n" .. USAGE)
					sh.status = f == "?" and 0 or 2
					return
				end
			end
			j = nxt
		end
		-- then the flags apply, left to right (set_builtin's second loop)
		local status = 0
		local force = false -- only `--` replaces the params even when none follow
		j = 2
		while j <= #args do
			local a = args[j]
			local on = a:sub(1, 1)
			if on == "-" and (#a == 1 or a == "--") then
				j = j + 1
				if a == "--" then
					force = true
				else -- bare `-`: turn off -v/-x and stop option processing (obsolescent)
					set_opt(sh, "opt_v", false)
					set_opt(sh, "opt_x", false)
				end
				break
			elseif on ~= "-" and on ~= "+" then
				break
			end
			on = on == "-"
			for k = 2, #a do
				local f = a:sub(k, k)
				if f == "o" then
					local o = args[j + 1]
					local o1 = o and o:sub(1, 1)
					if o == nil or o == "" or o1 == "-" or o1 == "+" then
						-- no name (or a flag-like word, left in place): list, and carry on
						list_o(sh, not on)
						if o == nil and sh.out == io.write and not rt.chkwrite(sh, "set") then
							status = 1
						end
					else
						j = j + 1 -- (the name is consumed)
						if not SETOPT[o] then
							io.stderr:write("curse: set: " .. o .. ": invalid option name\n")
							sh.status = 2
							return
						end
						set_opt(sh, SETOPT[o], on)
					end
				elseif f == "r" then
					-- a restricted shell can't be unrestricted (change_flag's FLAG_ERROR)
					if not on and sh.opt_r then
						io.stderr:write("curse: set: +r: invalid option\n" .. USAGE)
						sh.status = 1
						return
					elseif on and not sh.opt_r then
						rt.make_restricted(sh)
					end
				else
					set_opt(sh, SETFLAG[f], on)
				end
			end
			j = j + 1
		end
		if force or j <= #args then
			local np, n = {}, 0
			for k = j, #args do
				n = n + 1
				np[n] = args[k]
			end
			sh.params = np
			sh.nparams = n
		end
		sh.status = status
	end
end
