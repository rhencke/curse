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

-- bash's bind_variable from getopts (getopts.def): honors the target's attributes (an
-- integer evaluates, an array gets element 0, a nameref writes through); a readonly one
-- is reported. getopts_bind_variable (NAME) takes only a plain identifier: 0 / 1 / 2.
local function bind_name(sh, name, value)
	if not name:match("^[%a_][%w_]*$") then
		io.stderr:write("curse: getopts: `" .. name .. "': not a valid identifier\n")
		return 1
	end
	local b = sh.vars[name]
	if b and b.ref and (b.s == nil or b.s == "") then -- a valueless nameref: the value becomes its
		rt.assign_ctx = "getopts" -- target, and a bad one (`?`) fails the bind (getopts_bind_variable:
		local ok = sh:set_str(name, value) ~= false -- `getopts: `?': not a valid identifier', status 1)
		rt.assign_ctx = nil
		return ok and 0 or 1
	end
	return rt.assign_ref(sh, "getopts", name, value) and 0 or 2
end
local function bind_optarg(sh, value) -- value nil: OPTARG declared with no value (bash: NULL)
	if value ~= nil then -- (a refused OPTARG is only reported: getopts' status is NAME's)
		local st = sh.status
		rt.assign_ref(sh, "getopts", "OPTARG", value)
		sh.status = st
		return
	end
	local dn = sh:deref("OPTARG")
	local b = sh.vars[dn]
	if b and b.ro then
		io.stderr:write("curse: " .. dn .. ": readonly variable\n")
	elseif b and not b.arr then
		b.s, b.n = nil, nil
	elseif not b then
		sh.vars[dn] = {}
	end
