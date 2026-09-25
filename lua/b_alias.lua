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
	if cmd == "alias" then
		-- alias [name[=value] …]: define or print aliases.
		local j, ok = 2, true
		local listall = false
		-- internal_getopt(list, "p"): only an exact `--` ends the options (`--=v` is `-`-`-`)
		while args[j] and args[j]:sub(1, 1) == "-" and #args[j] > 1 do
			local a = args[j]
			if a == "--" then
				j = j + 1
				break
			end
			for c = 2, #a do
				if a:sub(c, c) ~= "p" then -- an unknown option: usage error (status 2)
					io.stderr:write("curse: alias: -" .. a:sub(c, c) .. ": invalid option\n")
					io.stderr:write("alias: usage: alias [-p] [name[=value] ... ]\n")
					sh.status = 2
					return
				end
			end
			listall = true -- `-p`: list them all (then handle any operands)
			j = j + 1
		end
		-- print_alias: always single-quoted (sh_single_quote); the reusable `alias ` prefix
		-- (plus `-- ` before a name starting with `-`) unless posix mode without -p
		local reuse = listall or not sh.opt_posix
		local function show(k)
			local v = sh.aliases[k]
			sh:echo((reuse and (k:sub(1, 1) == "-" and "alias -- " or "alias ") or "") .. k .. "='"
				.. (v:find("'", 1, true) and v:gsub("'", "'\\''") or v) .. "'")
		end
		if listall or j > #args then -- print all, sorted
			local ns = {}
			for k in pairs(sh.aliases) do
				ns[#ns + 1] = k
			end
			table.sort(ns)
			for _, k in ipairs(ns) do
				show(k)
			end
			sh.status = 0
		end
		if j <= #args then
			for k = j, #args do
				local nm, val = args[k]:match("^([^=]+)=(.*)$")
				if nm then
					-- legal_alias_name (general.c): no shellbreak/shellxquote/shellexp char, no `/`
					if nm:find("[ \t\n()<>;&|'\"`\\$/]") then
						io.stderr:write("curse: alias: `" .. nm .. "': invalid alias name\n")
						ok = false
					else
						sh.aliases[nm] = val
						sh.alias_gen = (sh.alias_gen or 0) + 1 -- (compiled fragments key on the table)
					end
				elseif sh.aliases[args[k]] then
					show(args[k])
				else
					io.stderr:write("curse: alias: " .. args[k] .. ": not found\n")
					ok = false
				end
			end
			sh.status = ok and 0 or 1
		end
	end
end
