-- Lazily-loaded builtin feature module (see BUILTIN_LAZY in runtime.lua): `fg` / `bg`.
local rt = require("runtime")
local I = require("interp")._int
local job_resolve, job_reap, SIGDESC = I.job_resolve, I.job_reap, I.SIGDESC

-- disown [-ahr] [jobspec|pid …]: drop jobs from the table (so `jobs`/`wait` forget them);
-- -h only marks them (nothing here sends SIGHUP), -a all jobs, -r only running ones.
local function disown(sh, args)
	local all, running, honly, j, sp, c, _ = false, false, false, 2
	repeat -- (internal_getopt "ahr")
		c, _, j, sp = rt.getopt(sh, "disown", args, "ahr", j, sp)
		if c == "?" then
			return
		end
		all, running, honly = all or c == "a", running or c == "r", honly or c == "h"
	until not c
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
			jb = job_resolve(sh, spec, "disown")
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
		sh.disowned = sh.disowned or {}
		for _, jb in ipairs(victims) do
			gone[jb], jb.gone = true, true
			-- (delete_job's bgp_add: `wait PID` answers from bgpids with the status it had
			-- when disowned — 0 while it was still running — and doesn't wait)
			sh.disowned[jb.pid] = jb.done and jb.status or 0
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

-- fg_bg + start_job (jobs.c): SPEC's job to the foreground (print its command, continue it
-- if stopped, wait for it: its status) or the background (a stopped one: print `[N]+ cmd &`,
-- continue it; a running one is "already in background", status 0). Returns the status.
local function fg_bg(sh, cmd, spec, fore)
	local j, dup = job_resolve(sh, spec or "%+")
	if not j then -- (get_job_spec's NO_JOB: sh_badjob, `current` for no operand; DUP_JOB said so)
		if not dup then
			io.stderr:write("curse: " .. cmd .. ": " .. (spec or "current") .. ": no such job\n")
		end
		return 1
	end
	if j.nojc then -- (started while `set -m` was off: bash won't foreground/background it)
		io.stderr:write("curse: " .. cmd .. ": job " .. j.id .. " started without job control\n")
		return 1
	end
	if (sh.in_subprogram or 0) > 0 or (sh.iso_ctx and sh.iso_ctx[1]) then
		-- (a subshell lists its parent's jobs, but can't start one: start_job's refusal)
		io.stderr:write("curse: " .. cmd .. ": no current jobs\n")
		return 1
	end
	local state = rt.job_state(j)
	if state == "dead" then
		io.stderr:write("curse: " .. cmd .. ": job has terminated\n")
		return 1
	end
	if not fore then
		sh.last_bg_pid = tostring(j.pid) -- (last_asynchronous_pid = the job's process group)
		if state == "running" then -- (XPG6: not an error)
			io.stderr:write("curse: bg: job " .. j.id .. " already in background\n")
			return 0
		end
		-- (POSIX: bg doesn't mark the current/previous job)
		local mark = sh.opt_posix and " " or (j == sh.job_cur and "+ " or (j == sh.job_prev and "- " or " "))
		sh.out(("[%d]%s%s &\n"):format(j.id, mark, j.cmd or ""))
	else
		rt.set_current_job(sh, j)
		sh.out((j.cmd or "") .. "\n")
	end
	io.flush()
	if state == "stopped" then -- continue it: its processes, and a suspended task
		for _, pid in ipairs(rt.job_procs(j)) do
			require("ffi").C.kill(pid, 18)
		end
		rt.job_set_running(sh, j)
	end
	if not fore then
		rt.job_reset_current(sh)
		return 0
	end
	local st = job_reap(sh, j) or 127
	if j.sig and SIGDESC[j.sig] then
		io.stderr:write(rt.Llibc(SIGDESC[j.sig]) .. "\n")
	end
	if j.done then -- (a foreground job that has ended is notified: it leaves the table)
		rt.job_delete(sh, j)
	end
	return st
end

return function(sh, cmd, args)
	if cmd == "disown" then
		return disown(sh, args)
	end
	-- fg/bg [jobspec] (fg_bg.def): the job (default: the current one, %+). Without job
	-- control (`set -m` off) bash refuses both; then neither takes an option (no_options).
	-- (a subshell / pipeline stage starts without job control — a $(…) keeps it — until
	-- its own `set -m`: rt.job_control_on)
	if not rt.job_control_on(sh) then
		io.stderr:write("curse: " .. cmd .. ": no job control\n")
		sh.status = 1
		return
	end
	local c, _, k = rt.getopt(sh, cmd, args, "", 2)
	if c == "?" then
		return
	end
	rt.jobs_poll(sh) -- (what SIGCHLD would have told bash by now: ended, stopped, continued)
	if cmd == "bg" then -- every operand in turn (none: the current job); fails if any did
		local st = 0
		repeat
			if fg_bg(sh, cmd, args[k], false) ~= 0 then
				st = 1
			end
			k = k + 1
		until args[k] == nil
		sh.status = st
		return
	end
	sh.status = fg_bg(sh, cmd, args[k], true)
end
