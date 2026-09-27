-- Lazily-loaded builtin feature module (see BUILTIN_LAZY in interp.lua). Its own
-- module -- no grab bags -- so a script loads only the builtin it uses.
local rt = require("runtime")

return function(sh, cmd, args, hook, tcb)
	if cmd == "unalias" then
		local ok, all, j, sp, c, _ = true, false, 2
		repeat -- (internal_getopt "a")
			c, _, j, sp = rt.getopt(sh, "unalias", args, "a", j, sp)
			if c == "?" then
				return
			end
			all = all or c == "a"
		until not c
		if all then
			sh.aliases = {}
			sh.alias_gen = (sh.alias_gen or 0) + 1 -- (compiled fragments key on the table)
		elseif not args[j] then
			io.stderr:write(rt.usage("unalias"))
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
