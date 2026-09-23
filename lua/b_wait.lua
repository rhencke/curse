-- Lazily-loaded builtin feature module (see BUILTIN_LAZY in interp.lua). Its own
-- module -- no grab bags -- so a script loads only the builtin it uses. Internals
-- aliased to interp's names so the branch body is a verbatim copy.
local ffi = require("ffi")
local rt = require("runtime")
local M = require("interp")
local I = M._int
local exec_simple, expand_part_str, tilde_word_initial, file_test, sq =
	I.exec_simple, I.expand_part_str, I.tilde_word_initial, I.file_test, I.sq
local BUILTINS, KEYWORDS, SETOPTS, SHOPT_ORDER = I.BUILTINS, I.KEYWORDS, I.SETOPTS, I.SHOPT_ORDER
local parse_umask, umask_symbolic = I.parse_umask, I.umask_symbolic
local job_reap, block_sig, canon_sig, sig_order = I.job_reap, I.block_sig, I.canon_sig, I.sig_order
local find_all_in_path, name_type, SIGNUM, NUMSIG = I.find_all_in_path, I.name_type, I.SIGNUM, I.NUMSIG
local array_key, sh_printf, fd_getc, fd_ready, read_split =
	I.array_key, I.sh_printf, I.fd_getc, I.fd_ready, I.read_split
local do_arrayassign, eval, fmt_decl, fmt_set_var = I.do_arrayassign, I.eval, I.fmt_decl, I.fmt_set_var
local C, P = I.C, I.P
local job_resolve, SIGDESC = I.job_resolve, I.SIGDESC
-- reap any child, skipping the shell's own helpers (rt.internal_pids: not jobs)
local function wait_any(stbuf)
	while true do
		local r = C.waitpid(-1, stbuf, rt.sched_live() and 1 or 0) -- (WNOHANG while tasks run)
		if r == 0 then -- nothing yet: let the background jobs run a while
			rt.sched_pump({ deadline = rt.wall_secs() + 0.01 })
		elseif r < 0 or not rt.internal_pids[r] then
			return r
		else
			rt.internal_pids[r] = nil
		end
	end
end

-- a waited job that a signal killed: bash's `PID Desc  command` line (not for the
-- signals a script expects to end things: INT, PIPE, TERM)
local function report(j)
	local d = j.sig and j.sig ~= 2 and j.sig ~= 13 and j.sig ~= 15 and SIGDESC[j.sig]
	if d then
		io.stderr:write("curse: " .. j.pid .. " " .. ("%-24s"):format(d) .. (j.cmd or "") .. "\n")
	end
end

-- The first of `jobs` to end (nil if none can): in-process jobs end in the scheduler, real
-- children through waitpid — whichever comes first.
local function wait_first(sh, jobs, stbuf)
	while true do
		local anyg, anyreal = false, false
		for _, j in ipairs(jobs) do
			if not j.done then
				job_reap(sh, j, true)
			end
			if j.done then
				return j
			end
			if j.g then
				anyg = true
			else
				anyreal = true
			end
		end
		if anyg then
			rt.sched_pump({
				untilf = function()
					for _, j in ipairs(jobs) do
						if j.g and j.g.done then
							return true
						end
					end
					return false
				end,
				deadline = anyreal and (rt.wall_secs() + 0.01) or nil,
			})
			if not anyreal and not rt.sched_live() then
				for _, j in ipairs(jobs) do
					job_reap(sh, j, true)
					if j.done then
						return j
					end
				end
				return nil
			end
		elseif anyreal then
			local r = wait_any(stbuf)
			if r < 0 then
				return nil
			end
			local est = rt.wexit(stbuf[0])
			for _, j in ipairs(sh.jobs) do
				if j.pid == r then
					j.done, j.status = true, est
					if sh.coprocs then
						rt.coproc_dispose(sh, r)
					end
				end
			end
		else
			return nil
		end
	end
