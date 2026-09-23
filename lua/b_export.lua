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
local func_body_text = I.func_body_text
local C, P = I.C, I.P

return function(sh, cmd, args, hook, tcb)
	if cmd == "export" or cmd == "declare" or cmd == "typeset" or cmd == "readonly" then
		-- export/declare [-Apx] NAME[=val]…: set the var; export/-x also pushes it to
		-- the process env so posix_spawn children inherit it. -A marks associative,
		-- -p prints declarations.
		local doexport, assoc, printmode, nref, plusn = (cmd == "export"), false, false, false, false
		local plusx, gflag, unexport = false, false, false
		local tattr, plust, plusr = false, false, false -- -t / +t: the function trace attribute
		local funcnames, funcbody, iattr, lattr, uattr, rattr, aattr = false, false, false, false, false, false, false
		local cattr = false -- declare -c: capitalize (first char upper, rest lower)
		local plusattr, plusarr -- +i/+l/+u/+c; +a/+A (an array can't be made scalar)
		local rest = {}
		-- Valid attribute letters per command; any other letter is an invalid option
		-- (bash: status 2, or 1 for `local`). export/readonly accept a narrower set.
		local VALID = (cmd == "export" or cmd == "readonly") and "afnpA" or "aAcfFgilnprtuxI"
		local opterr, endopts = nil, false
		for j = 2, #args do
			local a = args[j]
			if a == "--" then
				endopts = true -- end of flags
			elseif not endopts and a:sub(1, 1) == "-" and #a > 1 then
				for ci = 2, #a do
					local ch = a:sub(ci, ci)
					if not VALID:find(ch, 1, true) then
						opterr = ch
						break
					end
				end
				if opterr then
					break
				end
				if a:find("A") then
					assoc = true
				end
				if a:find("p") then
					printmode = true
				end
				if a:find("x") then
					doexport = true
				end
				-- `-n` un-exports for `export`, but means nameref for declare/typeset/local
				if a:find("n") then
					if cmd == "export" then
						unexport = true
					else
						nref = true
					end
				end
				if a:find("F") then
					funcnames = true
				end
				if a:find("f") then
					funcbody = true
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
				if a:find("c") then
					cattr = true
				end
				if a:find("r") then
					rattr = true
				end
				if a:find("a") then
					aattr = true
				end
				if a:find("g") then
					gflag = true
				end
				if a:find("t") then
					tattr = true
				end
			elseif not endopts and a:sub(1, 1) == "+" and #a > 1 then
				if a:find("n") then
					plusn = true
				end
				if a:find("x") then
					plusx = true
				end -- +x: drop the export attribute
				if a:find("t") then
					plust = true
				end
				if a:find("r") then
					plusr = true
				end
				for ch in a:sub(2):gmatch("[iluc]") do -- +i/+l/+u/+c: drop that attribute
					plusattr = plusattr or {}
					plusattr[ch] = true
				end
				if a:find("A") then
					plusarr = "A"
				elseif a:find("a") then
					plusarr = "a"
				end
			else
				rest[#rest + 1] = a
			end
		end
		if opterr then -- an unknown attribute letter: bash prints usage and fails (status 2)
			io.stderr:write("curse: " .. cmd .. ": -" .. opterr .. ": invalid option\n")
			sh.status = 2
			return
		end
		-- listing a subset of variables (bare `declare`/`export`/`readonly`, or with
		-- -p and no names): the builtin + attribute flags select which vars to print.
		local function decl_match(nm, b) -- (every attribute asked for must hold: -ar = both)
			if not b then
				return false
			end
			if (cmd == "readonly" or rattr) and not b.ro then
				return false
			end
			if (cmd == "export" or doexport) and not b.exported then
				return false
			end
			if (nref and not b.ref) or (assoc and not b.assoc) or (aattr and not (b.arr and not b.assoc)) then
				return false
			end
			if (iattr and not b.int) or (lattr and not b.lower) or (uattr and not b.upper) then
				return false
			end
			return true
		end
		local function list_decls()
			-- plain `declare`/`typeset` (no attribute flags, no -p) prints bare
			-- `name=value` like `set`; with a flag or -p it prints `declare -X name=…`.
			local bare = (cmd == "declare" or cmd == "typeset")
				and not printmode
				and not (doexport or rattr or iattr or lattr or uattr or aattr or assoc or nref)
			local names = {}
			for nm in pairs(sh.vars) do
				names[#names + 1] = nm
			end
			-- SHELLOPTS / BASHOPTS are derived live (not stored) but list as readonly vars
			local virt = {}
			for _, nm in ipairs({ "SHELLOPTS", "BASHOPTS" }) do
				if sh.vars[nm] == nil then
					virt[nm] = { s = sh:get(nm), ro = true }
					names[#names + 1] = nm
				end
			end
			if not bare then -- (the dynamic arrays, as bash lists them: `declare -a`, `declare -p`)
				for nm in pairs(M.DYN_ARRAYS) do
					if sh.vars[nm] == nil then
						virt[nm] = { arr = {} }
						names[#names + 1] = nm
					end
				end
			end
			table.sort(names)
			for _, nm in ipairs(names) do
				local box = sh.vars[nm] or virt[nm]
				if decl_match(nm, box) then
					local d = bare and fmt_set_var(nm, box) or fmt_decl(sh, nm)
					if d and sh.opt_posix and (cmd == "readonly" or cmd == "export") then
						-- posix mode lists `readonly [-a|-A] name=value` / `export …` (bash)
						local fl, rest = d:match("^declare %-(%S*) (.*)$")
						if fl then
							local kind = fl:match("[aA]")
							d = cmd .. (kind and (" -" .. kind) or "") .. " " .. rest
						end
					end
					if d then
						sh:echo(d)
					end
				end
			end
		end
		local fnbad = (funcnames or funcbody)
			and (aattr and "a" or assoc and "A" or iattr and "i" or lattr and "l" or uattr and "u" or cattr and "c" or nref and "n")
		if fnbad then -- an attribute a function can't have (bash: status 1)
			io.stderr:write("curse: " .. cmd .. ": -" .. fnbad .. ": invalid option\n")
			sh.status = 1
			return
		end
		local fattr = tattr or plust or rattr or plusr or doexport or unexport or plusx
			or cmd == "readonly" or cmd == "export"
		if (funcnames or funcbody) and #rest > 0 and fattr then
			-- set function attributes (nothing printed): -t trace (inherits DEBUG/RETURN),
			-- -r readonly (can't be redefined or unset), -x export (the function goes into
			-- the environment as BASH_FUNC_NAME%% — rt.fexport_sync; -n/+x un-exports)
			local allok = true
			for _, nm in ipairs(rest) do
				if (cmd == "export" or doexport) and nm:find("=", 1, true) then
					io.stderr:write("curse: " .. cmd .. ": " .. nm .. ": cannot export\n")
					allok = false
				elseif not sh.functions[nm] then
					if cmd == "export" or doexport then
						io.stderr:write("curse: " .. cmd .. ": " .. nm .. ": not a function\n")
					end
					allok = false
				elseif plusr and sh.fn_ro and sh.fn_ro[nm] then
					io.stderr:write("curse: " .. cmd .. ": " .. nm .. ": readonly function\n")
					allok = false
				else
					if tattr or plust then
						sh.fn_trace = sh.fn_trace or {}
						sh.fn_trace[nm] = tattr or nil
					end
					if rattr or cmd == "readonly" then
						sh.fn_ro = sh.fn_ro or {}
						sh.fn_ro[nm] = true
					end
					if cmd == "export" or doexport or unexport or plusx then
						sh.fexport = sh.fexport or {}
						sh.fexport[nm] = not (unexport or plusx) or nil
						rt.fexport_sync(sh, nm)
					end
				end
			end
			sh.status = allok and 0 or 1
		elseif funcnames or funcbody then
			-- declare -F [name…] lists `declare -f NAME`; -f prints bodies (not
			-- reconstructed here) — either way the exit status signals existence.
			-- With no names, an exported function's listing is marked `declare -fx NAME`,
			-- and -x (or `export -f`) lists only the exported ones.
			local names, allok, named = rest, true, #rest > 0
			local fx, fro, ftr = sh.fexport or {}, sh.fn_ro or {}, sh.fn_trace or {}
			if #names == 0 then -- (-x / -r / `export -f` / `readonly -f`: only those)
				names = {}
				for k in pairs(sh.functions) do
					if (not (doexport or cmd == "export") or fx[k]) and (not (rattr or cmd == "readonly") or fro[k]) then
						names[#names + 1] = k
					end
				end
				table.sort(names)
			end
			local function fdecl(nm) -- `declare -f[r][t][x] NAME`
				return "declare -f" .. (fro[nm] and "r" or "") .. (ftr[nm] and "t" or "") .. (fx[nm] and "x" or "") .. " " .. nm
			end
			for _, nm in ipairs(names) do
				-- `declare -f NAME` prints the verbatim definition (captured at parse time);
				-- `declare -F NAME` prints just NAME; bare `declare -F` prints `declare -f NAME`.
				if sh.functions[nm] then
					if funcbody then
						local d = func_body_text(sh, nm)
						if d then
							sh:echo(d)
						end
						if not named and (fx[nm] or fro[nm] or ftr[nm]) then
							sh:echo(fdecl(nm))
						end
					elseif funcnames then
						if named and sh.shopt.extdebug then -- extdebug: `name line file`
							sh:echo(
								nm
									.. " "
									.. (sh.func_line and sh.func_line[nm] or 0)
									.. " "
									.. (sh.func_file and sh.func_file[nm] or "")
							)
						else
							sh:echo(named and nm or fdecl(nm))
						end
					end
				else
					if printmode and funcbody then -- (`declare -f -p NAME` says so; -f alone is quiet)
						io.stderr:write("curse: " .. cmd .. ": " .. nm .. ": not found\n")
					end
					allok = false
				end
			end
			sh.status = allok and 0 or 1
		elseif #rest == 0 then -- no operands: list matching declarations (declare -p, or bare)
			list_decls()
			sh.status = 0
		elseif printmode then
			-- Only `declare`/`typeset -p NAME` prints a named declaration; `readonly -p
			-- NAME` and `export -p NAME` (with operands) print nothing (bash quirk — the
			-- no-operand forms still list all, handled above).
			if cmd == "readonly" or cmd == "export" then
				sh.status = 0
			else
				local allok = true
				for _, nm in ipairs(rest) do
					local d = fmt_decl(sh, nm)
					if d then
						sh:echo(d)
					else
						allok = false
						io.stderr:write("curse: " .. cmd .. ": " .. nm .. ": not found\n")
					end
				end
				sh.status = allok and 0 or 1
			end
		else
			rt.assign_ctx = cmd -- (a bad nameref target is `declare: `/': not a valid identifier')
			local roattr = (cmd == "readonly") or rattr
			-- `declare`/`typeset` in a function make each name LOCAL (like `local`),
			-- unless -g; `export`/`readonly` always act on the global var (bash).
			local localize = (cmd == "declare" or cmd == "typeset") and not gflag and (sh.calldepth or 0) > 0
			local unswap
			if gflag and (sh.calldepth or 0) > 0 then -- (act on the globals, past any caller's locals)
				local gnames = {}
				for _, a in ipairs(rest) do
					gnames[#gnames + 1] = a:match("^([%a_][%w_]*)")
				end
				unswap = sh:global_swap(gnames)
			end
			local allok = true
			for _, a in ipairs(rest) do
				-- `declare -A c[200]` / `declare x[3]`: an element form with no value declares
				-- the array itself (bash ignores the subscript)
				local mkarr = false
				if (cmd == "declare" or cmd == "typeset") and not a:find("=", 1, true) then
					local base = a:match("^([%a_][%w_]*)%[.*%]$")
					if base and nref then -- (`declare -n a[3]`)
						io.stderr:write("curse: " .. cmd .. ": " .. a .. ": reference variable cannot be an array\n")
						allok = false
						goto continue
					end
					if base then
						a, mkarr = base, true
					end
				end
				-- exporting / readonly-ing a name bound by a command-prefix tempenv (`y=5 f`
				-- with `export y` in f, `x=4 export x`) makes that binding PERMANENT (bash's
				-- att_propagate): it isn't restored when the command ends, and isn't localized
				local tnm = (doexport or roattr) and not unexport and a:match("^([%a_][%w_]*)")
				local propagated = false
				if tnm then
					for k = #sh.tenv, 1, -1 do
						local te = sh.tenv[k]
						-- (a function-local declaration's OWN prefix is absorbed by the local
						-- instead: `var=value declare -x var` in f leaves the global alone)
						if not te.consumed and te.name == tnm and not (localize and te.decl_pd == sh.pd) then
							te.consumed = true
							propagated = true
							local pb = sh.vars[tnm]
							if pb then
								pb.exported = true -- (a command-prefix binding is in the environment)
							end
							break
						end
					end
				end
				local localize = localize and not propagated
				if a == "SHELLOPTS" and (doexport or roattr) and not unexport and not plusx then
					-- $SHELLOPTS is a dynamic special (special_get), not a stored var: mark
					-- it exported and sync the env NOW (set_opt keeps it current after), so
					-- children inherit the option set. Don't create a shadowing real var.
					if doexport then
						sh.shellopts_exported = true
						C.setenv("SHELLOPTS", sh:shellopts(), 1)
					end
					goto continue
				end
				if (aattr or assoc) and not nref and not localize and not a:find("[", 1, true) then
					-- `declare -n foo; declare -a foo`: a VALUELESS nameref becomes the array
					local vn = a:match("^([%a_][%w_]*)")
					local vb = vn and sh.vars[vn]
					if vb and vb.ref and vb.s == nil and not vb.ro then
						sh.vars[vn] = nil
					end
				end
				local nm, op, val = a:match("^([%a_][%w_]*)(%+?=)(.*)$")
				do
					local db = nm and not nref and not plusn and sh.vars[nm]
					if db and db.ref and db.s and not db.ro and (localize or aattr or assoc)
						and db.s:match("^[%a_][%w_]*$") and sh:deref(nm) ~= "" then
						nm = sh:deref(nm) -- (`local -a ref=(…)`, ref -> var: declares the target)
					end
				end
				-- (`declare -n ref=x` re-points the ref: the REF's own readonly-ness counts)
				local rov = nm and sh.vars[nref and nm or sh:deref(nm)]
				if rov and rov.ro then
					-- reassigning a readonly variable is rejected (bash: `typeset +r r=v` too)
					-- (declare/typeset name themselves; export/readonly don't, like bash)
					local pfx = (cmd == "export" or cmd == "readonly") and "" or (cmd .. ": ")
					io.stderr:write("curse: " .. pfx .. nm .. ": readonly variable\n")
					allok = false
				elseif
					nm
					and (
						aattr
						or assoc
						or ((cmd == "declare" or cmd == "typeset") and not nref and sh.vars[sh:deref(nm)] and sh.vars[sh:deref(nm)].arr)
					)
					and val:sub(1, 1) == "("
					and val:sub(-1) == ")"
				then -- (declare also for a name that's ALREADY an array: `declare a='(1 2)'`;
					-- readonly/export keep such a quoted value literal)
					-- dynamic array literal: `declare -a "x=(1 2 3)"` (the -a/-A flag is required)
					if localize then
						sh:localVar(nm)
					end
					if assoc then
						sh:declare_assoc(nm)
					end
					if lattr or uattr or cattr or iattr then -- (the elements take the attributes)
						local ab = sh.vars[sh:deref(nm)] or {}
						sh.vars[sh:deref(nm)] = ab
						ab.lower, ab.upper, ab.cap = lattr or nil, uattr or nil, cattr or nil
						ab.int = iattr or ab.int
					end
					local ast = P.parse(nm .. (op == "+=" and "+=" or "=") .. val)
					local st1 = ast.stmts[1]
					if st1 and st1.t == "arrayassign" then
						M.do_arrayassign(sh, st1)
					end
					local bb = sh.vars[sh:deref(nm)]
					if roattr and bb then
						bb.ro = true
					end
				elseif nm and not nref and op == "=" and sh.vars[nm] and sh.vars[nm].ref
					and sh.vars[nm].s == nil and not aattr and not assoc
					and (not localize or (sh.savedstack[sh.pd] and sh.savedstack[sh.pd][nm] ~= nil)) then
					-- a VALUELESS nameref takes the value as its target, unevaluated (bash: even
					-- under -i); a bad target fails the declare — a global nameref is then gone,
					-- a function's own local one stays
					if rt.ref_target_ok(val) then
						sh.vars[nm].s = val
					elseif localize then
						io.stderr:write("curse: " .. cmd .. ": `" .. val .. "': invalid variable name for name reference\n")
						allok = false
					else
						rt.bad_ref_target(val, cmd)
						sh.vars[nm] = nil
						allok = false
					end
				elseif nm then
					local selfsub = not nref and not localize and sh:self_elem_unref(nm)
					if selfsub then -- (a -> b -> 'a[1]': a becomes an array; see self_elem_unref)
						sh:array_set(nm, array_key(sh, nm, selfsub), val, op == "+=")
						goto continue
					end
					local eb, esub = (not nref and sh.vars[nm] and sh.vars[nm].ref and sh:deref_elem(nm) or "")
						:match("^([%a_][%w_]*)%[(.+)%]$")
					if eb then -- (`typeset ref=4` with ref -> XXX[0]: writes that element)
						sh:array_set(eb, array_key(sh, eb, esub), val, op == "+=")
						goto continue
					end
					if localize then
						sh:localVar(nm)
					end
					local ap = (op == "+=")
					if nref and iattr then -- (`declare -in b=v`: bash fails it, silently, status 1)
						allok = false
					elseif nref then
						local nb = sh.vars[nm]
						if ap and nb and nb.ref then -- `-n ref+=x`: appends to the reference itself
							val = (nb.s or "") .. val
						end
						if ap and val:match("^[^[]*") == nm then -- (bash names no builtin here)
							io.stderr:write("curse: " .. nm .. ": nameref variable self references not allowed\n")
							allok = false
						elseif not sh:nameref_decl(cmd, nm, val, localize) then
							allok = false
						end
					elseif iattr and aattr and not assoc then -- declare -ai a=EXPR: element 0, integer
						local v = M.arith_eval_str(sh, val)
						if ap then
							v = rt.arith_str(sh, sh:array_get(nm, 0)) + v
						end
						sh:array_set(nm, 0, rt.i64_to_str(v), false)
						sh.vars[sh:deref(nm)].int = true
					elseif iattr then -- declare -i: arith-evaluate the value, mark integer
						if ap then -- (the old value is evaluated as an expression too)
							sh:aset(nm, rt.arith_str(sh, sh:get(nm)) + M.arith_eval_str(sh, val))
						else
							sh:aset(nm, M.arith_eval_str(sh, val))
						end
						sh.vars[sh:deref(nm)].int = true -- (through a nameref: its target)
					elseif lattr or uattr or cattr then -- declare -l/-u/-c: case attribute (set_str folds)
						sh.vars[nm] = sh.vars[nm] or {}
						sh.vars[nm].lower = lattr or nil
						sh.vars[nm].upper = uattr or nil
						sh.vars[nm].cap = cattr or nil
						if sh.vars[nm].arr then -- (an array's element 0, folded by array_set)
							sh:array_set(nm, sh.vars[nm].assoc and "0" or 0, val, ap)
						else
							sh:set_str(nm, ap and (sh:get(nm) .. val) or val)
						end
					else
						local eb = sh.vars[sh:deref(nm)]
						if ((eb and eb.arr and not eb.assoc) or aattr) and not assoc then
							-- scalar (+)= on an indexed array (or `declare -a f=x`) -> element 0
							sh:array_set(nm, array_key(sh, nm, "0"), val, ap)
						elseif assoc or (eb and eb.assoc) then -- …an associative one: key "0"
							if assoc then
								sh:declare_assoc(nm)
							end
							sh:array_set(nm, "0", val, ap)
						else
							if eb and eb.int and not assoc then -- an integer var stays arithmetic
								local v = rt.arith_str(sh, val)
								sh:aset(nm, ap and (rt.arith_str(sh, sh:get(nm)) + v) or v)
							else
								sh:set_str(nm, ap and (sh:get(nm) .. val) or val)
							end
						end
					end
					local bb = sh.vars[sh:deref(nm)]
					if roattr and nref and sh.vars[nm] and sh.vars[nm].ref then
						sh.vars[nm].ro = true -- (with -n, -r makes the REFERENCE readonly: `-nr`)
					elseif roattr and bb and not nref then
						bb.ro = true
					end
					-- export attribute: -n / +x clear it (keep the value), else export sets it.
					-- A nameref exports the nameref BOX itself, and its env value is the TARGET
					-- NAME it points at (`declare -nx ref=x` -> env ref="x"), not the deref value.
					local xb = nref and sh.vars[nm] or bb
					local xval = nref and (xb and xb.s or "") or sh:get(nm)
					if xb then
						if unexport or plusx then
							xb.exported = nil
							sh:env_resync(nm) -- (a shadowed exported global keeps its env value)
						elseif doexport or sh.opt_a then
							xb.exported = true
							C.setenv(nm, xval, 1)
						end
					end
					if plusn then -- `typeset +n ref=v`: v went THROUGH the ref; then it's plain
						sh:unref(nm)
					end
				elseif roattr and not nref and not plusn and sh.vars[a] and sh.vars[a].ref
					and (sh.vars[a].s or ""):find("[", 1, true) then
					-- `readonly ref` through a nameref to an ELEMENT (ref=var[0]) (bash)
					io.stderr:write("curse: " .. cmd .. ": `" .. sh.vars[a].s .. "': not a valid identifier\n")
					allok = false
				elseif a:match("^[%a_][%w_]*$") then
					local db = sh.vars[a]
					if db and db.ref and db.s and not db.ro and not nref and not plusn and not plusr
						and (aattr or assoc or localize) and db.s:match("^[%a_][%w_]*$") and sh:deref(a) ~= "" then
						-- `declare [-a] ref` (ref -> var) declares the TARGET (a function-local
						-- var when in a function), leaving the nameref as it is (bash)
						a = sh:deref(a)
						db = sh.vars[a]
					end
					-- a readonly nameref can't lose -n (once it has a target) nor -r (bash)
					if db and db.ref and db.ro and ((plusn and db.s ~= nil) or (nref and plusr)) then
						io.stderr:write("curse: " .. cmd .. ": " .. a .. ": readonly variable\n")
						allok = false
						goto continue
					end
					if (assoc or aattr) and not nref and db and db.ref and sh:deref_elem(a) then
						goto continue -- (`declare -A ref`, ref -> XXX[0]: nothing to convert — bash)
					end
					if plusr and not nref and not (db and db.ref and db.s == nil) then
						-- `+r` can't lift readonly — through a nameref, from its target — and
						-- declares a missing target (`declare +r ref` -> `declare -- bar`)
						local dn = sh:deref(a)
						local tb = sh.vars[dn]
						if tb and tb.ro then
							io.stderr:write("curse: " .. cmd .. ": " .. dn .. ": readonly variable\n")
							allok = false
							goto continue
						elseif not tb and dn ~= "" then
							sh.vars[dn] = {}
						end
					end
					if localize then
						sh:localVar(a)
					end
					if plusn then
						sh:unref(a)
					elseif nref and sh.arrayargs_pending and sh.arrayargs_pending[a] then
						-- `declare -n r=(…)`: an array can't be a reference — the literal is
						-- still assigned, to a plain array (bash)
						io.stderr:write("curse: " .. cmd .. ": " .. a .. ": reference variable cannot be an array\n")
						allok = false
						sh.arrayargs_pending.force = sh.arrayargs_pending.force or {}
						sh.arrayargs_pending.force[a] = true
					elseif nref then
						if not sh:nameref_decl(cmd, a, nil, localize) then -- (an invalid existing value…)
							allok = false
						elseif iattr then -- (`declare -ni ref`: the reference itself takes -i)
							sh.vars[a].int = true
						end
					elseif iattr and not ((assoc or aattr) and cmd ~= "readonly") then
						local dn = sh:deref(a) -- (through a nameref: the target, created if need be)
						sh.vars[dn] = sh.vars[dn] or {}
						sh.vars[dn].int = true
					elseif (lattr or uattr or cattr) and not ((assoc or aattr) and cmd ~= "readonly") then
						local dn = sh:deref(a)
						sh.vars[dn] = sh.vars[dn] or {}
						sh.vars[dn].lower = lattr or nil
						sh.vars[dn].upper = uattr or nil
						sh.vars[dn].cap = cattr or nil
					elseif assoc and (cmd ~= "readonly" or (sh.arrayargs_pending and sh.arrayargs_pending[a])) then
						-- (readonly -A applies the attribute only with a compound value)
						-- bash forbids converting an existing indexed array to associative
						-- (`readonly -A` with NO value does NOT apply the attribute — bash then
						-- shows just `declare -r`, so let it fall through to the plain-var branch)
						local b = sh.vars[sh:deref(a)]
						if b and b.arr and not b.assoc then
							local compound = sh.arrayargs_pending and sh.arrayargs_pending[a]
							if rt.array_convert_msg(sh, cmd, a, "indexed to associative array", compound) ~= 0 then
								allok = false
							end
							if compound then
								sh.arrayargs_pending.skip = sh.arrayargs_pending.skip or {}
								sh.arrayargs_pending.skip[a] = true -- (its literal isn't assigned)
							end
						else
							local fresh = b == nil or (b.arr == nil and b.s == nil and b.n == nil)
							sh:declare_assoc(a)
							if fresh then
								sh.vars[sh:deref(a)].empty_decl = true
							end -- declared, never assigned
						end
					elseif aattr and cmd ~= "readonly" then -- `declare -a`: mark an (empty) indexed array; convert a scalar to [0]
						local b = sh.vars[a] or {}
						if b.ro and b.assoc then -- (readonly is reported before any conversion)
							io.stderr:write("curse: " .. a .. ": readonly variable\n")
							allok = false
							if sh.arrayargs_pending and sh.arrayargs_pending[a] then
								sh.arrayargs_pending.skip = sh.arrayargs_pending.skip or {}
								sh.arrayargs_pending.skip[a] = true
							end
						elseif b.assoc then -- …and the reverse conversion is forbidden too
							local compound = sh.arrayargs_pending and sh.arrayargs_pending[a]
							if rt.array_convert_msg(sh, cmd, a, "associative to indexed array", compound) ~= 0 then
								allok = false
							end
							if compound then
								sh.arrayargs_pending.skip = sh.arrayargs_pending.skip or {}
								sh.arrayargs_pending.skip[a] = true -- (its literal isn't assigned)
							end
						else
							sh.vars[a] = b
							if b.s ~= nil and not b.arr then
								b.arr = { [0] = b.s }
								b.s = nil
								b.n = nil
							elseif not b.arr then
								b.arr = {}
								b.empty_decl = true
							end -- declared, never assigned
						end
					else
						sh.vars[a] = sh.vars[a] or {}
					end -- `declare x` (or `readonly -a/-A` with no value) creates a declared-but-unset var
					local bb = sh.vars[sh:deref(a)]
					if not bb and not nref and (roattr or doexport) then -- `readonly ref`: the
						bb = {} -- nameref's (unset) target gets the attribute, and so exists
						sh.vars[sh:deref(a)] = bb
					end
					if bb and (assoc or aattr) and cmd ~= "readonly" and not nref then -- (`declare -Ai`: both)
						if iattr then
							bb.int = true
						end
						if lattr or uattr or cattr then
							bb.lower, bb.upper, bb.cap = lattr or nil, uattr or nil, cattr or nil
						end
					end
					if roattr and nref and sh.vars[a] and sh.vars[a].ref then
						sh.vars[a].ro = true -- (with -n, -r makes the REFERENCE readonly)
					elseif roattr and bb and not nref then
						bb.ro = true
					end
					if bb then
						if unexport or plusx then
							bb.exported = nil
							sh:env_resync(a) -- (a shadowed exported global keeps its env value)
						elseif doexport then
							bb.exported = true -- `export U` defers the env until U gets a value (bash)
							if bb.s ~= nil or bb.n ~= nil then -- (through a nameref: the target's name)
								C.setenv(nref and a or sh:deref(a), sh:get(a), 1)
							end
						end
					end
				elseif a:find("[", 1, true) then -- name[subscript]=value : array-element form
					-- Find the MATCHING ] for the first [ (the subscript may itself contain a
					-- `[...]`, e.g. `declare a[a[0]=1]=X`), not the first ] — then =/+= and value.
					local anm, sub, aop, aval = nil, nil, nil, nil
					local nm, rest = a:match("^([%a_][%w_]*)%[(.*)$")
					if nm then
						local depth, close = 1, nil
						for j = 1, #rest do
							local ch = rest:sub(j, j)
							if ch == "[" then
								depth = depth + 1
							elseif ch == "]" then
								depth = depth - 1
								if depth == 0 then
									close = j
									break
								end
							end
						end
						if close then
							local after = rest:sub(close + 1)
							if after:sub(1, 2) == "+=" then
								anm, sub, aop, aval = nm, rest:sub(1, close - 1), "+=", after:sub(3)
							elseif after:sub(1, 1) == "=" then
								anm, sub, aop, aval = nm, rest:sub(1, close - 1), "=", after:sub(2)
							end
						end
						if not anm and not close and sh.shopt.assoc_expand_once then -- (a quoted `[`
							-- in the source subscript — declare m["foo[bar"]=v — left brackets
							-- unbalanced: under assoc_expand_once it ends at the first ]=)
							local s2, op2, v2 = rest:match("^(.-)%](%+?=)(.*)$")
							if s2 and s2 ~= "" then
								anm, sub, aop, aval = nm, s2, op2, v2
							end
						end
					end
					-- bash creates the element for declare/typeset/local, but NOT via a
					-- deferred `readonly a[i]=v` / `export a[i]=v` (those fail, status 1).
					if anm and sub == "" then -- `declare a[]=x`
						io.stderr:write("curse: " .. anm .. "[]: bad array subscript\n")
						allok = false
					elseif anm and (aattr or assoc) and (cmd == "declare" or cmd == "typeset")
						and aval:sub(1, 1) == "(" and aval:sub(-1) == ")" then
						-- `declare -a e[10]='(test)'`: a compound value assigns the whole array
						-- (bash ignores the subscript)
						if localize then
							sh:localVar(anm)
						end
						if assoc then
							sh:declare_assoc(anm)
						end
						local st1 = P.parse(anm .. (aop == "+=" and "+=" or "=") .. aval).stmts[1]
						if st1 and st1.t == "arrayassign" then
							M.do_arrayassign(sh, st1)
						end
					elseif anm and nref then -- `declare -n a[3]=x`
						io.stderr:write("curse: " .. cmd .. ": " .. anm .. "[" .. sub .. "]: reference variable cannot be an array\n")
						allok = false
					elseif anm and (cmd == "declare" or cmd == "typeset") then
						if aval:sub(1, 1) == "(" and aval:sub(-1) == ")" and sh.vars[sh:deref(anm)] == nil then
							-- (bash warns only when it's creating the array here)
							io.stderr:write("curse: warning: " .. anm .. "[" .. sub .. "]=" .. aval .. ": quoted compound array assignment deprecated\n")
						end
						if localize then
							sh:localVar(anm)
						end
						local rb = sh.vars[anm]
						if rb and rb.ref then -- (`declare ref[1]=v`: the nameref becomes the array)
							io.stderr:write("curse: warning: " .. anm .. ": removing nameref attribute\n")
							sh.vars[anm] = { exported = rb.exported }
						end
						if assoc and not sh:is_assoc(anm) then -- (`declare -A m[k]=v` makes m assoc)
							sh:declare_assoc(anm)
						end
						sh:array_set(anm, array_key(sh, anm, sub), aval, aop == "+=")
						local bb = sh.vars[sh:deref(anm)]
						if roattr and bb then
							bb.ro = true
						end
					else -- (`A[]]=X`: no valid subscript; `readonly a[1]=v`: not assignable here)
						io.stderr:write(
							"curse: " .. cmd .. ": `" .. (anm and (anm .. "[" .. sub .. "]") or a) .. "': not a valid identifier\n"
						)
						allok = false
					end
				else -- a token that isn't a valid name (`FOO-BAR`, `1x`, …): bash errors
					io.stderr:write("curse: " .. cmd .. ": `" .. a .. "': not a valid identifier\n")
					allok = false
				end
				do
					local pname = a:match("^([%a_][%w_]*)")
					local pb = pname and sh.vars[sh:deref(pname)]
					if mkarr and pname and not assoc and not (pb and pb.arr) then
						pb = pb or {}
						local v0 = pb.s or (pb.n and rt.i64_to_str(pb.n)) -- (a scalar becomes [0]: bash)
						pb.arr, pb.s, pb.n, pb.empty_decl = pb.arr or (v0 and { [0] = v0 }) or {}, nil, nil, v0 == nil or nil
						sh.vars[sh:deref(pname)] = pb
					end
					if pb and plusattr then
						pb.int = not plusattr.i and pb.int or nil
						pb.lower = not plusattr.l and pb.lower or nil
						pb.upper = not plusattr.u and pb.upper or nil
						pb.cap = not plusattr.c and pb.cap or nil
					end
					if pb and plusarr and pb.arr and ((plusarr == "A") == (pb.assoc == true)) then
						io.stderr:write("curse: " .. cmd .. ": " .. pname .. ": cannot destroy array variables in this way\n")
						allok = false
					end
				end
				::continue::
			end
			rt.assign_ctx = nil
			if unswap then
				if sh.arrayargs_pending then
					sh.pending_unswap = unswap -- (interp assigns the NAME=(…) literals next)
				else
					unswap()
				end
			end
			sh.status = allok and 0 or 1
		end
	end
end
