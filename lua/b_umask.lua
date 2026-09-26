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
		local sflag, pflag, badflag, pos = false, false, false, {}
		local j = 2
		while args[j] and args[j]:sub(1, 1) == "-" and #args[j] > 1 do
			local a = args[j]
			j = j + 1
			if a == "--" then
				break
			elseif a == "--help" and not badflag then -- (GETOPT_HELP: the builtin's help)
				return rt.builtin_help(sh, "umask")
			end
			for k = 2, #a do -- (combined flags; the first bad letter is reported)
				local f = a:sub(k, k)
				if f == "S" then
					sflag = true
				elseif f == "p" then
					pflag = true
				elseif not badflag then
					badflag = "-" .. f
				end
			end
		end
		for k = j, #args do
			pos[#pos + 1] = args[k]
		end
		local cur = tonumber(C.umask(0)) % 512
		C.umask(cur)
		if badflag then
			io.stderr:write("curse: umask: " .. badflag .. ": invalid option\numask: usage: umask [-p] [-S] [mode]\n")
			sh.status = 2 -- a usage error (bash)
		elseif #pos == 0 then -- bash ignores extra args; it uses only the first MODE
			local body = sflag and umask_symbolic(cur) or string.format("%04o", cur)
			sh:echo(pflag and ("umask " .. (sflag and "-S " or "") .. body) or body)
			sh.status = 0
		else
			local m, err = parse_umask(pos[1], cur)
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
