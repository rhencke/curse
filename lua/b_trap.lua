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
		-- trap [-lp] [[ACTION] SIG…]  (bash builtins/trap.def)
		local j, pflag, lflag = 2, false, false
		local usage = "trap: usage: trap [-lp] [[arg] signal_spec ...]\n"
		while args[j] and args[j]:match("^%-.") and args[j] ~= "--" do -- (getopt "lp")
			if args[j] == "--help" then -- (CASE_HELPOPT: the builtin's help, status 2)
				require("b_help")(sh, "help", { "help", "trap" })
				sh.status = 2
				sh.spb_err = 2 -- (EX_USAGE: rt.spb_run)
				return
			end
			if not args[j]:match("^%-[lp]+$") then
				io.stderr:write("curse: trap: -" .. args[j]:match("^%-[lp]*(.)") .. ": invalid option\n")
				io.stderr:write(usage)
				sh.status = 2
				sh.spb_err = 2 -- (EX_USAGE: rt.spb_run)
				return
			end
			lflag = lflag or args[j]:find("l", 2, true) ~= nil
			pflag = pflag or args[j]:find("p", 2, true) ~= nil
			j = j + 1
		end
		if args[j] == "--" then
			j = j + 1
		end
		if lflag then -- list signal names (NN) SIGNAME)
			sh.out(rt.signal_list(NUMSIG))
			sh.status = 0
			return
		end
		-- showtrap: the action via sh_single_quote; a name bash has no name for prints as its
		-- number; posix mode drops the SIG prefix. `trap -p` in posix mode (show_default)
		-- also lists untrapped signals, as `-`.
		local posix = sh.opt_posix
		local function show(canon, dflt)
			local t = sh.traps[canon]
			if t == nil then
				if not dflt then
					return
				end
				t = "-"
			elseif t == "'" then
				t = "\\'"
			else
				t = "'" .. t:gsub("'", "'\\''") .. "'"
			end
			if posix then
				canon = canon:gsub("^SIG", "")
			end
			sh:echo("trap -- " .. t .. " " .. canon)
		end
		if pflag or j > #args then -- print traps (all, or the named signals) in signal order
			local st = 0
			local dflt = pflag and posix
			if j <= #args then -- print only the named signals, as they come
				for k = j, #args do
					local c = canon_sig(args[k])
					if not c then
						io.stderr:write("curse: trap: " .. args[k] .. ": invalid signal specification\n")
						st = 1
					else
						show(c, dflt)
					end
				end
			else
				local list = {}
				for canon in pairs(sh.traps) do
					list[#list + 1] = canon
				end
				table.sort(list, function(a, b)
					return sig_order(a) < sig_order(b)
				end)
				for _, canon in ipairs(list) do
					show(canon, false)
				end
			end
			sh.status = st
		else
			-- The first word is the action unless it's an all-digit valid signal (`trap 0 2`:
			-- reset them all) or — not in posix mode — the sole word and a valid signal (`trap
			-- TERM`); a NAME first word with signals after is the action (`trap INT EXIT`).
			local first = args[j]
			local action, sigstart
			if first:match("^%d+$") and canon_sig(first) then
				action, sigstart = "-", j
			elseif not posix and first ~= "-" and #args == j and canon_sig(first) then
				action, sigstart = "-", j
			else
				action, sigstart = first, j + 1
			end
			if sigstart > #args then -- an action with no signal spec is a usage error
				io.stderr:write(usage)
				sh.status = 2
				sh.spb_err = 2 -- (EX_USAGE: rt.spb_run)
				return
			end
			-- a subshell's first set/reset drops the trap strings it inherited — before the
			-- specs are even decoded (trap.def: SUBSHELL_RESETTRAP → free_trap_strings)
			rt.iso_trap_changed(sh)
			local ok = true
			for k = sigstart, #args do
				local canon = canon_sig(args[k])
				if not canon then
					io.stderr:write("curse: trap: " .. args[k] .. ": invalid signal specification\n")
					ok = false
				elseif sh.sig_ign_start and sh.sig_ign_start[canon] then
					-- ignored when the shell started: can't be trapped or reset (bash), silently
				else
					if action == "-" then
						sh.traps[canon] = nil
					else
						sh.traps[canon] = action
						if action:find("BASH_COMMAND", 1, true) then
							-- (sticky: code compiled from now on records each command's text —
							-- tier.trap_mode "B" keys the fragments that do)
							sh.trap_bcmd = true
						end
					end
					if canon == "ERR" then -- (it fires where it was set: see interp's fire_err_trap)
						sh.err_trap_sp = sh.in_subprogram or 0
					elseif canon == "DEBUG" then -- (likewise: rt.pseudo_trapped)
						sh.dbg_trap_sp = sh.in_subprogram or 0
					elseif canon == "RETURN" then
						sh.ret_trap_sp = sh.in_subprogram or 0
					end
					if canon == "EXIT" then
						rt.exit_trap_inherited = nil -- this (sub)shell's own EXIT trap now
						if not sh.opt_i then -- (the untrapped terminating signals: rt.termsig)
							rt.sig_exit_trap(sh)
						end
					end
					-- a REAL signal (not EXIT/DEBUG/RETURN/ERR): the process disposition follows
					-- the trap — `''` is a real SIG_IGN (so children and exec'd programs inherit
					-- it, as in bash), a command installs curse's async handler (it schedules a
					-- VM hook that runs the trap at the next safepoint — no polling), `-` restores
					-- the default. sh.sigtraps holds the signals with a non-default disposition.
					local num = SIGNUM[canon:match("^SIG(.+)$") or ""]
					local ic = rt.iso_cur(sh)
					if num and ic and ic.igint and ic.igint[num] then
						ic.igint[num] = nil -- (an async job's ignored SIGINT/SIGQUIT: the trap's now)
					end
					if num and num ~= 9 and num ~= 19 then -- KILL/STOP can't be trapped
						if action == "-" then
							if sh.sigtraps and sh.sigtraps[canon] then
								sh.sigtraps[canon] = nil
								rt.sig_untrapped(sh, num) -- (the default, or caught: rt.termsig)
							end
						else
							sh.sigtraps = sh.sigtraps or {}
							sh.sigtraps[canon] = true
							if action == "" then
								C.curse_sig_ignore(num)
							else
								block_sig(num, true)
								-- the C signal hook calls this global with the signal number to run
								-- its trap directly (bound to the shell that owns the traps).
								_G.__curse_sigrun = function(s)
									M.run_signal(sh, s)
								end
							end
						end
					end
				end
			end
			sh.status = ok and 0 or 1
		end
	end
end
