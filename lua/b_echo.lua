-- Lazily-loaded feature: the `echo` builtin. Its own tiny module (not b_rare) so a
-- cold `echo` script loads only these ~15 lines, nothing else. See BUILTIN_LAZY.
local rt = require("runtime")

return function(sh, cmd, args, hook, tcb)
	if cmd == "echo" then
		-- echo [-neE] ARGS: -n suppresses the newline, -e interprets backslash escapes.
		local j, nonl, esc = 2, false, sh.shopt.xpg_echo and true or false -- (xpg_echo: -e by default)
		while args[j] and args[j]:match("^%-[neE]+$") do
			for ch in args[j]:sub(2):gmatch(".") do
				if ch == "n" then
					nonl = true
				elseif ch == "e" then
					esc = true
				elseif ch == "E" then
					esc = false
				end
			end
			j = j + 1
		end
		local buf = {}
		for k = j, #args do
			buf[#buf + 1] = args[k]
		end
		local s = table.concat(buf, " ")
		local stopped
		if esc then
			s, stopped = rt.ansi_unescape(s)
		end -- \c stops all output (incl. the newline)
		sh.out(s)
		if not nonl and not stopped then
			sh.out("\n")
		end
		if sh.out == io.write then
			rt.chkwrite(sh, "echo") -- (full disk, a read-only fd: reported, status 1)
		end
		sh.status = 0
	end
end
