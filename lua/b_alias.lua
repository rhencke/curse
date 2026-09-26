-- Lazily-loaded builtin feature module (see BUILTIN_LAZY in interp.lua). Its own
-- module -- no grab bags -- so a script loads only the builtin it uses.
local rt = require("runtime")

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
			elseif a == "--help" then -- (GETOPT_HELP: the builtin's help, status 2)
				return rt.builtin_help(sh, "alias")
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
			sh:echo((reuse and (k:sub(1, 1) == "-" and "alias -- " or "alias ") or "") .. k .. "="
				.. (v:find("'", 1, true) and rt.sh_single_quote(v) or "'" .. v .. "'"))
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
