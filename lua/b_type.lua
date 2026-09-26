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
	if cmd == "type" then
		-- type [-afptP] NAME… (bash's type.def): -t the kind, -p a file's path, -P a forced
		-- $PATH search, -a every location, -f no functions; the last of -t/-p/-P decides the
		-- output. The obsolete -type/--type, -path/--path, -all/--all are rewritten first —
		-- over the whole leading run of dash words, so `type -- -type` asks for `-t`.
		local words = {}
		for k = 2, #args do
			words[#words + 1] = args[k]
		end
		for k = 1, #words do
			local w = words[k]
			if w:sub(1, 1) ~= "-" then
				break
			end
			local f = w:sub(2)
			if f == "type" or f == "-type" then
				words[k] = "-t"
			elseif f == "path" or f == "-path" then
				words[k] = "-p"
			elseif f == "all" or f == "-all" then
				words[k] = "-a"
			end
		end
		local fl = { short = true }
		local j0 = 1
		while words[j0] and words[j0]:sub(1, 1) == "-" and #words[j0] > 1 do
			local w = words[j0]
			j0 = j0 + 1
			if w == "--" then
				break
			elseif w == "--help" then -- (GETOPT_HELP: the builtin's help, status 2)
				return rt.builtin_help(sh, "type")
			end
			for k = 2, #w do
				local f = w:sub(k, k)
				if f == "a" then
					fl.all = true
				elseif f == "f" then
					fl.nofunc = true
				elseif f == "p" then
					fl.path_only, fl.type, fl.short = true, false, false
				elseif f == "t" then
					fl.type, fl.path_only, fl.short = true, false, false
				elseif f == "P" then
					fl.path_only, fl.force, fl.type, fl.short = true, true, false, false
				else -- an unknown option: usage error, nothing looked up (bash)
					io.stderr:write("curse: type: -" .. f .. ": invalid option\n")
					io.stderr:write("type: usage: type [-afptP] name [name ...]\n")
					sh.status = 2
					return
				end
			end
		end
		local allok = true
		sh.write_err = nil
		for j = j0, #words do
			local nm = words[j]
			if not I.describe(sh, nm, fl) then
				allok = false
				if not (fl.path_only or fl.type) then
					io.stderr:write("curse: type: " .. nm .. ": not found\n")
				end
			end
		end
		sh.status = allok and 0 or 1
		if sh.out == io.write then -- (sh_chkwrite: a failed write is reported, status 1)
			if sh.write_err then
				rt.chkwrite_report(sh, "type", sh.write_errmsg)
				sh.status = 1
			elseif not rt.chkwrite(sh, "type") then
				sh.status = 1
			end
		end
	end
end