end
local function unbind_optarg(sh) -- (bash's unbind_variable_noref: OPTARG itself goes)
	sh.vars.OPTARG = nil
end

return function(sh, cmd, args, hook, tcb)
	if cmd == "getopts" then
		-- getopts OPTSTRING NAME [args…] (bash's getopts.def + sh_getopt): one option per call.
		-- An option to getopts itself is a usage error (status 2); `--` ends them.
		local a0 = 2
		if args[2] == "--" then
			a0 = 3
		elseif args[2] and args[2]:match("^%-.") then
			io.stderr:write("curse: getopts: " .. args[2]:sub(1, 2) .. ": invalid option\n")
			io.stderr:write("getopts: usage: getopts optstring name [arg ...]\n")
			sh.status = 2
			return
		end
		if #args < a0 + 1 then
			io.stderr:write("getopts: usage: getopts optstring name [arg ...]\n")
			sh.status = 2
			return
		end
		local spec, vname = args[a0], args[a0 + 1]
		-- a leading `:` is silent mode (special_error), and is stripped once: the rest is
		-- sh_getopt's optstring (so in `::a:` a missing argument returns `:` — a success)
		local silent = spec:sub(1, 1) == ":"
		local optstr = silent and spec:sub(2) or spec
		local src_get, src_n
		if #args >= a0 + 2 then
			local base = a0 + 1
			src_n = #args - base
			src_get = function(k)
				return args[k + base]
			end
		else
			src_n = sh.nparams
			src_get = function(k)
				return sh.params[k]
			end
		end
		-- The scan position (sh_optind + the in-word cursor) belongs to THIS OPTIND box: a
		-- local OPTIND starts fresh and the caller's resumes on return; assigning OPTIND
		-- resets it (bash's sv_optind). Else it continues where it was, even when OPTIND
		-- couldn't be written (readonly).
		local ob = sh.vars[sh:deref("OPTIND")]
		local stt = sh.getopts_state and ob and sh.getopts_state[ob]
		local optind, cur
		if stt then
			optind, cur = stt.optind, stt.cur
		else
			optind = math.max(1, math.floor(tonumber(sh:get("OPTIND")) or 1))
			cur = 1
		end
		-- A leftover OPTIND pointing past a now-shorter argument list (e.g. after a
		-- fresh `set --`) is exhausted: bash returns EOF and clamps OPTIND to
		-- nargs+1 (getopt.c: `sh_optind >= argc` -> `sh_optind = argc`, argc =
		-- nparams+1). It does NOT rescan from 1 — only an explicit OPTIND= does.
		if optind > src_n + 1 then
			optind = src_n + 1
			cur = 1
		end
		-- (sh_getopt: `$0: illegal option -- h`, no line number; OPTERR=0 or silent mode
		-- silences it — bash's sh_opterr, atoi($OPTERR))
		local oe = sh.vars.OPTERR and sh:get("OPTERR") or ""
		local quiet = silent or (oe ~= "" and (tonumber(oe:match("^%s*([+-]?%d+)") or "0") or 0) == 0)
		local res -- { kind = "eof" | "invalid" | "missing" | "ok", opt, arg }
		while not res do
			local word = optind <= src_n and src_get(optind) or nil
			if not word or word == "-" or word:sub(1, 1) ~= "-" then
				res = { kind = "eof" }
			elseif word == "--" then
				optind = optind + 1
				res = { kind = "eof" }
			else
				local oc = word:sub(1 + cur, 1 + cur)
				if oc == "" then
					optind = optind + 1
					cur = 1
				else
					local pos = optstr:find(oc, 1, true)
					if not pos or oc == ":" then
						cur = cur + 1
						if 1 + cur > #word then
							optind = optind + 1
							cur = 1
						end
						if not quiet then
							io.stderr:write(rt.L("%s: illegal option -- %c\n", sh.argv0 or "curse", oc:byte()))
						end
						res = { kind = "invalid", opt = oc }
					elseif optstr:sub(pos + 1, pos + 1) == ":" then -- takes an argument
						local rest = word:sub(2 + cur)
						if rest ~= "" then
							optind, cur = optind + 1, 1
							res = { kind = "ok", opt = oc, arg = rest }
						elseif (optind + 1) <= src_n then
							res = { kind = "ok", opt = oc, arg = src_get(optind + 1) }
							optind, cur = optind + 2, 1
						else
							optind, cur = optind + 1, 1
							if not quiet then
								io.stderr:write(rt.L("%s: option requires an argument -- %c\n", sh.argv0 or "curse", oc:byte()))
							end
							-- (an optstring still starting with `:` makes sh_getopt return `:`: a
							-- plain success with an empty OPTARG)
							res = optstr:sub(1, 1) == ":" and { kind = "ok", opt = ":", arg = "" }
								or { kind = "missing", opt = oc }
						end
					else -- flag, no argument: OPTARG is left declared with no value
						cur = cur + 1
						if 1 + cur > #word then
							optind, cur = optind + 1, 1
						end
						res = { kind = "ok", opt = oc }
					end
				end
			end
		end
		-- OPTIND is written every call (bash: to handle `--` skipping); readonly -> reported
		local obn = sh:deref("OPTIND")
		local ob2 = sh.vars[obn]
		if ob2 and ob2.ro then
			io.stderr:write("curse: " .. obn .. ": readonly variable\n")
		else
			rt.assign_ref(sh, "getopts", "OPTIND", tostring(optind)) -- (resets the state: set after)
		end
		sh.getopts_state = sh.getopts_state or setmetatable({}, { __mode = "k" })
		local box = sh.vars[sh:deref("OPTIND")]
		if box then
			sh.getopts_state[box] = res.kind ~= "eof" and { optind = optind, cur = cur } or nil
		end
		local k = res.kind
		if k == "eof" then
			unbind_optarg(sh)
			bind_name(sh, vname, "?")
			sh.status = 1
		elseif k == "invalid" then
			sh.status = bind_name(sh, vname, "?")
			if silent then
				bind_optarg(sh, res.opt)
			else
				unbind_optarg(sh)
			end
		elseif k == "missing" then
			if silent then
				sh.status = bind_name(sh, vname, ":")
				bind_optarg(sh, res.opt)
			else
				sh.status = bind_name(sh, vname, "?")
				unbind_optarg(sh)
			end
		else
			bind_optarg(sh, res.arg)
			sh.status = bind_name(sh, vname, res.opt)
		end
	end
end
