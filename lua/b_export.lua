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
		local tattr, plust = false, false -- -t / +t: the function trace attribute
		local funcnames, funcbody, iattr, lattr, uattr, rattr, aattr = false, false, false, false, false, false, false
		local cattr = false -- declare -c: capitalize (first char upper, rest lower)
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
		local function decl_match(nm, b)
			if not b then
				return false
			end
			if cmd == "readonly" or rattr then
				return b.ro
			end
			if cmd == "export" or doexport then
				return b.exported
			end
			if nref then
				return b.ref
			end
			if assoc then
				return b.assoc
			end
			if aattr then
				return b.arr and not b.assoc
			end
			if iattr then
				return b.int
			end
			if lattr then
				return b.lower
			end
			if uattr then
				return b.upper
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
			table.sort(names)
			for _, nm in ipairs(names) do
				if decl_match(nm, sh.vars[nm]) then
					local d = bare and fmt_set_var(nm, sh.vars[nm]) or fmt_decl(sh, nm)
					if d then
						sh:echo(d)
					end
				end
			end
		end
		if (funcnames or funcbody) and (tattr or plust) and #rest > 0 then
			-- `declare -ft NAME…` / `+t`: SET the trace attribute (a traced function inherits
			-- the DEBUG/RETURN traps, like functrace for just it) — nothing is printed
			local allok = true
			for _, nm in ipairs(rest) do
				if sh.functions[nm] then
					sh.fn_trace = sh.fn_trace or {}
					sh.fn_trace[nm] = tattr or nil
				else
					allok = false
				end
			end
			sh.status = allok and 0 or 1
		elseif (funcnames or funcbody) and #rest > 0 and (cmd == "export" or doexport or unexport or plusx) then
			-- `export -f NAME…` / `declare -fx NAME…` (`-n`/`+x`: un-export): the function
			-- goes into the environment as BASH_FUNC_NAME%% (rt.fexport_sync)
			local allok = true
			for _, nm in ipairs(rest) do
				if nm:find("=", 1, true) then -- (NAME=… can't be an environment function)
					io.stderr:write("curse: " .. cmd .. ": " .. nm .. ": cannot export\n")
					allok = false
				elseif sh.functions[nm] then
					sh.fexport = sh.fexport or {}
					sh.fexport[nm] = not (unexport or plusx) or nil
					rt.fexport_sync(sh, nm)
				else
					io.stderr:write("curse: " .. cmd .. ": " .. nm .. ": not a function\n")
					allok = false
				end
			end
			sh.status = allok and 0 or 1
		elseif funcnames or funcbody then
			-- declare -F [name…] lists `declare -f NAME`; -f prints bodies (not
			-- reconstructed here) — either way the exit status signals existence.
			-- With no names, an exported function's listing is marked `declare -fx NAME`,
			-- and -x (or `export -f`) lists only the exported ones.
			local names, allok, named = rest, true, #rest > 0
			local fx = sh.fexport or {}
			if #names == 0 then
				names = {}
				for k in pairs(sh.functions) do
					if not (doexport or cmd == "export") or fx[k] then
						names[#names + 1] = k
					end
				end
				table.sort(names)
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
						if not named and fx[nm] then
							sh:echo("declare -fx " .. nm)
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
							sh:echo(named and nm or ((fx[nm] and "declare -fx " or "declare -f ") .. nm))
						end
					end
				else
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
			local roattr = (cmd == "readonly") or rattr
			-- `declare`/`typeset` in a function make each name LOCAL (like `local`),
			-- unless -g; `export`/`readonly` always act on the global var (bash).
			local localize = (cmd == "declare" or cmd == "typeset") and not gflag and (sh.calldepth or 0) > 0
			local allok = true
			for _, a in ipairs(rest) do
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
				local nm, op, val = a:match("^([%a_][%w_]*)(%+?=)(.*)$")
				if nm and sh.vars[sh:deref(nm)] and sh.vars[sh:deref(nm)].ro then
					-- reassigning a readonly variable is rejected (bash: `typeset +r r=v` too)
					io.stderr:write("curse: " .. cmd .. ": " .. nm .. ": readonly variable\n")
					allok = false
				elseif nm and (aattr or assoc) and val:sub(1, 1) == "(" and val:sub(-1) == ")" then
					-- dynamic array literal: `declare -a "x=(1 2 3)"` (the -a/-A flag is required)
					if localize then
						sh:localVar(nm)
					end
					if assoc then
						sh:declare_assoc(nm)
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
				elseif nm then
					if localize then
						sh:localVar(nm)
					end
					local ap = (op == "+=")
					if nref then
						if not sh:make_nameref(nm, val) then
							io.stderr:write(
								"curse: "
									.. cmd
									.. ": `"
									.. (val or "")
									.. "': invalid variable name for name reference\n"
							)
							allok = false
						end
					elseif iattr then -- declare -i: arith-evaluate the value, mark integer
						if ap then
							sh:aset(nm, sh:aget(nm) + eval(sh, P.arith(val)))
						else
							sh:aset(nm, eval(sh, P.arith(val)))
						end
						sh.vars[nm].int = true
					elseif lattr or uattr or cattr then -- declare -l/-u/-c: case attribute (set_str folds)
						sh.vars[nm] = sh.vars[nm] or {}
						sh.vars[nm].lower = lattr or nil
						sh.vars[nm].upper = uattr or nil
						sh.vars[nm].cap = cattr or nil
						sh:set_str(nm, ap and (sh:get(nm) .. val) or val)
					else
						local eb = sh.vars[sh:deref(nm)]
						if eb and eb.arr and not eb.assoc and not assoc then -- scalar (+)= on an indexed array -> element 0
							sh:array_set(nm, array_key(sh, nm, "0"), val, ap)
						else
							if assoc then
								sh:declare_assoc(nm)
							end
							sh:set_str(nm, ap and (sh:get(nm) .. val) or val)
						end
					end
					local bb = sh.vars[sh:deref(nm)]
					if roattr and bb and not nref then
						bb.ro = true
					end -- bash ignores -r when -n is given
					-- export attribute: -n / +x clear it (keep the value), else export sets it.
					-- A nameref exports the nameref BOX itself, and its env value is the TARGET
					-- NAME it points at (`declare -nx ref=x` -> env ref="x"), not the deref value.
					local xb = nref and sh.vars[nm] or bb
					local xval = nref and (xb and xb.s or "") or sh:get(nm)
					if xb then
						if unexport or plusx then
							xb.exported = nil
							C.unsetenv(nm)
						elseif doexport or sh.opt_a then
							xb.exported = true
							C.setenv(nm, xval, 1)
						end
					end
				elseif a:match("^[%a_][%w_]*$") then
					if localize then
						sh:localVar(a)
					end
					if plusn then
						sh:unref(a)
					elseif nref then
						if not sh:make_nameref(a) then -- existing value is an invalid nameref target
							io.stderr:write(
								"curse: "
									.. cmd
									.. ": `"
									.. (sh.vars[a] and sh.vars[a].s or "")
									.. "': invalid variable name for name reference\n"
							)
							allok = false
						end
					elseif iattr then
						sh.vars[a] = sh.vars[a] or {}
						sh.vars[a].int = true
					elseif lattr or uattr or cattr then
						sh.vars[a] = sh.vars[a] or {}
						sh.vars[a].lower = lattr or nil
						sh.vars[a].upper = uattr or nil
						sh.vars[a].cap = cattr or nil
					elseif assoc and cmd ~= "readonly" then -- bash forbids converting an existing indexed array to associative
						-- (`readonly -A` with NO value does NOT apply the attribute — bash then
						-- shows just `declare -r`, so let it fall through to the plain-var branch)
						local b = sh.vars[sh:deref(a)]
						if b and b.arr and not b.assoc then
							io.stderr:write(
								"curse: " .. cmd .. ": " .. a .. ": cannot convert indexed to associative array\n"
							)
							allok = false
						else
							local fresh = b == nil or (b.arr == nil and b.s == nil and b.n == nil)
							sh:declare_assoc(a)
							if fresh then
								sh.vars[sh:deref(a)].empty_decl = true
							end -- declared, never assigned
						end
					elseif aattr and cmd ~= "readonly" then -- `declare -a`: mark an (empty) indexed array; convert a scalar to [0]
						local b = sh.vars[a] or {}
						if b.assoc then -- …and the reverse conversion is forbidden too
							io.stderr:write(
								"curse: " .. cmd .. ": " .. a .. ": cannot convert associative to indexed array\n"
							)
							allok = false
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
					if roattr and bb and not nref then
						bb.ro = true
					end -- bash ignores -r when -n is given
					if bb then
						if unexport or plusx then
							bb.exported = nil
							C.unsetenv(a)
						elseif doexport then
							bb.exported = true -- `export U` defers the env until U gets a value (bash)
							if bb.s ~= nil or bb.n ~= nil then
								C.setenv(a, sh:get(a), 1)
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
					end
					-- bash creates the element for declare/typeset/local, but NOT via a
					-- deferred `readonly a[i]=v` / `export a[i]=v` (those fail, status 1).
					if anm and (cmd == "declare" or cmd == "typeset") then
						if localize then
							sh:localVar(anm)
						end
						sh:array_set(anm, array_key(sh, anm, sub), aval, aop == "+=")
						local bb = sh.vars[sh:deref(anm)]
						if roattr and bb then
							bb.ro = true
						end
					else
						allok = false
					end
				else -- a token that isn't a valid name (`FOO-BAR`, `1x`, …): bash errors
					io.stderr:write("curse: " .. cmd .. ": `" .. a .. "': not a valid identifier\n")
					allok = false
				end
				::continue::
			end
			sh.status = allok and 0 or 1
		end
	end
end
