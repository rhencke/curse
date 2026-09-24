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
local statbuf, statbuf2 = I.statbuf, I.statbuf2

return function(sh, cmd, args, hook, tcb)
	if cmd == "pwd" then
		local phys = sh.opt_P or false -- (set -P)
		for j = 2, #args do -- (options until `--` or an operand; the last of -L/-P wins)
			local a = args[j]
			if a == "--" or not a:match("^%-.") then
				break
			end
			local bad = a:match("[^LP]", 2)
			if bad then
				return rt.bad_option(sh, "pwd", "-" .. bad)
			end
			for f in a:gmatch("[LP]") do
				phys = f == "P"
			end
		end
		local out
		if phys then
			out = rt.phys_under(sh, sh:pwd())
		else
			-- pwd -L (default): use $PWD only when it actually names the current directory
			-- (an absolute path with the same dev+inode as "."); a lied-about `PWD=foo`
			-- falls back to the physical cwd. But when the cwd is gone (stat "." fails),
			-- getcwd can't help either, so bash keeps $PWD as-is — only validate when the
			-- current directory is still accessible.
			out = sh:pwd()
			local same = out:sub(1, 1) == "/"
				and C.curse_stat(out, statbuf) == 0
				and C.curse_stat(".", statbuf2) == 0
				and ffi.cast("uint64_t *", statbuf)[0] == ffi.cast("uint64_t *", statbuf2)[0] -- st_dev @ 0
				and ffi.cast("uint64_t *", statbuf + 8)[0] == ffi.cast("uint64_t *", statbuf2 + 8)[0] -- st_ino @ 8
			-- fall back to the physical cwd only when it's actually available: if getcwd
			-- fails (the cwd was removed), bash keeps $PWD rather than printing nothing.
			if not same then
				local pc = sh:phys_cwd()
				if pc ~= "" then
					out = pc
				end
			end
		end
		sh:echo(out)
		sh.status = 0
	end
end
