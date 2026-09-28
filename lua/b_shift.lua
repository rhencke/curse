-- Lazily-loaded builtin feature module (see BUILTIN_LAZY in interp.lua). Its own
-- module -- no grab bags -- so a script loads only the builtin it uses.
local rt = require("runtime")

return function(sh, cmd, args, hook, tcb)
	if cmd == "shift" then
		-- bash's shift.def: an optional `--`, at most one legal_number operand
		local a = 2
		if args[a] == "--" then
			a = 3
		end
		local w = args[a]
		local nn = 1
		if w ~= nil then -- (get_numeric_arg: the number first, then no_args on the rest)
			nn = rt.legal_number(w)
			if not nn then
				io.stderr:write("curse: shift: " .. w .. ": numeric argument required\n")
				sh.status = 1
				return
			end
		end
		if w ~= nil and args[a + 1] ~= nil then -- (too many: the rest of the line is abandoned)
			rt.too_many(sh, "shift") -- (bash's no_args: DISCARD)
		end
		if nn < 0 or nn > sh.nparams then
			-- (past $#: silent unless shift_verbose — or posix mode, which sets it too)
			if nn < 0 or sh.shopt.shift_verbose or sh.opt_posix then
				io.stderr:write("curse: shift: " .. (w and w .. ": " or "") .. "shift count out of range\n")
			end
			sh.status = 1
			return
		end
		for k = 1, sh.nparams - nn do
			sh.params[k] = sh.params[k + nn]
		end
		for k = sh.nparams - nn + 1, sh.nparams do
			sh.params[k] = nil
		end
		sh.nparams = sh.nparams - nn
		sh.status = 0
	end
end
