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
	if cmd == "local" then
		if args[2] == "--help" then -- (CASE_HELPOPT: before the function check, status 2)
			require("b_help")(sh, "help", { "help", "local" }, hook, tcb)
			sh.status = 2
			return
		end
		if sh.pd == 0 and (sh.calldepth or 0) == 0 then -- (no function: checked before anything)
			io.stderr:write("curse: local: can only be used in a function\n")
			sh.status = 1
			return
		end
		-- local is bash's declare_internal(list, local_var=1): the same options as declare,
		-- every operand made local. Validate the options, handle -f/-F, the listing, -p and
		-- `local -` here; a plain `local NAME[=value]…` takes the localAssign fast path, and
		-- anything with an attribute goes through declare's code (b_export) as `local`.
		local attrs, pflag, inherit, dash, rest = false, false, false, false, {}
		local endopts = false
		for j = 2, #args do -- (bash's option pass first: a bad letter rejects the lot)
			local a = args[j]
			if endopts or a == "--" or not a:match("^[-+].") then
				break
			end
			local bad = a:match("[^aAcfFgGiIlnprtux]", 2)
			if bad then
				io.stderr:write("curse: local: " .. a:sub(1, 1) .. bad .. ": invalid option\n")
				io.stderr:write("local: usage: local [option] name[=value] ...\n")
				sh.status = 2
				return
			end
			if a:find("[fF]") and a:sub(1, 1) == "-" then -- (functions: never made, only looked up)
				local st = 0
				for k = j + 1, #args do
					if args[k]:find("=", 1, true) then
						io.stderr:write("curse: local: cannot use `-f' to make functions\n")
						st = 1
						break
					elseif not sh.functions[args[k]] then
						st = 1
					end
				end
				sh.status = st
				return
			end
		end
		for j = 2, #args do
			local a = args[j]
			if endopts then
				rest[#rest + 1] = a
			elseif a == "--" then
				endopts = true
			elseif a:match("^[-+].") then
				if a:find("p") then -- (+p too: bash's pflag++ ignores the sign)
					pflag = true
				end
				if a:find("I") and a:sub(1, 1) == "-" then
					inherit = true -- (-I: the local starts as a copy of the outer var)
				end
				if a:find("[aAcgGilnrtux]") then
					attrs = true
				end
				endopts = false
			else
				endopts = true -- (the first operand ends the options)
				rest[#rest + 1] = a
			end
			dash = dash or (a == "-" and endopts)
		end
		local saved = sh.savedstack[sh.pd]
		local opts_local = sh.local_opts and sh.local_opts[sh.pd]
		if pflag and #rest > 0 then -- `local -p NAME…` (show_localname_attributes): this frame's
			local ok = true
			for _, nm in ipairs(rest) do
				local d
				if nm == "-" then
					d = opts_local and "declare -- -" -- (the local `-` variable, valueless)
				else
					d = saved and saved[nm] ~= nil and fmt_decl(sh, nm)
				end
				if d then
					sh:echo(d)
				else
					io.stderr:write("curse: local: " .. nm .. ": not found\n")
					ok = false
				end
			end
			sh.status = ok and 0 or 1
			return
		end
		if #rest == 0 then
			-- bare `local` / `local -p` / `local -i`: list this frame's local variables (bash
			-- format), a local `-` (set options) first as `local -`
			local names = {}
			if saved then
				for nm in pairs(saved) do
					names[#names + 1] = nm
				end
			end
			table.sort(names)
			if opts_local then
				sh:echo("local -")
			end
			for _, nm in ipairs(names) do
				local d = fmt_decl(sh, nm)
				if d then
					sh:echo(d)
				end
			end
			sh.status = 0
			return
		end
		if dash and not opts_local then
			-- `local -`: the set options become local to this call (restored by popCall)
			sh.local_opts = sh.local_opts or {}
			local snap = {}
			for _, f in ipairs(rt.opt_fields()) do
				snap[f] = { v = sh[f] } -- (exact: nil means "the default")
			end
			sh.local_opts[sh.pd] = snap
		end
		sh.local_inherit = inherit or nil -- (read by Shell:localVar; cleared below)
		if attrs then
			local dargs = {}
			for j = 1, #args do
				if args[j] ~= "-" then
					dargs[#dargs + 1] = args[j]
				end
			end
			local ok, err = pcall(require("b_export"), sh, "local", dargs, hook, tcb)
			sh.local_inherit = nil
			if not ok then
				error(err, 0)
			end
			return
		end
		local lok = true
		for _, a in ipairs(rest) do
			local anm, sub, aop, aval = a:match("^([%a_][%w_]*)%[(.-)%](%+?=)(.*)$")
			if a == "-" then
			elseif anm then -- local a[i]=v : create the element in a local array
				sh:localVar(anm)
				sh:array_set(anm, array_key(sh, anm, sub), aval, aop == "+=")
			elseif not (a:match("^[%a_][%w_]*$") or a:match("^[%a_][%w_]*%+?=") or a:find("[", 1, true)) then
				io.stderr:write("curse: local: `" .. a .. "': not a valid identifier\n")
				lok = false
				sh.badassign = true -- (EX_BADASSIGN: see rt stage_body)
			elseif not sh:localAssign(a, "local") then
				lok = false -- (a readonly var can't be localized: bash errors, skips it, continues)
			end
		end
		sh.local_inherit = nil
		sh.status = lok and 0 or 1
	end
end
