-- Lazily-loaded builtin feature module (see BUILTIN_LAZY in runtime.lua): `fg` / `bg`.
local I = require("interp")._int
local job_resolve, job_reap, SIGDESC = I.job_resolve, I.job_reap, I.SIGDESC

-- disown [-ahr] [jobspec|pid …]: drop jobs from the table (so `jobs`/`wait` forget them);
-- -h only marks them (nothing here sends SIGHUP), -a all jobs, -r only running ones.
local function disown(sh, args)
	local all, running, honly, j = false, false, false, 2
	while args[j] and args[j]:match("^%-.") and args[j] ~= "--" do -- (`--Z`: the `-` is the bad option)
		if args[j] == "--help" then -- (CASE_HELPOPT: the builtin's help, status 2)
			require("b_help")(sh, "help", { "help", "disown" })
			sh.status = 2
			return
		end
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
		sh.disowned = sh.disowned or {}
		for _, jb in ipairs(victims) do
			gone[jb] = true
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

return function(sh, cmd, args)
	if cmd == "disown" then
		return disown(sh, args)
	end
	-- fg/bg [jobspec]: the job (default: the current one, %+). Without job control
	-- (`set -m` off) bash refuses both.
	-- (a subshell / pipeline stage starts without job control — a $(…) keeps it — until
	-- its own `set -m`)
	local nojc, st = not sh.opt_m, sh.iso_ctx
	for k = st and #st or 0, 1, -1 do
		if not st[k].cs then
			nojc = nojc or st[k].mgen == sh.m_gen
			break
		end
	end
	if nojc then
		io.stderr:write("curse: " .. cmd .. ": no job control\n")
		sh.status = 1
		return
	end
	local spec = args[2] or "%+"
	local j = job_resolve(sh, spec)
	if not j or j.done then -- (get_job_spec's NO_JOB: sh_badjob, `current` for no operand)
		io.stderr:write("curse: " .. cmd .. ": " .. (args[2] or "current") .. ": no such job\n")
		sh.status = 1
		return
	end
	if (sh.in_subprogram or 0) > 0 or (sh.iso_ctx and sh.iso_ctx[1]) then
		-- (a subshell lists its parent's jobs, but can't start one: start_job's refusal)
		io.stderr:write("curse: " .. cmd .. ": no current jobs\n")
		sh.status = 1
		return
	end
	if j.nojc then -- (started while `set -m` was off: bash won't foreground/background it)
		io.stderr:write("curse: " .. cmd .. ": job " .. j.id .. " started without job control\n")
		sh.status = 1
		return
	end
	if cmd == "bg" then -- nothing stops our jobs, so it's already running (start_job: status 0)
		io.stderr:write("curse: bg: job " .. j.id .. " already in background\n")
		sh.status = 0
		return
	end
	-- fg: print the job's command line, then wait for it; its status is fg's
	sh.out((j.cmd or "") .. "\n")
	io.flush()
	sh.status = job_reap(sh, j) or 127
	if j.sig and SIGDESC[j.sig] then
		io.stderr:write(require("runtime").Llibc(SIGDESC[j.sig]) .. "\n")
	end
end
