-- Lazily-loaded builtin feature module (see BUILTIN_LAZY in interp.lua). Its own
-- module -- no grab bags -- so a script loads only the builtin it uses. Internals
-- aliased to interp's names so the branch body is a verbatim copy.
local ffi = require("ffi")
local bit = require("bit")
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

-- a waited job that a signal killed: bash's `PID Desc  command` line (rt.jobs_notify: not
-- for the signals a script expects to end things — INT, PIPE, TERM — nor a trapped one)
local function report(sh, j)
	rt.jobs_notify(sh, j)
end

-- The first of `jobs` to end (nil if none can, or a trapped signal came): in-process jobs
-- end in the scheduler, real children through waitpid — whichever comes first.
local function wait_first(sh, jobs, stbuf)
	while true do
		if sh.wait_sig then
			return nil
		end
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
					if sh.wait_sig then
						return true
					end
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
				if ffi.errno() ~= 4 then -- (EINTR: go round — a trap may have ended the wait)
					return nil
				end
			else
				local est = rt.wexit(stbuf[0])
				for _, j in ipairs(sh.jobs) do
					if j.pid == r then
						j.done, j.status = true, est
						local sg = bit.band(stbuf[0], 0x7f)
						j.sig = sg ~= 0 and sg ~= 0x7f and sg or nil
						if sh.coprocs then
							rt.coproc_dispose(sh, r)
						end
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
	-- a trapped signal that arrives meanwhile ends the wait (run_signal sets sh.wait_sig)
	local sv_in, sv_sig = sh.in_wait, sh.wait_sig
	sh.in_wait, sh.wait_sig = true, nil
	-- in a pipeline stage / $(…), the parent's jobs are listed but aren't children: `wait`
	-- sees only the subshell's own
	local foreign = cmd == "wait" and sh.foreign_pids
	if not foreign or not next(foreign) then
		local ok, err = pcall(wait_builtin, sh, cmd, args, hook, tcb)
		sh.in_wait, sh.wait_sig = sv_in, sv_sig
		if not ok then
			error(err, 0)
		end
		return
	end
	local all, mine = sh.jobs or {}, {}
	for _, j in ipairs(all) do
		if not foreign[j.pid] then
			mine[#mine + 1] = j
		end
	end
	sh.jobs = mine
	local ok, err = pcall(wait_builtin, sh, cmd, args, hook, tcb)
	sh.in_wait, sh.wait_sig = sv_in, sv_sig
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

-- the jobs still in the table, oldest slot first
local function table_jobs(sh, live) -- (`live`: not the ones a `wait ID` already reported)
	local list = {}
	for _, j in ipairs(sh.jobs) do
		if not j.gone and not (live and j.waited) then
			list[#list + 1] = j
		end
	end
	table.sort(list, function(a, b)
		return a.id < b.id
	end)
	return list
end

wait_builtin = function(sh, cmd, args, hook, tcb)
	if cmd == "wait" then
		-- wait [-fn] [-p VAR] [id…] (wait.def): reap background jobs. With ids, the last
		-- one's status; with none, wait for all (status 0). A waited job leaves the table.
		local stbuf = ffi.new("int[1]")
		local function reap(pid)
			if rt.wait_child(pid, stbuf, 0, sh) < 0 then
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
		if pvar then -- (a valid name, unset first: a readonly one stops it right here)
			if not rt.split_array_ref(pvar, sh) then
				io.stderr:write("curse: wait: `" .. pvar .. "': not a valid identifier\n")
				sh.status = 1
				return
			end
			local pb = sh.vars[sh:deref(pvar)]
			if pb and pb.ro then
				io.stderr:write("curse: wait: " .. sh:deref(pvar) .. ": cannot unset: readonly variable\n")
				sh.status = 1
				return
			end
			if pvar:find("^[%a_][%w_]*$") then
				require("b_unset")(sh, "unset", { "unset", pvar })
			end
		end
		sh.jobs = sh.jobs or {}
		local waited -- the pid whose status we return (for -p)
		if nflag then
			-- -n: the first job to end — one that already has and isn't yet reported first;
			-- with ids, only among those (127 if none can)
			local list = table_jobs(sh, true)
			if #specs > 0 then
				local want, sel = {}, {}
				for _, sp in ipairs(specs) do
					local j, dup
					if sp:sub(1, 1) == "%" then
						j, dup = job_resolve(sh, sp, "wait")
					else
						local pid = rt.legal_number(sp)
						for _, jj in ipairs(list) do
							if jj.pid == pid then
								j = jj
							end
						end
					end
					if j then
						want[j] = true
					elseif not dup then
						io.stderr:write("curse: wait: " .. sp .. ": no such job\n")
					end
				end
				for _, j in ipairs(list) do
					if want[j] then
						sel[#sel + 1] = j
					end
				end
				list = sel
			end
			local j = #list > 0 and wait_first(sh, list, stbuf)
			if j then
				sh.status, waited = j.status or 0, j.pid
				rt.job_delete(sh, j)
			else
				sh.status = 127
			end
		elseif #specs > 0 then
			local last = 0
			for _, s in ipairs(specs) do
				local pid = nil
				if s:match("^%d") then -- (a pid: a bad one ends `wait` right here)
					local n = rt.legal_number(s)
					if not n or n > 2147483647 then
						io.stderr:write("curse: wait: `" .. s .. "': not a pid or valid job spec\n")
						sh.status = 1
						return
					end
					pid = n
				end
				if pid then
					local found = nil
					for _, j in ipairs(sh.jobs) do
						if j.pid == pid then
							found = j
						end
					end
					waited = pid
					if found and found.forgot then -- (posix mode: a waited pid leaves bgpids too)
						io.stderr:write("curse: wait: pid " .. pid .. " is not a child of this shell\n")
						last, waited = 127, nil
					elseif found then
						last = job_reap(sh, found) or 127
						if found.done then
							report(sh, found)
							rt.job_waited(sh, found)
							found.forgot = sh.opt_posix or nil
						end
					elseif sh.disowned and sh.disowned[pid] then
						last = sh.disowned[pid]
					elseif sh.bgp_cleared and sh.bgp_cleared[pid] then -- (a `( … )`'s parent's: bgp_clear)
						io.stderr:write("curse: wait: pid " .. pid .. " is not a child of this shell\n")
						last, waited = 127, nil
					elseif rt.vpid_tasks[pid] and rt.vpid_tasks[pid].g.bg then -- (a disowned in-process job)
						local g = rt.vpid_tasks[pid].g
						rt.wait_groups({ g }, sh)
						last = g.done and (g.status[1] or 0) or 127
					elseif C.waitpid(pid, stbuf, 1) == 0 or (sh.procsub_status and sh.procsub_status[pid]) then
						last = reap(pid) -- (a live child we don't list, or a finished procsub)
					else
						local r = C.waitpid(pid, stbuf, 1) -- (WNOHANG)
						if r == pid then
							last = rt.wexit(stbuf[0])
						else
							io.stderr:write("curse: wait: pid " .. pid .. " is not a child of this shell\n")
							last, waited = 127, nil
						end
					end
				elseif s:sub(1, 1) == "%" then
					local j, dup = job_resolve(sh, s, "wait")
					if not j then
						if not dup then
							io.stderr:write("curse: wait: " .. s .. ": no such job\n")
						end
						last, waited = 127, nil
					else
						last, waited = job_reap(sh, j) or 127, j.pid
						if j.done then
							report(sh, j)
							rt.job_waited(sh, j)
						end
					end
				else -- a word that's neither: status 1, and on to the next
					io.stderr:write("curse: wait: `" .. s .. "': not a pid or valid job spec\n")
					last, waited = 1, nil
				end
				if sh.wait_sig then
					break
				end
			end
			sh.status = last
		else -- wait for all jobs
			-- (wait_for_background_pids: a job still running when reached is waited for and
			-- leaves the table; one that had already ended goes too — mark_dead_jobs_as_notified
			-- — except $!'s: POSIX keeps the last async job's status until reported)
			-- (a real child has ended if waitpid says so; an in-process job if the shell already
			-- saw it end — rt.jobs_poll — or a signal killed it while we waited on another, as
			-- bash's waitchld reaps a child killed alongside; one that just finishes meanwhile
			-- would, as a bash child, still have been running when reached)
			local gone, blocked = {}, false
			for _, j in ipairs(table_jobs(sh)) do
				local ended = j.done
				if not ended and j.g then
					ended = blocked and j.g.done and job_reap(sh, j, true) ~= nil and j.sig ~= nil
				elseif not ended then
					ended = job_reap(sh, j, true) ~= nil
				end
				if not ended then
					blocked = blocked or not (j.g and j.g.done)
					job_reap(sh, j)
					report(sh, j)
				end
				if sh.wait_sig then
					break
				end
				if not ended or tostring(j.pid) ~= sh.last_bg_pid then
					gone[#gone + 1] = j
				end
			end
			for _, j in ipairs(gone) do -- (deleted after: $!'s job doesn't become current meanwhile)
				rt.job_delete(sh, j)
				j.forgot = not sh.wait_sig or nil -- (bgp_clear: a later `wait PID` doesn't know it)
			end
			if sh.bg_pids and not sh.wait_sig then
				for _, p in ipairs(sh.bg_pids) do
					pcall(reap, p)
				end
				sh.bg_pids = {}
			end
			sh.status = 0
			waited = nil -- (wait with no ids never sets VAR)
		end
		if sh.wait_sig then -- a trapped signal ended it (its trap has run)
			sh.status = 128 + sh.wait_sig
			return
		end
		if pvar and waited then
			local st = sh.status
			rt.assign_ref(sh, "wait", pvar, tostring(waited))
			sh.status = st
		end
	end
end

return wait_entry
