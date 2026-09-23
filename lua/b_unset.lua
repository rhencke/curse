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
	if cmd == "unset" then
		local fmode, vmode, nmode = false, false, false -- -f: functions only; -v: vars only; neither: var then function
		-- -n: a nameref ITSELF, not its target
		sh.status = 0
		-- (the leading options first, as bash's internal_getopt reads them)
		for j = 2, #args do
			local a = args[j]
			if a == "--" or a:sub(1, 1) ~= "-" or a == "-" then
				break
			end
			for k = 2, #a do
				local f = a:sub(k, k)
				if f == "f" then
					fmode = true
				elseif f == "v" then
					vmode = true
				elseif f == "n" then
					nmode = true
				else
					io.stderr:write("curse: unset: -" .. f .. ": invalid option\n")
					io.stderr:write("unset: usage: unset [-f] [-v] [-n] [name ...]\n")
					sh.status = 2
					return
				end
			end
		end
		if fmode and vmode then
			io.stderr:write("curse: unset: cannot simultaneously unset a function and a variable\n")
			sh.status = 1
			return
		end
		for j = 2, #args do
			local a = args[j]
			if a == "-f" then
				fmode = true
			elseif a == "-v" then
				vmode = true
			elseif a == "-n" then
				nmode = true
			elseif a:sub(1, 1) == "-" and #a > 1 then -- other flags: ignore
			elseif fmode then
				if sh.fn_ro and sh.fn_ro[a] and sh.functions[a] then
					io.stderr:write("curse: unset: " .. a .. ": cannot unset: readonly function\n")
					sh.status = 1
				else
					sh.functions[a] = nil
					if sh.fexport and sh.fexport[a] then -- (it leaves the environment too)
						sh.fexport[a] = nil
						rt.fexport_sync(sh, a)
					end
				end
			elseif vmode and not rt.split_array_ref(a, sh) then -- `unset -v 'a b'` (bare unset
				-- quietly tries a function of that name instead)
				io.stderr:write("curse: unset: `" .. a .. "': not a valid identifier\n")
				sh.status = 1
			else
				local viaref
				if not nmode and a:match("^[%a_][%w_]*$") and sh.vars[a] and sh.vars[a].ref then
					viaref = sh:deref_elem(a) -- (a nameref to an ELEMENT unsets that element)
					a = viaref or a
				end
				local nm, sub = a:match("^([%a_][%w_]*)%[(.+)%]$")
				local function ukey() -- (the argument is expanded already: under
					-- assoc_expand_once an associative subscript isn't expanded again)
					if sh.shopt.assoc_expand_once and sh:is_assoc(nm) then
						return sub
					end
					return array_key(sh, nm, sub)
				end
				if nm then
					local eb = sh.vars[sh:deref(nm)]
					if (sub == "@" or sub == "*") and eb and eb.arr and (rt.compat_level(sh) <= 51 or not eb.assoc) then
						-- `unset a[@]`: bash 5.2 empties an indexed array (an assoc's `@` is a
						-- key); at compat 5.1 either is unset whole
						if rt.compat_level(sh) <= 51 then
							a, nm = nm, nil
						else
							eb.arr = {}
						end
					elseif eb and eb.arr then -- real indexed/assoc array: unset one element
						if not sh:array_unset(nm, ukey()) then
							io.stderr:write("curse: unset: [" .. sub .. "]: bad array subscript\n")
							sh.status = 1
						end
					elseif eb and array_key(sh, nm, sub) == 0 then
						a = nm
						nm = nil -- `name[0]` on a scalar unsets the whole variable
					elseif eb and not viaref then -- non-array, non-zero subscript (bash: "not an array")
						io.stderr:write("curse: unset: " .. nm .. ": not an array variable\n")
						sh.status = 1
					end
					-- eb == nil: `name[sub]` with no such variable is a no-op (status 0)
				end
				if nm == nil then
					local dn = nmode and a or sh:deref(a)
					if nmode and not (sh.vars[a] and sh.vars[a].ref) then
						goto next_arg -- `unset -n` leaves a variable that isn't a nameref alone (bash)
					end
					if dn == "RANDOM" then
						sh.random_plain = true -- (unset RANDOM loses its special meaning — bash)
					end
					local b = sh.vars[dn]
					if b and b.ro then -- readonly: cannot unset (bash: status 1, keep it)
						io.stderr:write("curse: unset: " .. dn .. ": cannot unset: readonly variable\n")
						sh.status = 1
					elseif b ~= nil or vmode then
						-- bash dynamic-scope unset: when the var is NOT local to the CURRENT
						-- frame but shadows a local declared in an ENCLOSING frame (e.g. an
						-- `unset -v` run from a nested `unlocal` helper), removing it REVEALS
						-- that outer binding instead of leaving the name unset.
						local revealed, env_done = false, false
						-- unset of a var LOCAL to the current frame just makes it appear unset
						-- (bash: the outer value stays hidden until the function returns). Only
						-- when the name is NOT local here does unset REVEAL a shadowed binding —
						-- and it peels the MOST RECENT layer, whether that's an enclosing `local`
						-- shadow (savedstack) or a tempenv `x=v cmd` binding (sh.tenv), ordered by
						-- a monotonic seq so interleaved local/tempenv layers unwind correctly.
						if not (sh.savedstack[sh.pd] and sh.savedstack[sh.pd][dn] ~= nil) then
							local best_seq, best_d, best_k = -1, nil, nil
							for d = (sh.pd or 0), 1, -1 do
								local ss = sh.savedstack[d]
								if ss and ss[dn] ~= nil and ss[dn].seq > best_seq then
									best_seq = ss[dn].seq
									best_d = d
									best_k = nil
								end
							end
							for k = #sh.tenv, 1, -1 do
								local e = sh.tenv[k]
								if not e.consumed and e.name == dn and e.seq > best_seq then
									best_seq = e.seq
									best_k = k
									best_d = nil
								end
							end
							if best_d then
								sh.vars[dn] = sh.savedstack[best_d][dn].box or nil -- false = was absent
								sh.savedstack[best_d][dn] = nil
								revealed = true
							elseif best_k then
								local e = sh.tenv[best_k]
								sh.vars[dn] = e.box or nil
								e.consumed = true
								revealed = true
								if e.env then
									C.setenv(dn, e.env, 1)
								else
									C.unsetenv(dn)
								end
								env_done = true
							end
						end
						local here = sh.savedstack[sh.pd] and sh.savedstack[sh.pd][dn] ~= nil
						if not revealed and here and b then
							-- a local of THIS call stays a (value-less) local, attributes kept:
							-- `local v=x; unset v; declare -p v` -> `declare -- v` (bash)
							sh.vars[dn] = { exported = b.exported, int = b.int, lower = b.lower,
								upper = b.upper, cap = b.cap }
							sh:env_resync(dn)
							env_done = true
						elseif not revealed then
							sh.vars[dn] = nil
						end
						if not env_done then
							C.unsetenv(dn)
						end -- drop from the process env too
						if rt.LOCALE_VARS[dn] then
							rt.reset_locale(sh)
						end -- re-apply locale (bash)
						if dn == "IGNOREEOF" then
							sh.opt_ignoreeof = false -- (sv_ignoreeof)
						end
						if dn == "POSIXLY_CORRECT" then
							sh.opt_posix = false -- (sv_strict_posix: unsetting it leaves posix mode)
						end
					elseif sh.functions[a] then
						sh.functions[a] = nil -- plain unset falls back to a function
						if sh.fexport and sh.fexport[a] then
							sh.fexport[a] = nil
							rt.fexport_sync(sh, a)
						end
					end
				end
			end
			::next_arg::
		end
	end
end
