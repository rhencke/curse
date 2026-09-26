-- Lazily-loaded builtin feature module (see BUILTIN_LAZY in interp.lua). Its own
-- module -- no grab bags -- so a script loads only the builtin it uses. Internals
-- it needs are aliased from interp's _int under their interp names.
local rt = require("runtime")
local I = require("interp")._int
local exec_simple = I.exec_simple
local BUILTINS = I.BUILTINS

return function(sh, cmd, args, hook, tcb)
	if cmd == "builtin" then
		-- builtin [--] NAME args: run NAME only if it's an actual shell builtin.
		local j = 2
		if args[j] == "--" then
			j = j + 1
		elseif args[j] and args[j]:match("^%-.") then -- (no options)
			return rt.bad_option(sh, "builtin", args[j]:sub(1, 2))
		end
		if args[j] == nil then
			sh.status = 0
		elseif BUILTINS[args[j]] and not (sh.disabled_builtins and sh.disabled_builtins[args[j]]) then
			-- (a builtin disabled with `enable -n` isn't one: bash's find_shell_builtin)
			-- (not a special builtin through `builtin`: its errors aren't fatal — execute_cmd)
			local svc = sh.via_command
			sh.via_command = true
			local ok, e = pcall(exec_simple, sh, { unpack(args, j) }, hook, true) -- skip functions
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
