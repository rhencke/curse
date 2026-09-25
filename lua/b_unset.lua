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
		-- the options lead (bash's internal_getopt): a later `-f`/`-v` is just a name
		local first = 2
		while first <= #args do
			local a = args[first]
			if a:sub(1, 1) ~= "-" or a == "-" then
				break
			elseif a == "--help" then
				return rt.builtin_help(sh, "unset")
			end
			first = first + 1
			if a == "--" then
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
					return rt.bad_option(sh, "unset", "-" .. f)
				end
			end
		end
		if fmode and vmode then
			io.stderr:write("curse: unset: cannot simultaneously unset a function and a variable\n")
			sh.status = 1
			return
		end
		-- (unset_builtin: a readonly function can't go; bash reports and moves on)
		local function unset_fn(a)
			if sh.fn_ro and sh.fn_ro[a] and sh.functions[a] then
				io.stderr:write("curse: unset: " .. a .. ": cannot unset: readonly function\n")
				sh.status = 1
			elseif sh.functions[a] then
				sh.functions[a] = nil
				if sh.fexport and sh.fexport[a] then -- (it leaves the environment too)
					sh.fexport[a] = nil
					rt.fexport_sync(sh, a)
				end
			end
		end
		for j = first, #args do
			local a = args[j]
			-- (bash's tokenize_array_reference: the subscript's `]` must end the word — a quoted
			-- "U[a]b]" is no variable, so without -v it names a function — except that an
			-- unquoted `A[…]` word's associative subscript runs to its final `]` (W_ARRAYREF))
			local isvar = rt.split_array_ref(a, sh) or (sh.arrayref_args and sh.arrayref_args[a]
				and a:find("^[%a_][%w_]*%[.+%]$") and sh:is_assoc(a:match("^[%a_][%w_]*")))
			if fmode or (not vmode and not isvar) then
				-- -f, or a name that can't be a variable: a function name
				unset_fn(a)
			elseif not isvar then
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
					local en = sh:deref(nm)
					local eb = sh.vars[en]
					if (eb and eb.ro) or (not eb and (en == "SHELLOPTS" or en == "BASHOPTS")) then
						io.stderr:write("curse: unset: " .. en .. ": cannot unset: readonly variable\n")
						sh.status = 1
						goto next_arg
					elseif (sub == "@" or sub == "*") and eb and not eb.arr then
						-- (unbind_array_element: `@`/`*` never unsets a scalar)
						io.stderr:write("curse: unset: " .. en .. ": not an array variable\n")
						sh.status = 1
						goto next_arg
					elseif (sub == "@" or sub == "*") and eb and eb.arr and (rt.compat_level(sh) <= 51 or not eb.assoc) then
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
					local b = sh.vars[dn]
					if (b and b.ro) or (b == nil and (dn == "SHELLOPTS" or dn == "BASHOPTS")) then
						-- readonly: cannot unset (bash: status 1, keep it)
						io.stderr:write("curse: unset: " .. dn .. ": cannot unset: readonly variable\n")
						sh.status = 1
						goto next_arg
					end
					if rt.NOUNSET_ARR[dn] and rt.noassign_live(sh, dn) then
						-- (BASH_SOURCE, BASH_ARGV, …: bash's att_nounset)
						io.stderr:write("curse: unset: " .. dn .. ": cannot unset\n")
						sh.status = 1
						goto next_arg
					end
					if nmode and not (b and b.ref) then
						goto next_arg -- `unset -n` leaves a variable that isn't a nameref alone (bash)
					end
					if dn == "RANDOM" then
						sh.random_plain = true -- (unset RANDOM loses its special meaning — bash)
					elseif (b == nil or b.dyn) and (rt.DYN_SPECIAL[dn] or rt.DYN_ASSIGN[dn]) then
						-- a dynamic variable unset loses its magic for good (bash)
						sh.unset_specials = sh.unset_specials or {}
						sh.unset_specials[dn] = true
					end
					if b ~= nil or vmode then
						-- bash dynamic-scope unset: when the var is NOT local to the CURRENT
						-- frame but shadows a local declared in an ENCLOSING frame (e.g. an
						-- `unset -v` run from a nested `unlocal` helper), removing it REVEALS
						-- that outer binding instead of leaving the name unset.
						local revealed, env_done, inplace = false, false, false
						-- unset of a var LOCAL to the current frame just makes it appear unset
						-- (bash: the outer value stays hidden until the function returns). Only
						-- when the name is NOT local here does unset REVEAL a shadowed binding —
						-- and it peels the MOST RECENT layer, whether that's an enclosing `local`
						-- shadow (savedstack) or a tempenv `x=v cmd` binding (sh.tenv), ordered by
						-- a monotonic seq so interleaved local/tempenv layers unwind correctly.
						-- With localvar_unset an enclosing frame's local is unset in place too.
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
							if best_d and sh.shopt.localvar_unset then
								inplace = true
							elseif best_d then
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
						local here = inplace or sh.savedstack[sh.pd] and sh.savedstack[sh.pd][dn] ~= nil
						if not revealed and here and b then
							-- a local of THIS call stays a (value-less) local — a plain one, its
							-- attributes gone: `local -i v=3; unset v; v=1+1` stores `1+1`,
							-- `declare -p v` -> `declare -- v` (bash). One that took over a
							-- tempenv binding (`v=t f`) stays exported, as that binding was.
							local rec = sh.savedstack[sh.pd] and sh.savedstack[sh.pd][dn]
							sh.vars[dn] = { exported = (rec and rec.absorbed and b.exported) or nil }
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
						if dn == "PATH" and sh.hashcache then
							sh.hashcache = {} -- (sv_path: unsetting PATH flushes the hash table)
						end
						if dn == "GLOBIGNORE" then
							rt.setup_glob_ignore(sh) -- (unset: dotglob off)
						end
						if dn == "IGNOREEOF" then
							sh.opt_ignoreeof = false -- (sv_ignoreeof)
						end
						if dn == "POSIXLY_CORRECT" then
							sh.opt_posix = false -- (sv_strict_posix: unsetting it leaves posix mode)
						end
					elseif not nmode then
						unset_fn(a) -- plain unset falls back to a function
					end
				end
			end
			::next_arg::
		end
	end
end
