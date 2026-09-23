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
		if args[2] and args[2]:match("^%-.") and args[2] ~= "--" and args[2] ~= "-v" then
			-- (getopt: `-vNAME`, or an invalid option letter)
			local a = args[2]
			if a:sub(2, 2) ~= "v" then
				return rt.bad_option(sh, "printf", a:sub(1, 2))
			end
			local t = { "printf", "-v", a:sub(3) }
			for k = 3, #args do
				t[#t + 1] = args[k]
			end
			args = t
		end
		if args[2] == "-v" and (args[3] == nil or args[args[4] == "--" and 5 or 4] == nil) then
			if args[3] == nil then
				io.stderr:write("curse: printf: -v: option requires an argument\n")
			end
			io.stderr:write(rt.usage("printf"))
			sh.status = 2
			return
		end
		if args[2] == "-v" then
			local target = args[3]
			if target == nil then
				io.stderr:write("curse: printf: -v: option requires an argument\n")
				sh.status = 2
			else
				local nsets = {}
				local fi = args[4] == "--" and 5 or 4 -- (`printf -v VAR -- FMT …`)
				local res, st = sh_printf(args[fi] or "", args, fi + 1, nsets)
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
					if sub == "" then
						io.stderr:write("curse: printf: `" .. target .. "': bad array subscript\n")
						sh.status = 2
					elseif (sub == "@" or sub == "*") and not sh:is_assoc(nm) then
						io.stderr:write("curse: " .. target .. ": bad array subscript\n")
						sh.status = 1
					elseif not rt.split_array_ref(target) then -- (`A[]]`: brackets don't balance)
						io.stderr:write("curse: printf: `" .. target .. "': not a valid identifier\n")
						sh.status = 2
					else
						sh:array_set(nm, array_key(sh, nm, sub), res, false)
						sh.status = st
					end
				elseif target:find("%[") then -- malformed subscript like `a[`
					io.stderr:write("curse: printf: `" .. target .. "': bad array subscript\n")
					sh.status = 2
				else
					sh.status = st
					rt.assign_ctx = "printf" -- (a bad nameref target fails it: status 1)
					sh:set_str(target, res)
					rt.assign_ctx = nil
				end
			end
		else
			local fi = 2
			if args[fi] == "--" then
				fi = fi + 1
			end -- end of options
			if args[fi] == nil then
				io.stderr:write(rt.usage("printf"))
				sh.status = 2
			else
				local nsets = {}
				local res, st = sh_printf(args[fi], args, fi + 1, nsets)
				for _, ns in ipairs(nsets) do
					sh:set_str(ns[1], tostring(ns[2]))
				end
				sh.out(res)
				if sh.out == io.write then
					rt.chkwrite(sh, "printf") -- (a failed write is reported, status 1)
				end
				sh.status = st
			end
		end
	end
end
