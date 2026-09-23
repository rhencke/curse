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
		local fmode, vmode = false, false -- -f: functions only; -v: vars only; neither: var then function
		sh.status = 0
		for j = 2, #args do
			local a = args[j]
			if a == "-f" then
				fmode = true
			elseif a == "-v" then
				vmode = true
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
			else
				local nm, sub = a:match("^([%a_][%w_]*)%[(.+)%]$")
				if nm then
					local eb = sh.vars[sh:deref(nm)]
					if eb and eb.arr then -- real indexed/assoc array: unset one element
						if not sh:array_unset(nm, array_key(sh, nm, sub)) then
							io.stderr:write("curse: unset: " .. a .. ": bad array subscript\n")
							sh.status = 1
						end
					elseif eb and array_key(sh, nm, sub) == 0 then
						a = nm
						nm = nil -- `name[0]` on a scalar unsets the whole variable
					elseif eb then -- non-array with a non-zero subscript (bash: "not an array")
						io.stderr:write("curse: unset: " .. a .. ": not an array\n")
						sh.status = 1
					end
					-- eb == nil: `name[sub]` with no such variable is a no-op (status 0)
				end
				if nm == nil then
					local dn = sh:deref(a)
					if dn == "RANDOM" then
						sh.random_plain = true -- (unset RANDOM loses its special meaning — bash)
					end
					local b = sh.vars[dn]
					if b and b.ro then -- readonly: cannot unset (bash: status 1, keep it)
						io.stderr:write("curse: unset: " .. a .. ": cannot unset: readonly variable\n")
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
							C.unsetenv(a)
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
		end
	end
end
