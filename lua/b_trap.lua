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

return function(sh, cmd, args, hook, tcb)
	if cmd == "trap" then
		-- trap [-p] [ACTION] SIG…  (subset: registers/prints; only EXIT actually fires)
		local j, pflag = 2, false
		if args[j] == "-l" then -- list signal names (NN) SIGNAME)
			local nums = {}
			for n in pairs(NUMSIG) do
				nums[#nums + 1] = n
			end
			table.sort(nums)
			for _, n in ipairs(nums) do
				sh:echo(("%2d) SIG%s"):format(n, NUMSIG[n]))
			end
			sh.status = 0
			return
		end
		if args[j] == "-p" then
			pflag = true
			j = j + 1
		end
		if args[j] == "--" then
			j = j + 1
		end
		if pflag or j > #args then -- print traps (all, or the named signals) in signal order
			local list = {}
			if j <= #args then -- print only the named signals
				for k = j, #args do
					local c = canon_sig(args[k])
					if c and sh.traps[c] then
						list[#list + 1] = c
					end
				end
			else
				for canon in pairs(sh.traps) do
					list[#list + 1] = canon
				end
			end
			table.sort(list, function(a, b)
				return sig_order(a) < sig_order(b)
			end)
			for _, canon in ipairs(list) do
				sh:echo("trap -- '" .. sh.traps[canon] .. "' " .. canon)
			end
			sh.status = 0
		elseif args[j]:sub(1, 1) == "-" and args[j] ~= "-" then -- a stray -flag (e.g. `trap -1`)
			io.stderr:write("curse: trap: " .. args[j] .. ": invalid option\n")
			sh.status = 2
		else
			-- bash: reset-mode (all tokens are signals to reset) only when the first
			-- token is a NUMERIC signal (`trap 0 2`) or the sole arg and a valid signal
			-- (`trap TERM`); a NAME first token is the action, even a name that happens
			-- to be a signal (`trap INT EXIT` runs `INT` at EXIT; `trap err ERR`).
			local action, sigstart
			if canon_sig(args[j]) and (#args == j or args[j]:match("^%d+$")) then
				action, sigstart = "-", j
			else
				action, sigstart = args[j], j + 1
			end
			if sigstart > #args then -- an action with no signal spec is a usage error
				io.stderr:write("curse: trap: usage: trap [-lp] [[arg] signal_spec ...]\n")
				sh.status = 1
				return
			end
			local ok = true
			for k = sigstart, #args do
				local canon = canon_sig(args[k])
				if not canon then
					io.stderr:write("curse: trap: " .. args[k] .. ": invalid signal specification\n")
					ok = false
				elseif action == "-" then
					sh.traps[canon] = nil
				else
					sh.traps[canon] = action
				end
				-- a REAL signal (not EXIT/DEBUG/RETURN/ERR): install curse's async handler
				-- (block_sig(num,true)); it schedules a VM hook that runs the trap at the next
				-- safepoint (no polling). Resetting restores the default disposition.
				-- sh.sigtraps counts active signal traps.
				local num = canon and SIGNUM[canon:match("^SIG(.+)$") or ""]
				if num and num ~= 9 and num ~= 19 then -- KILL/STOP can't be trapped
					local had = sh.sigtraps and sh.sigtraps[canon]
					if action == "-" and had then
						block_sig(num, false)
						sh.sigtraps[canon] = nil
					elseif action ~= "-" and not had then
						sh.sigtraps = sh.sigtraps or {}
						sh.sigtraps[canon] = true
						block_sig(num, true)
						-- the C signal hook calls this global with the signal number to run its
						-- trap directly (bound to the shell that owns the traps).
						_G.__curse_sigrun = function(s)
							M.run_signal(sh, s)
						end
					end
				end
			end
			sh.status = ok and 0 or 1
		end
	end
end
