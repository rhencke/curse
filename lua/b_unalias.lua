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
	if cmd == "unalias" then
		local ok, j, all = true, 2, false
		while args[j] and args[j]:match("^%-.") do -- (internal_getopt "a")
			if args[j] == "--" then
				j = j + 1
				break
			elseif args[j] == "--help" then -- (CASE_HELPOPT: the builtin's help, status 2)
				require("b_help")(sh, "help", { "help", "unalias" }, hook, tcb)
				sh.status = 2
				return
			end
			local bad = args[j]:match("^%-a*([^a])")
			if bad then -- an unknown option (`--Z`: the `-`): usage error (status 2)
				io.stderr:write("curse: unalias: -" .. bad .. ": invalid option\n")
				io.stderr:write("unalias: usage: unalias [-a] name [name ...]\n")
				sh.status = 2
				return
			end
			all, j = true, j + 1
		end
		if all then
			sh.aliases = {}
			sh.alias_gen = (sh.alias_gen or 0) + 1 -- (compiled fragments key on the table)
		elseif not args[j] then
			io.stderr:write("unalias: usage: unalias [-a] name [name ...]\n")
			sh.status = 2
			return
		else
			for k = j, #args do
				if sh.aliases[args[k]] then
					sh.aliases[args[k]] = nil
					sh.alias_gen = (sh.alias_gen or 0) + 1
				else
					io.stderr:write("curse: unalias: " .. args[k] .. ": not found\n")
					ok = false
				end
			end
		end
		sh.status = ok and 0 or 1
	end
end
