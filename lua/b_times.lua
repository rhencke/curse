-- Lazily-loaded builtin feature module (see BUILTIN_LAZY in interp.lua). Its own
-- module -- no grab bags -- so a script loads only the builtin it uses.
local rt = require("runtime")

return function(sh, cmd, args, hook, tcb)
	if cmd == "times" then
		if rt.getopt(sh, "times", args, "", 2) then -- (bash's no_options)
			return
		end
		-- Two lines: shell user/sys, then children user/sys, each `%dm%.3fs`.
		local dp = rt.decimal_point() -- (print_timeval: the locale's radix — 0m0,003s in de_DE)
		local function ct(s)
			local t = ("%dm%.3fs"):format(math.floor(s / 60), s % 60)
			return dp == "." and t or (t:gsub("%.", dp))
		end
		local c = os.clock()
		sh:echo(ct(c) .. " " .. ct(0))
		sh:echo(ct(0) .. " " .. ct(0))
		sh.status = 0
	end
end