end
local wait_builtin
local function wait_entry(sh, cmd, args, hook, tcb)
	-- in a pipeline stage / $(…), the parent's jobs are listed but aren't children: `wait`
	-- sees only the subshell's own
	local foreign = cmd == "wait" and sh.foreign_pids
	if not foreign or not next(foreign) then
		return wait_builtin(sh, cmd, args, hook, tcb)
	end
	local all, mine = sh.jobs or {}, {}
	for _, j in ipairs(all) do
		if not foreign[j.pid] then
			mine[#mine + 1] = j
		end
	end
	sh.jobs = mine
	local ok, err = pcall(wait_builtin, sh, cmd, args, hook, tcb)
	local out = {}
	for _, j in ipairs(all) do
		if foreign[j.pid] then
			out[#out + 1] = j
		end
	end
	for _, j in ipairs(sh.jobs or {}) do
		out[#out + 1] = j
	end
	sh.jobs = out
	if not ok then
		error(err, 0)
	end
end

wait_builtin = function(sh, cmd, args, hook, tcb)
	if cmd == "wait" then
		-- wait [-n] [pid…]: reap background jobs. With pids, return the last one's
		-- status; with none, wait for all (status 0); an invalid arg is status 1.
		local stbuf = ffi.new("int[1]")
		local function reap(pid)
			if rt.wait_child(pid, stbuf, 0) < 0 then
				-- a process substitution already reaped when its command finished
				return sh.procsub_status and sh.procsub_status[pid] or 127
			end
			return rt.wexit(stbuf[0])
		end
		local nflag, specs = false, {}
		local pvar -- -p VAR: the pid whose status is returned lands in VAR
		local k = 2
		while args[k] and args[k]:match("^%-.") do -- (options end at `--` or an operand)
			local a = args[k]
			k = k + 1
			if a == "--" then
				break
			end
			local ci = 2
			while ci <= #a do
				local f = a:sub(ci, ci)
				ci = ci + 1
				if f == "n" then
					nflag = true
				elseif f == "f" then -- (accepted: we always block until done anyway)
				elseif f == "p" then
					pvar = a:sub(ci) ~= "" and a:sub(ci) or args[k]
					if a:sub(ci) == "" then
						k = k + 1
					end
					if pvar == nil then
						io.stderr:write("curse: wait: -p: option requires an argument\n" .. rt.usage("wait"))
						sh.status = 2
						return
					end
					break
				else
					io.stderr:write("curse: wait: -" .. f .. ": invalid option\n" .. rt.usage("wait"))
					sh.status = 2
					return
				end
			end
		end
		for j = k, #args do
			specs[#specs + 1] = args[j]
		end
		if pvar then -- (bash unsets VAR first: a readonly one stops it right here)
			local pb = sh.vars[sh:deref(pvar)]
			if pb and pb.ro then
				io.stderr:write("curse: wait: " .. sh:deref(pvar) .. ": cannot unset: readonly variable\n")
				sh.status = 1
				return
			end
		end
		sh.jobs = sh.jobs or {}
		local waited -- the pid whose status we return (for -p)
		if nflag and #specs > 0 then
			-- -n with jobs: whichever LISTED job finishes first (others that end are recorded)
			-- (only jobs not yet waited for count; bash forgets a job once wait returns it)
			local want = {}
			for _, sp in ipairs(specs) do
				local j = sp:sub(1, 1) == "%" and job_resolve(sh, sp)
				local pid = j and j.pid or tonumber(sp)
				local live
				for _, jj in ipairs(sh.jobs) do
					if jj.pid == pid and not jj.waited then
						live = jj
					end
				end
				if live then
					want[pid] = true
				else
					io.stderr:write("curse: wait: " .. sp .. ": no such job\n")
				end
			end
			sh.status = 127
			for _, j in ipairs(sh.jobs) do -- (one already finished answers at once)
				if want[j.pid] and j.done then
					sh.status, waited = j.status or 0, j.pid
					j.waited = true
					break
				end
			end
			if not waited and next(want) then
				local list = {}
				for _, j in ipairs(sh.jobs) do
					if want[j.pid] then
						list[#list + 1] = j
					end
				end
				local j = wait_first(sh, list, stbuf)
				if j then
					sh.status, waited = j.status or 0, j.pid
					j.waited = true
				end
			end
		elseif nflag and #specs == 0 then
			-- wait for the NEXT job to finish (127 if there are none to wait for)
			local list = {}
			for _, j in ipairs(sh.jobs) do
				if not j.done then
					list[#list + 1] = j
				end
			end
			local j = #list > 0 and wait_first(sh, list, stbuf)
			if not j then
				sh.status = 127
			else
				sh.status, waited = j.status or 0, j.pid
			end
		elseif #specs > 0 then
			local last = 0
			for _, s in ipairs(specs) do
				if s:sub(1, 1) == "%" then
					local j = job_resolve(sh, s)
					if not j then
						io.stderr:write("curse: wait: " .. s .. ": no such job\n")
						last = 127
					else
						last, waited = job_reap(sh, j) or 127, j.pid
						report(j)
					end
				elseif s:match("^%d+$") then
					local pid, found = tonumber(s), nil
					for _, j in ipairs(sh.jobs) do
						if j.pid == pid then
							found = j
						end
					end
					waited = pid
					if found then
						last = job_reap(sh, found) or 127
						report(found)
					elseif C.waitpid(pid, stbuf, 1) == 0 or (sh.procsub_status and sh.procsub_status[pid]) then
						last = reap(pid) -- (a live child we don't list, or a finished procsub)
					else
						local r = C.waitpid(pid, stbuf, 1) -- (WNOHANG)
						if r == pid then
							last = rt.wexit(stbuf[0])
						else
							io.stderr:write("curse: wait: pid " .. pid .. " is not a child of this shell\n")
							last = 127
						end
					end
				else -- a bare non-pid/non-jobspec word: status 1 alone, 127 under -n
					io.stderr:write("curse: wait: `" .. s .. "': not a pid or valid job spec\n")
					last = nflag and 127 or 1
				end
			end
			sh.status = last
		else -- wait for all jobs
			for _, j in ipairs(sh.jobs) do
				if not j.done then
					job_reap(sh, j)
					report(j)
				end
			end
			if sh.bg_pids then
				for _, p in ipairs(sh.bg_pids) do
					pcall(reap, p)
				end
				sh.bg_pids = {}
			end
			sh.status = 0
		end
		if pvar and waited then
			local st = sh.status
			rt.assign_ref(sh, "wait", pvar, tostring(waited))
			sh.status = st
		end
	end
end

return wait_entry
