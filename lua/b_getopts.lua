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
	if cmd == "getopts" then
		-- getopts OPTSTRING NAME [args…]: parse one option per call using OPTIND (+ an
		-- internal char cursor for bundled opts); sets NAME, OPTARG; status 1 when done.
		local spec, vname = args[2] or "", args[3] or "?"
		local silent = spec:sub(1, 1) == ":"
		local src_get, src_n
		if #args >= 4 then
			src_n = #args - 3
			src_get = function(k)
				return args[k + 3]
			end
		else
			src_n = sh.nparams
			src_get = function(k)
				return sh.params[k]
			end
		end
		local optind = math.max(1, math.floor(tonumber(sh:get("OPTIND")) or 1))
		local cur = sh.getopts_cur or 1
		-- A leftover OPTIND pointing past a now-shorter argument list (e.g. after a
		-- fresh `set --`) is exhausted: bash returns EOF and clamps OPTIND to
		-- nargs+1 (getopt.c: `sh_optind >= argc` -> `sh_optind = argc`, argc =
		-- nparams+1). It does NOT rescan from 1 — only an explicit OPTIND= does.
		if optind > src_n + 1 then
			optind = src_n + 1
			cur = 1
		end
		local res
		while not res do
			local word = optind <= src_n and src_get(optind) or nil
			if not word or word == "-" or word:sub(1, 1) ~= "-" then
				res = { done = true }
			elseif word == "--" then
				optind = optind + 1
				res = { done = true }
			else
				local oc = word:sub(1 + cur, 1 + cur)
				if oc == "" then
					optind = optind + 1
					cur = 1
				else
					local pos = spec:find(oc, 1, true)
					if not pos or oc == ":" then
						cur = cur + 1
						if 1 + cur > #word then
							optind = optind + 1
							cur = 1
						end
						res =
							{ opt = "?", arg = silent and oc or nil, err = not silent and ("illegal option -- " .. oc) }
					elseif spec:sub(pos + 1, pos + 1) == ":" then -- takes an argument
						local rest = word:sub(2 + cur)
						if rest ~= "" then
							sh:set_str("OPTARG", rest)
							optind = optind + 1
							cur = 1
							res = { opt = oc }
						else
							local a = (optind + 1) <= src_n and src_get(optind + 1) or nil
							if a then
								sh:set_str("OPTARG", a)
								optind = optind + 2
								cur = 1
								res = { opt = oc }
							else
								optind = optind + 1
								cur = 1
								res = silent and { opt = ":", arg = oc }
									or { opt = "?", err = "option requires an argument -- " .. oc }
							end
						end
					else -- flag, no argument
						cur = cur + 1
						if 1 + cur > #word then
							optind = optind + 1
							cur = 1
						end
						res = { opt = oc, clr = true } -- a no-arg option UNSETS OPTARG (bash)
					end
				end
			end
		end
		sh.getopts_cur = cur
		sh:set_str("OPTIND", tostring(optind))
		local valid = vname:match("^[%a_][%w_]*$") -- an invalid NAME -> status 1, var not set
		if res.done then
			if valid then
				sh:set_str(vname, "?")
			end
			sh.getopts_cur = 1
			sh.vars["OPTARG"] = nil
			sh.status = 1 -- end of options: OPTARG unset
		else
			if valid then
				sh:set_str(vname, res.opt)
			end
			if res.arg ~= nil then
				sh:set_str("OPTARG", res.arg)
			elseif res.err or res.clr then
				sh.vars["OPTARG"] = nil
			end
			if res.err then
				io.stderr:write("curse: " .. res.err .. "\n")
			end
			sh.status = valid and 0 or 1
		end
	end
end
