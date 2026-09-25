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

-- sh_physpath (pathphys.c) of a RELATIVE internal cwd (`.`, `..`: a cd after getcwd
-- failed): its first char is kept as the root, `.` dropped, `..` pops what follows it
local function physrel(path)
	local r, base, i, n = path:sub(1, 1), 1, 2, #path
	while i <= n do
		local c = path:byte(i)
		local e = path:find("/", i, true) or n + 1
		local seg = path:sub(i, e - 1)
		if c == 47 or seg == "." then
			i = c == 47 and i + 1 or e
		elseif seg == ".." then
			i = e
			if #r > base then
				local k = #r
				while k > base and r:byte(k) ~= 47 do
					k = k - 1
				end
				r = r:sub(1, k > base and k - 1 or base)
			end
		else
			r = r .. (#r ~= base and "/" or "") .. seg
			i = e
		end
	end
	return r
end

return function(sh, cmd, args, hook, tcb)
	if cmd == "pwd" then
		local phys, pflag = sh.opt_P or false, false -- (set -P)
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
				pflag = pflag or phys
			end
		end
		-- cd.def: the internal cwd (not $PWD), with -P its physical form; when that can't
		-- be had -- or, in posix mode, the internal cwd isn't "." any more -- getcwd.
		local tcwd = sh:cwd()
		local out = tcwd
		if phys then
			if tcwd:byte(1) ~= 47 and tcwd ~= "" then
				out = physrel(tcwd)
			else
				out = tcwd ~= "" and sh:phys_cwd() ~= "" and rt.phys_under(sh, tcwd) or nil
			end
		end
		if out == nil or out == "" or (sh.opt_posix and not (C.curse_stat(tcwd, statbuf) == 0
			and C.curse_stat(".", statbuf2) == 0
			and ffi.cast("uint64_t *", statbuf)[0] == ffi.cast("uint64_t *", statbuf2)[0] -- st_dev @ 0
			and ffi.cast("uint64_t *", statbuf + 8)[0] == ffi.cast("uint64_t *", statbuf2 + 8)[0])) then
			sh.tcwd, out = nil, sh:phys_cwd() -- (resetpwd)
			if out == "" then
				local e = ffi.string(C.strerror(ffi.errno()))
				io.stderr:write(rt.L("%s: error retrieving current directory: %s: %s\n", "pwd",
					rt.L("getcwd: cannot access parent directories"), e))
				sh.status = 1
				return
			end
			sh.tcwd = out
		end
		sh.write_err = nil
		sh:echo(out)
		if sh.write_err and sh.out == io.write then -- (sh_chkwrite: `pwd >&-`)
			rt.chkwrite_report(sh, "pwd", sh.write_errmsg)
		end
		sh.status = sh.write_err and 1 or 0
		-- "This is dumb but posix-mandated": posix `pwd -P` sets PWD
		if sh.opt_posix and pflag then
			if rt.ro_refuse(sh, "PWD") then
				sh.status = 1
			else
				sh:set_str("PWD", out)
			end
		end
	end
end
