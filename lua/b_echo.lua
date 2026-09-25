-- Lazily-loaded feature: the `echo` builtin. Its own tiny module (not b_rare) so a
-- cold `echo` script loads only these ~15 lines, nothing else. See BUILTIN_LAZY.
local rt = require("runtime")

return function(sh, cmd, args, hook, tcb)
	if cmd == "echo" then
		-- echo [-neE] ARGS: -n suppresses the newline, -e interprets backslash escapes.
		local j, nonl, esc = 2, false, sh.shopt.xpg_echo and true or false -- (xpg_echo: -e by default)
		-- (posix + xpg_echo: no options at all — `echo -n` prints `-n`, as bash)
		local opts = not (esc and sh.opt_posix)
		while opts and args[j] and args[j]:match("^%-[neE]+$") do
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
		sh.status = 0
		if sh.out == io.write or (sh.traps.SIGPIPE == "" and rt.CO_OUTS[sh.out]) then
			if not rt.chkwrite(sh, "echo") then -- (full disk, a read-only fd: reported, status 1)
				sh.status = 1
			end
		end
	end
end
