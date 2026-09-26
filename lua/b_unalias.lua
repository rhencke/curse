-- Lazily-loaded builtin feature module (see BUILTIN_LAZY in interp.lua). Its own
-- module -- no grab bags -- so a script loads only the builtin it uses.

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
