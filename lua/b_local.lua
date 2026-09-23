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
		-- local [-naA] [+n] NAME[=val]…: shadow the var in this scope, honoring
		-- nameref (-n), indexed (-a) and associative (-A) attributes.
		local nref, assoc, plusn, rest, lok = false, false, false, {}, true
		local iattr, lattr, uattr, aattr, rattr = false, false, false, false, false
		local inherit = false
		for j = 2, #args do
			local a = args[j]
			if a == "--" then
			elseif a == "-" then
				-- `local -`: the set options become local to this call (restored by popCall)
				sh.local_opts = sh.local_opts or {}
				if not sh.local_opts[sh.pd] then
					local snap = {}
					for _, f in ipairs(rt.opt_fields()) do
						snap[f] = { v = sh[f] } -- (exact: nil means "the default")
					end
					sh.local_opts[sh.pd] = snap
				end
			elseif a:sub(1, 1) == "-" and #a > 1 then
				if a:find("n") then
					nref = true
				end
				if a:find("A") then
					assoc = true
				end
				if a:find("a") then
					aattr = true
				end
				if a:find("i") then
					iattr = true
				end
				if a:find("l") then
					lattr = true
				end
				if a:find("u") then
					uattr = true
				end
				if a:find("r") then
					rattr = true
				end
				if a:find("I") then
					inherit = true -- (-I: the local starts as a copy of the outer var)
				end
			elseif a:sub(1, 1) == "+" and #a > 1 then
				if a:find("n") then
					plusn = true
				end
			else
				rest[#rest + 1] = a
			end
		end
		local attrs = nref or assoc or plusn or iattr or lattr or uattr or aattr or rattr
		if #rest == 0 and not attrs then
			-- bare `local` / `local -p`: list this frame's local variables (bash format)
			local saved, names = sh.savedstack[sh.pd], {}
			if saved then
				for nm in pairs(saved) do
					names[#names + 1] = nm
				end
			end
			table.sort(names)
			for _, nm in ipairs(names) do
				local d = fmt_decl(sh, nm)
				if d then
					sh:echo(d)
				end
			end
			sh.status = 0
			return
		end
		sh.local_inherit = inherit or nil -- (read by Shell:localVar; cleared below)
		if not attrs then
			for _, a in ipairs(rest) do
				local anm, sub, aop, aval = a:match("^([%a_][%w_]*)%[(.-)%](%+?=)(.*)$")
				if anm then -- local a[i]=v : create the element in a local array
					sh:localVar(anm)
					sh:array_set(anm, array_key(sh, anm, sub), aval, aop == "+=")
				elseif not (a:match("^[%a_][%w_]*$") or a:match("^[%a_][%w_]*%+?=") or a:find("[", 1, true)) then
					io.stderr:write("curse: local: `" .. a .. "': not a valid identifier\n")
					lok = false
				elseif
					(function()
						local ln = a:match("^([%a_][%w_]*)")
						return ln and sh:is_global_ro(sh:deref(ln))
					end)()
				then
					-- a readonly var can't be localized (bash errors, skips it, continues)
					io.stderr:write("curse: local: " .. a:match("^([%a_][%w_]*)") .. ": readonly variable\n")
					lok = false
				else
					sh:localAssign(a)
					if sh.opt_a then
						local nm = a:match("^([%a_][%w_]*)")
						local b = nm and sh.vars[sh:deref(nm)]
						if b and not b.arr then
							b.exported = true
							C.setenv(nm, sh:get(nm), 1)
						end
					end
				end
			end
		else
			for _, a in ipairs(rest) do
				local nm, ap, val = a:match("^([%a_][%w_]*)(%+?)=(.*)$")
				ap = ap == "+"
				local vname = nm or a
				sh:localVar(vname)
				if nref then
					if not sh:nameref_decl("local", nm or vname, val, true) then
						lok = false
					end
				elseif plusn then
					sh:unref(vname)
				else
					-- -A/-a/-i/-l/-u/-r (mirrors declare in a function): apply the value arith-evaluated
					-- for -i, case-folded for -l/-u, else the plain string; then any -r readonly mark.
					if assoc then
						sh:declare_assoc(vname)
					elseif aattr then
						local b = sh.vars[vname] or {}
						if not b.assoc then
							if b.s ~= nil and not b.arr then -- (an inherited scalar becomes [0])
								b.arr = { [0] = b.s }
								b.s, b.n = nil, nil
							end
							b.arr = b.arr or {}
						end
						sh.vars[vname] = b
					end
					if nm then
						if iattr then
							sh:aset(nm, M.arith_eval_str(sh, val))
							sh.vars[nm].int = true
						elseif lattr or uattr then
							sh:set_str(nm, lattr and val:lower() or val:upper())
							sh.vars[nm].lower = lattr or nil
							sh.vars[nm].upper = uattr or nil
						elseif aattr and not assoc then -- `local -a a=v` / `a+=v`: element 0
							sh:array_set(nm, 0, val, ap)
						elseif not (assoc or aattr) then -- (an existing array local takes it as [0])
							rt.assign_scalar(sh, nm, ap and (sh:get(nm) .. val) or val)
						end
					elseif iattr or lattr or uattr then
						local b = sh.vars[vname] or {}
						b.int = iattr or b.int
						b.lower = lattr or b.lower
						b.upper = uattr or b.upper
						sh.vars[vname] = b
					end
					if rattr then
						local b = sh.vars[sh:deref(vname)]
						if b then
							b.ro = true
						end
					end
				end
			end
		end
		sh.local_inherit = nil
		sh.status = lok and 0 or 1
	end
end
