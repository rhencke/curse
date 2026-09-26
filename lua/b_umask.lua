-- Lazily-loaded builtin feature module (see BUILTIN_LAZY in interp.lua). Its own
-- module -- no grab bags -- so a script loads only the builtin it uses. Internals
-- it needs are aliased from interp's _int under their interp names.
local rt = require("runtime")
local I = require("interp")._int
local parse_umask, umask_symbolic = I.parse_umask, I.umask_symbolic
local C = I.C

return function(sh, cmd, args, hook, tcb)
	if cmd == "umask" then
		-- umask [-S] [MODE]: print (octal or -S symbolic) or set the file-creation mask.
		-- (options up to the first operand or `--`, bash's internal_getopt; -p prints a form
		-- that can be eval'd)
		local sflag, pflag, j, sp, c, _ = false, false, 2
		repeat
			c, _, j, sp = rt.getopt(sh, "umask", args, "Sp", j, sp)
			if c == "?" then
				return
			end
			sflag, pflag = sflag or c == "S", pflag or c == "p"
		until not c
		local mode = args[j] -- (bash ignores extra args; it uses only the first MODE)
		local cur = tonumber(C.umask(0)) % 512
		C.umask(cur)
		if not mode then
			local body = sflag and umask_symbolic(cur) or string.format("%04o", cur)
			sh:echo(pflag and ("umask " .. (sflag and "-S " or "") .. body) or body)
			sh.status = 0
		else
			local m, err = parse_umask(mode, cur)
			if m == nil then
				io.stderr:write("curse: umask: " .. err .. "\n")
				sh.status = 1
			else
				C.umask(m)
				if sflag then -- (-S with a mode shows the new mask symbolically)
					sh:echo(umask_symbolic(m))
				end
				sh.status = 0
			end
		end
	end
end
