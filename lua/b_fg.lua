-- Lazily-loaded builtin feature module (see BUILTIN_LAZY in runtime.lua): `fg` / `bg`.
local M = require("interp")
local I = M._int
local job_resolve, job_reap, SIGDESC = I.job_resolve, I.job_reap, I.SIGDESC

return function(sh, cmd, args)
	-- fg/bg [jobspec]: the job (default: the current one, %+). Without job control
	-- (`set -m` off) bash refuses both.
	if not sh.opt_m then
		io.stderr:write("curse: " .. cmd .. ": no job control\n")
		sh.status = 1
		return
	end
	local spec = args[2] or "%+"
	local j = job_resolve(sh, spec)
	if not j or j.done then
		io.stderr:write("curse: " .. cmd .. ": " .. (args[2] or "current") .. ": no such job\n")
		sh.status = 1
		return
	end
	if cmd == "bg" then -- nothing stops our jobs, so it's already running: just report it
		sh.out(("[%d]+ %s &\n"):format(j.id, j.cmd or ""))
		sh.status = 0
		return
	end
	-- fg: print the job's command line, then wait for it; its status is fg's
	sh.out((j.cmd or "") .. "\n")
	io.flush()
	sh.status = job_reap(sh, j) or 127
	if j.sig and SIGDESC[j.sig] then
		io.stderr:write(SIGDESC[j.sig] .. "\n")
	end
end
