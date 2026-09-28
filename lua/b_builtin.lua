-- Lazily-loaded builtin feature module (see BUILTIN_LAZY in interp.lua). Its own
-- module -- no grab bags -- so a script loads only the builtin it uses. Internals
-- it needs are aliased from interp's _int under their interp names.
local rt = require("runtime")
local I = require("interp")._int
local exec_simple = I.exec_simple

return function(sh, cmd, args, hook, tcb)
	if cmd == "builtin" then
		-- builtin [--] NAME args: run NAME only if it's an actual shell builtin.
		local c, _, j = rt.getopt(sh, "builtin", args, "", 2) -- (no options)
		if c then
			return
		end
		if args[j] == nil then
			sh.status = 0
		elseif rt.builtin_enabled(sh, args[j]) then
			-- (a builtin disabled with `enable -n` isn't one: bash's find_shell_builtin)
			-- (not a special builtin through `builtin`: its errors aren't fatal — execute_cmd)
			local svc = sh.via_command
			sh.via_command = true
			local ok, e = pcall(exec_simple, sh, rt.tslice(args, j), hook, true) -- skip functions
			sh.via_command = svc
			if not ok then
				error(e, 0)
			end
		else
			io.stderr:write("curse: builtin: " .. args[j] .. ": not a shell builtin\n")
			sh.status = 1
		end
	end
end
