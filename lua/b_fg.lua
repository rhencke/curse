-- Lazily-loaded builtin feature module (see BUILTIN_LAZY in runtime.lua): `fg` / `bg`.
local M = require("interp")
local I = M._int
local job_resolve, job_reap, SIGDESC = I.job_resolve, I.job_reap, I.SIGDESC

-- disown [-ahr] [jobspec|pid …]: drop jobs from the table (so `jobs`/`wait` forget them);
-- -h only marks them (nothing here sends SIGHUP), -a all jobs, -r only running ones.
local function disown(sh, args)
	local all, running, honly, j = false, false, false, 2
	while args[j] and args[j]:match("^%-%a+$") do
		for f in args[j]:sub(2):gmatch(".") do
			if f == "a" then
				all = true
			elseif f == "r" then
				running = true
			elseif f == "h" then
				honly = true
			else
				io.stderr:write("curse: disown: -" .. f .. ": invalid option\n")
				io.stderr:write("disown: usage: disown [-h] [-ar] [jobspec ... | pid ...]\n")
				sh.status = 2
				return
			end
		end
		j = j + 1
	end
	if args[j] == "--" then
		j = j + 1
	end
	local victims, status = {}, 0
	if all or running then
		if not args[j] then
			for _, jb in ipairs(sh.jobs or {}) do
				if not (running and jb.done) then
					victims[#victims + 1] = jb
				end
			end
		end
	end
	if not args[j] and not (all or running) then
		local jb = job_resolve(sh, "%+")
		if not jb then
			io.stderr:write("curse: disown: current: no such job\n")
			sh.status = 1
			return
		end
		victims[1] = jb
	end
	for k = j, #args do
		local spec, jb = args[k], nil
		if spec:sub(1, 1) == "%" then
			jb = job_resolve(sh, spec)
		elseif spec:match("^%d+$") then
			for _, x in ipairs(sh.jobs or {}) do
				if x.pid == tonumber(spec) then
					jb = x
				end
			end
		end
		if jb then
			victims[#victims + 1] = jb
		else
			io.stderr:write("curse: disown: " .. spec .. ": no such job\n")
			status = 1
		end
	end
	if not honly then
		local gone = {}
		for _, jb in ipairs(victims) do
			gone[jb] = true
		end
		local keep = {}
		for _, jb in ipairs(sh.jobs or {}) do
			if not gone[jb] then
				keep[#keep + 1] = jb
			end
		end
		sh.jobs = keep
		require("runtime").job_reset_current(sh)
		if sh.bg_pids then -- (and a plain `wait` no longer waits for them)
			local kp = {}
			for _, pid in ipairs(sh.bg_pids) do
				local drop = false
				for jb in pairs(gone) do
					drop = drop or jb.pid == pid
				end
				if not drop then
					kp[#kp + 1] = pid
				end
			end
			sh.bg_pids = kp
		end
	end
	sh.status = status
end

return function(sh, cmd, args)
	if cmd == "disown" then
		return disown(sh, args)
	end
	-- fg/bg [jobspec]: the job (default: the current one, %+). Without job control
	-- (`set -m` off) bash refuses both.
	if not sh.opt_m then
		io.stderr:write("curse: " .. cmd .. ": no job control\n")
		sh.status = 1
		return
	end
	local spec = args[2] or "%+"
	local j = job_resolve(sh, spec)
	if (sh.in_subprogram or 0) > 0 or (sh.iso_ctx and sh.iso_ctx[1]) then
		j = nil -- (a subshell lists its parent's jobs, but none is ITS current job: bash)
	end
	if not j or j.done then
		local cur = not args[2] or args[2] == "%%" or args[2] == "%+"
		io.stderr:write("curse: " .. cmd .. ": " .. (cur and "no current jobs" or (args[2] .. ": no such job")) .. "\n")
		sh.status = 1
		return
	end
	if j.nojc then -- (started while `set -m` was off: bash won't foreground/background it)
		io.stderr:write("curse: " .. cmd .. ": job " .. j.id .. " started without job control\n")
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
