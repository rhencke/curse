-- Lazily-loaded builtin feature module (see BUILTIN_LAZY in interp.lua). Its own
-- module -- no grab bags -- so a script loads only the builtin it uses. Internals
-- it needs are aliased from interp's _int under their interp names.
local rt = require("runtime")
local I = require("interp")._int
local job_reap = I.job_reap

-- printable_job_status (jobs.c): Running, Done / Exit N (posix: Done(N)), or the signal
local function job_state(sh, j)
	if not j.done then
		return rt.L("Running")
	elseif j.sig then
		return I.SIGDESC[j.sig] and rt.Llibc(I.SIGDESC[j.sig]) or rt.L("Signal %d", j.sig)
	elseif (j.status or 0) == 0 then
		return rt.L("Done")
	end
	return rt.L(sh.opt_posix and "Done(%d)" or "Exit %d", j.status)
end

return function(sh, cmd, args, hook, tcb)
	if cmd == "jobs" then
		-- jobs [-lnprs] [jobspec…] | jobs -x cmd args (jobs.def): list the job table —
		-- `[N]± STATE  command`; a job listed once it has ended leaves the table (that is a
		-- script's only notice of it). -n: only jobs changed since last listed; -r running
		-- only; -s stopped only (nothing stops here).
		local form, state, execute = nil, nil, false
		local k = 2
		while args[k] and args[k]:match("^%-.") do
			local a = args[k]
			if a == "--" then
				k = k + 1
				break
			elseif a == "--help" then
				return rt.builtin_help(sh, "jobs")
			end
			for ci = 2, #a do
				local f = a:sub(ci, ci)
				if f == "l" or f == "p" or f == "n" then
					form = f
				elseif f == "x" then
					if form then
						io.stderr:write("curse: jobs: no other options allowed with `-x'\n")
						sh.status = 1
						return
					end
					execute = true
				elseif f == "r" or f == "s" then
					state = f
				else
					return rt.bad_option(sh, "jobs", "-" .. f)
				end
			end
			k = k + 1
		end
		if execute then -- jobs -x CMD ARGS: run CMD with each jobspec as its pid
			local t = {}
			for i = k, #args do
				local a = args[i]
				local jb = a:sub(1, 1) == "%" and I.job_resolve(sh, a, "jobs") -- (a bad one stays as is)
				t[#t + 1] = jb and tostring(jb.pid) or a
			end
			if #t == 0 then
				sh.status = 0
				return
			end
			return I.exec_simple(sh, t, hook)
		end
		for _, j in ipairs(sh.jobs or {}) do -- WNOHANG refresh
			if not j.gone then
				job_reap(sh, j, true)
			end
		end
		local function show(j)
			local st = job_state(sh, j)
			if form == "p" then
				sh:echo(tostring(j.pid))
			elseif form ~= "n" or j.notified ~= st then
				local mark = (j == sh.job_cur) and "+" or (j == sh.job_prev and "-" or " ")
				local amp = j.done and "" or " &"
				local lead = form == "l" and (" %5d "):format(j.pid) or "  "
				sh:echo(("[%d]%s%s%s%s%s%s"):format(j.id, mark, lead, st, (" "):rep(math.abs(24 - #st)), j.cmd or "", amp))
			end
			j.notified = st
		end
		local shown, status = {}, 0
		if k > #args then
			local list = {}
			for _, j in ipairs(sh.jobs or {}) do
				if not j.gone then
					if j.waited and j.done then -- (notified already — by `wait ID` or a listing)
						rt.job_delete(sh, j)
					elseif state == nil or (state == "r" and not j.done) then
						list[#list + 1] = j
					end
				end
			end
			table.sort(list, function(a, b)
				return a.id < b.id
			end)
			for _, j in ipairs(list) do
				show(j)
				shown[#shown + 1] = j
			end
		else
			for i = k, #args do
				local jb, dup = I.job_resolve(sh, args[i], "jobs")
				if jb then
					show(jb)
					shown[#shown + 1] = jb
				elseif not dup then -- (an ambiguous one isn't a failure: bash)
					io.stderr:write("curse: jobs: " .. args[i] .. ": no such job\n")
					status = 1
				end
			end
		end
		for _, j in ipairs(shown) do -- (listed after it ended: that was its notice)
			if j.done then
				if k > #args then -- (a full listing marks it notified: the next one deletes it)
					rt.job_waited(sh, j)
				else
					rt.job_delete(sh, j)
				end
			end
		end
		sh.status = status
	end
end
