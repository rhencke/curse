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
	if cmd == "printf" then
		-- printf [-v VAR] FMT [ARGS…] — native, bash-compatible.
		-- options (internal_getopt "v:"): each -v NAME / -vNAME is checked as it comes, and
		-- the last one wins; `--` ends them
		local target, fi = nil, 2
		while args[fi] and args[fi]:match("^%-.") do
			local a = args[fi]
			if a == "--" then
				fi = fi + 1
				break
			elseif a:sub(2, 2) ~= "v" then
				return rt.bad_option(sh, "printf", a:sub(1, 2))
			end
			local nm = a:sub(3)
			if nm == "" then
				nm = args[fi + 1]
				fi = fi + 1
			end
			if nm == nil then
				io.stderr:write("curse: printf: -v: option requires an argument\n")
				io.stderr:write(rt.usage("printf"))
				sh.status = 2
				return
			end
			if not (nm:match("^[%a_][%w_]*$") or nm:match("^[%a_][%w_]*%[.+%]$") and (rt.split_array_ref(nm)
				or rt.split_array_ref(nm, sh))) then
				io.stderr:write("curse: printf: `" .. nm .. "': not a valid identifier\n")
				sh.status = 2
				return
			end
			target = nm
			fi = fi + 1
		end
		if args[fi] == nil then
			io.stderr:write(rt.usage("printf"))
			sh.status = 2
			return
		end
		if target then
			local nsets = {}
			local res, st = sh_printf(args[fi], args, fi + 1, nsets)
			for _, ns in ipairs(nsets) do
				sh:set_str(ns[1], tostring(ns[2]))
			end
			-- target may be NAME or NAME[SUBSCRIPT]
			local nm, sub = target:match("^([%a_][%w_]*)%[(.*)%]$")
			if rt.ro_refuse(sh, nm or target:match("^[%a_][%w_]*$") or "") then
				sh.status = 1
				return
			end
			local once = nm and sh.shopt.assoc_expand_once and sh:is_assoc(nm) -- (A[]] is key ])
			if once and sub ~= "" and rt.split_array_ref(target, sh) then
				sh:array_set(nm, sub, res, false)
				sh.status = st
			elseif nm then
				if (sub == "@" or sub == "*") and not sh:is_assoc(nm) then
					io.stderr:write("curse: " .. target .. ": bad array subscript\n")
					sh.status = 1
				else
					local key = array_key(sh, nm, sub)
					if rt.neg_oob(sh, nm, key) then
						-- (a negative subscript past the start: nothing is bound)
						io.stderr:write("curse: " .. target .. ": bad array subscript\n")
						sh.status = 1
					else
						sh:array_set(nm, key, res, false)
						sh.status = st
					end
				end
			else
				sh.status = st
				local tb = sh.vars[sh:deref(target)]
				if tb and (tb.int or tb.lower or tb.upper) and not tb.arr then
					rt.assign_ref(sh, "printf", target, res) -- (bound like an assignment: bash)
				else
					rt.assign_ctx = "printf" -- (a bad nameref target fails it: status 1)
					sh:set_str(target, res)
					rt.assign_ctx = nil
				end
			end
		else
			local nsets = {}
			local res, st = sh_printf(args[fi], args, fi + 1, nsets, sh)
			for _, ns in ipairs(nsets) do
				sh:set_str(ns[1], tostring(ns[2]))
			end
			sh.out(res)
			if (sh.out == io.write or (sh.traps.SIGPIPE == "" and rt.CO_OUTS[sh.out]))
				and not rt.chkwrite(sh, "printf") then
				st = 1 -- (a failed write is reported, status 1)
			end
			sh.status = st
		end
	end
end
