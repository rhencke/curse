-- Lazily-loaded builtin feature module (see BUILTIN_LAZY in interp.lua). Its own
-- module -- no grab bags -- so a script loads only the builtin it uses.
local rt = require("runtime")

return function(sh, cmd, args, hook, tcb)
	if cmd == "alias" then
		-- alias [name[=value] …]: define or print aliases.
		local ok, listall, j, sp, c, _ = true, false, 2
		repeat -- (internal_getopt "p": `-p` lists them all, then any operands are handled)
			c, _, j, sp = rt.getopt(sh, "alias", args, "p", j, sp)
			if c == "?" then
				return
			end
			listall = listall or c == "p"
		until not c
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
