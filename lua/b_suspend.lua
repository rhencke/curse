-- Lazily-loaded `suspend` builtin (see BUILTIN_LAZY in interp.lua), as bash's suspend.def:
-- stop the shell with SIGSTOP — only under job control unless -f (and never a resident
-- daemon worker, whose client would just hang).
local rt = require("runtime")

return function(sh, cmd, args)
	local force, j, sp, f, _ = false, 2
	repeat
		f, _, j, sp = rt.getopt(sh, "suspend", args, "f", j, sp)
		if f == "?" then
			return
		end
		force = force or f == "f"
	until not f
	if args[j] ~= nil then
		rt.too_many(sh, "suspend")
	end
	if not force and not sh.opt_m then
		io.stderr:write("curse: suspend: cannot suspend: no job control\n")
		sh.status = 1
		return
	end
	sh.status = 0
	if not rt.daemon_worker then
		local C = require("ffi").C
		C.kill(C.getpid(), 19) -- SIGSTOP; a SIGCONT resumes here
	end
end
