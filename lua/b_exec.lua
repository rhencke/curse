-- Lazily-loaded builtin feature module: `exec [-cl] [-a name] [command [arg …]] [redir …]`
-- (bash-5.2.21/builtins/exec.def, exec_builtin). Called from interp's exec_stmt with the
-- command's prefix bindings in effect (a temporary env; posix: they persist).
local ffi = require("ffi")
local rt = require("runtime")
local M = require("interp")
local I = M._int
local apply_redirs, restore_redirs, C = I.apply_redirs, I.restore_redirs, I.C

-- bash's full_pathname (general.c): an absolute name as is, else under the (logical) cwd
-- with a leading `./` dropped (sh_makepath's MP_DOCWD|MP_RMDOT)
local function full_pathname(sh, f)
	if f:byte(1) == 47 then
		return f
	end
	local cwd = sh:pwd()
	if f:sub(1, 2) == "./" then
		f = f:sub(3)
	end
	return cwd:sub(-1) == "/" and cwd .. f or cwd .. "/" .. f
end

-- What execve would refuse, diagnosed as shell_execve does (file_error / "Is a directory"),
-- then exec_builtin's own "cannot execute" for all but ENOENT: the status (127 / 126), or
-- nil when PATH can be run.
local stbuf = ffi.new("uint8_t[144]")
local function exec_refused(path)
	local e
	if C.curse_rt_stat(path, stbuf) ~= 0 then
		e = ffi.errno()
	elseif bit.band(ffi.cast("uint32_t *", stbuf + 24)[0], 0xF000) == 0x4000 then
		e = 21 -- EISDIR
	elseif C.access(path, 1) ~= 0 then -- X_OK
		e = ffi.errno()
	else
		return nil
	end
	local msg = ffi.string(C.strerror(e))
	if e == 21 then -- (shell_execve's EISDIR: its own _("%s: %s"), unlike file_error's)
		io.stderr:write("curse: " .. rt.L("%s: %s", path, msg) .. "\n")
	else
		io.stderr:write("curse: " .. path .. ": " .. msg .. "\n")
	end
	if e == 2 then -- ENOENT: EX_NOTFOUND, "no duplicate error message"
		return 127
	end
	io.stderr:write("curse: exec: " .. path .. ": cannot execute: " .. msg .. "\n")
	return 126
end

-- The environ as a list of NAME=VALUE strings (to put back after a failed `exec -c`)
local function environ_list()
	local t, e, i = {}, C.environ, 0
	while e ~= nil and e[i] ~= nil do
		t[#t + 1] = ffi.string(e[i])
		i = i + 1
	end
	return t
end

-- bash's failed_exec: the shell exits (EXIT trap and all) unless it is the main shell of
-- an interactive session or `shopt -s execfail` is on; a subshell always exits.
local function failed_exec(sh, status)
	sh.status = status
	if (sh.in_subprogram or 0) > 0 or not (sh.opt_i or sh.shopt.execfail) then
		error({ __curse_exit = status })
	end
end

return function(sh, st, args, hook, viacmd)
	-- in an in-process subshell/$(…) fds and the environ are process-global: save them
	-- (restored when it ends); `exec CMD` runs CMD, then ends the subshell
	rt.iso_save_fds(sh)
	rt.iso_save_env(sh)
	io.flush()
	local sv
	if st.redirs then
		local ok
		-- a pipeline stage's output is buffered for its fd 1: what's there goes to the old
		-- one, and a builtin then writes (and reports a failed write) straight to fd 1
		local tostdout = rt.CO_OUTS[sh.out] and I.redirs_touch_stdout(st.redirs)
		if tostdout then
			rt.flush_stage_out(sh)
		end
		sv, ok = apply_redirs(sh, st.redirs, "exec")
		if tostdout and ok then
			sh.out = io.write
		end
		if sh.coprocs then
			rt.coproc_fdcheck(sh) -- a coproc end it closed/moved reads as -1
		end
		if not ok then -- (the builtin never runs; posix: a special builtin's redirection
			-- error is fatal to a non-interactive shell — `command exec` only fails)
			if type(sv) == "table" then
				restore_redirs(sv)
			end
			sh.status = 1
			if sh.opt_posix and not viacmd and not sh.opt_i then
				error({ __curse_exit = 1 })
			end
			return
		end
	end
	-- exec [-cl] [-a name] [--] [cmd…]: -c empty environment, -l login ($0 gets a
	-- leading -), -a NAME as $0. Another option (or -a without its NAME) is a usage
	-- error (status 2) — and then the redirections are undone (bash disposes of the
	-- undo list only after the options parse).
	local k, argv0, cflag, lflag = 2, nil, false, false
	local bad
	while not bad and args[k] and args[k]:sub(1, 1) == "-" and args[k] ~= "-" do
		local a = args[k]
		k = k + 1
		if a == "--" then
			break
		end
		local j = 2
		while j <= #a do
			local f = a:sub(j, j)
			if f == "c" then
				cflag = true
			elseif f == "l" then
				lflag = true
			elseif f == "a" then
				if j < #a then
					argv0 = a:sub(j + 1)
				elseif args[k] ~= nil then
					argv0 = args[k]
					k = k + 1
				else
					bad = "curse: exec: -a: option requires an argument\n"
				end
				break
			else
				bad = "curse: exec: -" .. f .. ": invalid option\n"
				break
			end
			j = j + 1
		end
	end
	if bad then
		io.stderr:write(bad .. rt.usage("exec"))
		if type(sv) == "table" then
			restore_redirs(sv)
		end
		sh.status = 2
		if sh.opt_posix and not viacmd and not sh.opt_i then -- (EX_USAGE: rt.spb_run's rule)
			rt.spb_exit(sh, 2, sh.spb_neg)
		end
		return
	end
	if type(sv) == "table" then -- the redirections persist: the saved originals are dropped
		rt.redir_discard(sv)
	end
	if k > #args then
		sh.status = 0
		return
	end
	if rt.restricted(sh, "exec: restricted") then
		return
	end
	local rest = { unpack(args, k) }
	local name = rest[1]
	-- search_for_command: the name along $PATH ONLY (a function or builtin of that name
	-- is bypassed); one with a slash is taken as is. Then its full pathname.
	local command
	if name:find("/", 1, true) then
		command = name
	elseif name ~= "" then
		command = sh:resolve_cmd(name)
	end
	if not command then
		local isdir = name ~= "" and C.curse_rt_stat(name, stbuf) == 0
			and bit.band(ffi.cast("uint32_t *", stbuf + 24)[0], 0xF000) == 0x4000
		if isdir then
			io.stderr:write("curse: exec: " .. name .. ": cannot execute: Is a directory\n")
		else
			io.stderr:write("curse: exec: " .. rt.err_name(name) .. ": not found\n")
		end
		return failed_exec(sh, isdir and 126 or 127)
	end
	command = full_pathname(sh, command)
	local refused = exec_refused(command)
	if refused then
		return failed_exec(sh, refused)
	end
	if lflag then -- (mkdashname: a leading - on the name's basename)
		argv0 = "-" .. (argv0 or name:match("[^/]*$"))
	end
	rest[1] = command
	local sv_a0, sv_eb, sv_ne, sv_sa0 = sh.exec_argv0, sh.exec_builtin, sh.exec_noenv, sh.exec_script_a0
	sh.exec_argv0 = argv0 or name -- (argv[0] is the name as typed; the path is exec'd)
	sh.exec_script_a0 = argv0 -- (a no-#! script's $0: this, else its full pathname)
	sh.exec_builtin = true -- (a spawn failure reads `exec: NAME: …`, bash)
	sh.exec_noenv = true -- (no `_` of its own: only a forked command gets one)
	local env0
	if cflag then
		env0 = environ_list()
		C.clearenv()
	end
	-- the command replaces this shell: bash lowers SHLVL for it — except in a ( … )
	-- subshell (SUBSHELL_PAREN), itself counted as having raised nothing — and never
	-- with -c (no environment at all)
	local sd, snu = rt.shlvl_delta, rt.env_drop_us
	if not cflag and not (sh.paren_sp and sh.paren_sp == sh.in_subprogram) then
		rt.shlvl_delta = -1
	end
	rt.env_drop_us = true
	local eok, eerr = pcall(sh.exec, sh, unpack(rest))
	rt.shlvl_delta, rt.env_drop_us = sd, snu
	sh.exec_argv0, sh.exec_builtin, sh.exec_noenv, sh.exec_script_a0 = sv_a0, sv_eb, sv_ne, sv_sa0
	if env0 then -- (only a failed exec that the shell survives needs these back)
		C.clearenv()
		for _, kv in ipairs(env0) do
			local n, v = kv:match("^([^=]*)=(.*)$")
			if n then
				C.setenv(n, v, 1)
			end
		end
	end
	if not eok then
		error(eerr, 0)
	end
	io.flush()
	-- the command REPLACED the shell: end with its status, no EXIT trap (bash). Not
	-- os.exit — in the daemon that would kill the worker before it replies.
	error({ __curse_exit = sh.status or 0, __curse_noexittrap = true })
end
