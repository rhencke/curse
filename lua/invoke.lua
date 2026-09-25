-- Shell invocation (bash's shell.c main): the argv option parser, the startup files and
-- the choice of what to run — ONE implementation shared by the daemon's per-request
-- dispatch (daemon.lua) and the direct CLI (run.lua).
--
--   local inv, st = Invoke.parse(argv)   -- argv[1] is argv[0]; nil, st: exit with st
--   local kind, payload = Invoke.start(sh, inv)
--     kind "code" (payload: the -c string), "file" (payload: the script's text), "stdin"
--     (non-interactive, read fd 0), "repl" (interactive), or "exit" (done: $? is sh.status)
--
-- The common invocations (`sh -c CODE`, `sh script args`) must stay cheap — they are the
-- daemon's per-request path: no file is opened or stat'ed that the invocation doesn't call
-- for (BASH_ENV only when it's set, login/rc files only for login/interactive shells).
local rt = require("runtime")
local ffi = require("ffi")

local M = {}

-- bash's long_args[] (shell.c), in its order: the usage text lists them so. A long option
-- may be spelled `--name` or `-name`; init-file and rcfile take the next word.
local LONG = {
	"debug",
	"debugger",
	"dump-po-strings",
	"dump-strings",
	"help",
	"init-file",
	"login",
	"noediting",
	"noprofile",
	"norc",
	"posix",
	"pretty-print",
	"rcfile",
	"restricted",
	"verbose",
	"version",
}
local LONGSET = {}
for _, nm in ipairs(LONG) do
	LONGSET[nm] = true
end

-- show_shell_usage (shell.c); `extra` (--help) adds the version line and the trailer
function M.usage(name, extra)
	local t = {}
	if extra then
		t[#t + 1] = "GNU bash, version 5.2.37(1)-release-(x86_64-pc-linux-gnu)\n"
	end
	t[#t + 1] = "Usage:\t" .. name .. " [GNU long option] [option] ...\n\t" .. name
		.. " [GNU long option] [option] script-file ...\nGNU long options:\n"
	for _, nm in ipairs(LONG) do
		t[#t + 1] = "\t--" .. nm .. "\n"
	end
	t[#t + 1] = "Shell options:\n\t-ilrsD or -c command or -O shopt_option\t\t(invocation only)\n"
		.. "\t-abefhkmnptuvxBCEHPT or -o option\n"
	if extra then
		t[#t + 1] = "Type `" .. name .. " -c \"help set\"' for more information about shell options.\n"
			.. "Type `" .. name .. " -c help' for more information about shell builtin commands.\n"
			.. "Use the `bashbug' command to report bugs.\n\n"
			.. "bash home page: <http://www.gnu.org/software/bash>\n"
			.. "General help using GNU software: <http://www.gnu.org/gethelp/>\n"
	end
	return table.concat(t)
end

local VERSION = "GNU bash, version 5.2.37(1)-release (x86_64-pc-linux-gnu)\n"
	.. "Copyright (C) 2022 Free Software Foundation, Inc.\n"
	.. "License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>\n\n"
	.. "This is free software; you are free to change and redistribute it.\n"
	.. "There is NO WARRANTY, to the extent permitted by law.\n"

-- (straight to the real stream: no shell is live yet for the "curse: " prefix rewrite)
local function err(s)
	io.stdout:flush()
	io.stderr:write(s)
	io.stderr:flush()
end

-- Parse argv as bash's parse_long_options + parse_shell_options do. Returns the invocation
-- table, or nil + the exit status after reporting a usage error (or printing --help /
-- --version: status 0).
function M.parse(args)
	local a0 = args[1] or "bash"
	-- shell_name: argv[0] as given (a bare `-` or empty one is "bash": set_shell_name)
	-- (curse's own entry points — the client or binary run by their own names — are bash)
	local b0 = a0:match("[^/]*$")
	local name = (a0 == "" or a0 == "-" or b0 == "curse-client" or b0 == "curse") and "bash" or a0
	local inv = { name = name, argv = args, sets = {}, i = 2 }
	local i, n = 2, #args
	-- long options first: `--name` or `-name`; an unknown `--x` is a usage error, an
	-- unknown `-x` falls through to the flag parser
	while i <= n do
		local a = args[i]
		if a:byte(1) ~= 45 then -- '-'
			break
		end
		local long = a:byte(2) == 45 and #a > 2
		local nm = a:sub(long and 3 or 2)
		if not LONGSET[nm] then
			if long then
				err(name .. ": " .. a .. ": invalid option\n" .. M.usage(name))
				return nil, 2
			end
			break
		end
		if nm == "init-file" or nm == "rcfile" then
			i = i + 1
			if args[i] == nil then
				err(name .. ": " .. nm .. ": option requires an argument\n")
				return nil, 2
			end
			inv.rcfile = args[i]
		else
			inv[nm] = true
		end
		i = i + 1
	end
	if inv.help then
		io.write(M.usage(name, true))
		io.flush()
		return nil, 0
	elseif inv.version then
		io.write(VERSION)
		io.flush()
		return nil, 0
	end
	-- single-letter options, clustered; each `o`/`O` in a cluster takes the next word.
	-- report_error under an errexit already on exits 1 at once (no usage text).
	local sets, e_on = inv.sets, false
	while i <= n do
		local a = args[i]
		local c1 = a:byte(1)
		if c1 ~= 45 and c1 ~= 43 then -- '-' / '+'
			break
		end
		local nx = i + 1
		if a == "-" or a == "--" then -- (the end of the options: 4.3BSD's `-`, getopt's `--`)
			i = nx
			break
		end
		local on = c1 == 45
		for k = 2, #a do
			local ch = a:sub(k, k)
			if ch == "c" then
				inv.want_c = true
			elseif ch == "l" then
				inv.login = true
			elseif ch == "s" then
				inv.stdin = true
			elseif ch == "D" then
				inv.dump = true
			elseif ch == "i" then
				inv.forced_i = on
			elseif ch == "o" or ch == "O" then
				local o = args[nx]
				if o == nil then -- bare -o/+o/-O/+O: list the options (then carry on)
					inv.lists = inv.lists or {}
					inv.lists[#inv.lists + 1] = ch == "o" and (on and "-o" or "+o") or (on and "" or "-p")
				elseif ch == "o" then
					local f = rt.SETOPT[o]
					if not f then
						err(name .. ": line 0: " .. name .. ": " .. o .. ": invalid option name\n")
						return nil, 2
					end
					sets[#sets + 1] = { f, on }
					if f == "opt_e" then
						e_on = on
					end
					nx = nx + 1
				else
					inv.shopts = inv.shopts or {}
					inv.shopts[#inv.shopts + 1] = { o, on }
					nx = nx + 1
				end
			elseif rt.SETFLAG[ch] then
				sets[#sets + 1] = { rt.SETFLAG[ch], on }
				if ch == "e" then
					e_on = on
				end
			else
				err(name .. ": " .. string.char(c1) .. ch .. ": invalid option\n")
				if e_on then
					return nil, 1
				end
				err(M.usage(name))
				return nil, 2
			end
		end
		i = nx
	end
	if inv.want_c then
		inv.code = args[i]
		if inv.code == nil then
			err(name .. ": -c: option requires an argument\n")
			return nil, e_on and 1 or 2
		end
		i = i + 1
	end
	inv.i = i
	return inv
end

-- Source a startup file as bash's maybe_execute_file: `~` expanded, a missing file skipped
-- silently (returns false), opened as named (no $PATH search).
local function nohook() end
local function run_file(sh, path)
	if path:byte(1) == 126 then -- '~'
		local rest = path:match("^~(/.*)$")
		if rest then
			path = sh:get("HOME") .. rest
		end
	end
	local f = io.open(path, "r")
	if not f then
		return false
	end
	f:close()
	local sp = sh.shopt.sourcepath
	sh.shopt.sourcepath = false
	local ok, e = pcall(require(rt.BUILTIN_LAZY["."]), sh, ".", { ".", path }, nohook)
	sh.shopt.sourcepath = sp
	if not ok then
		error(e, 0)
	end
	return true
end

-- execute_env_file: the variable's value, expanded as in double quotes, names the file
local function env_file(sh, var)
	local v = sh.vars[var] and sh:get(var)
	if v and v ~= "" then
		if v:find("[$`\\]") then
			local ok, x = pcall(function()
				return require("interp")._int.expand_word(sh, require("parser").parse_heredoc(v, false))
			end)
			v = ok and x or v
		end
		if v ~= "" then
			run_file(sh, v)
		end
	end
end

-- run_startup_files (shell.c): login files, $BASH_ENV (non-interactive), the rc file
-- (interactive) or $ENV (interactive posix)
local function startup_files(sh, inv, sh_like)
	local posix = sh.opt_posix
	local norc = inv.norc
	if inv.login_shell and not posix then
		norc = true -- (a login shell doesn't read .bashrc)
		if not inv.noprofile then
			run_file(sh, "/etc/profile")
			if sh_like then
				run_file(sh, "~/.profile")
			elseif not run_file(sh, "~/.bash_profile") and not run_file(sh, "~/.bash_login") then
				run_file(sh, "~/.profile")
			end
		end
	end
	if not sh.opt_i then
		if not posix and not sh_like and not sh.opt_p then
			env_file(sh, "BASH_ENV")
		end
		return
	end
	if not posix then
		if not sh_like and not norc then
			run_file(sh, "/etc/bash.bashrc") -- (Debian's SYS_BASHRC)
			run_file(sh, inv.rcfile or "~/.bashrc")
		elseif sh_like and not sh.opt_p then
			env_file(sh, "ENV")
		end
	elseif not sh.opt_p then
		env_file(sh, "ENV")
	end
end

-- open_shell_script: find (a name with no `/` that isn't in the cwd is looked for on $PATH:
-- find_path_file), read, and vet the script. Returns its text, or nil after reporting.
local function open_script(sh, inv, path)
	local f, emsg, errno = io.open(path, "r")
	if not f and errno == 2 and not path:find("/", 1, true) then
		for dir in (sh:get("PATH") .. ":"):gmatch("([^:]*):") do
			local cand = (dir == "" and "." or dir) .. "/" .. path
			local g = io.open(cand, "r")
			if g and g:read(0) then -- (a readable file, not a directory)
				f, inv.found = g, cand
				break
			elseif g then
				g:close()
			end
		end
	end
	local s
	if f then
		s, emsg, errno = f:read("*a")
		f:close()
	end
	if not s then
		-- bash: a missing script is `ARGV0: PATH: No such file or directory`, 127; any other
		-- open failure 126; a read failure (a directory) is labeled with the script's own
		-- name ($0 by then); errexit reclassifies either as 1
		local label = f and path or inv.name
		err(label .. ": " .. path .. ": " .. ((emsg or ""):match("([^:]+)$") or "No such file or directory"):gsub("^ ", "") .. "\n")
		sh.status = sh.opt_e and 1 or (not f and errno == 2) and 127 or 126
		return nil
	end
	-- check_binary_file (general.c): an ELF header, or a NUL in the first line (the first
	-- two, after a `#!` line) of the first 80 bytes
	if s:find("\0", 1, true) or s:sub(1, 4) == "\127ELF" then
		local sample = s:sub(1, 80)
		local bin = sample:sub(1, 4) == "\127ELF"
		if not bin then
			local nl = sample:sub(1, 2) == "#!" and 2 or 1
			for k = 1, #sample do
				local b = sample:byte(k)
				if b == 10 then
					nl = nl - 1
					if nl == 0 then
						break
					end
				elseif b == 0 then
					bin = true
					break
				end
			end
		end
		if bin then
			err(path .. ": " .. path .. ": cannot execute binary file\n")
			sh.status = 126
			return nil
		end
		s = s:gsub("%z", "") -- (shell_getc drops the NUL bytes of a script's text)
	end
	-- (shell_getc ends the last line with a newline: a final `\` is a line continuation)
	if s ~= "" and s:byte(-1) ~= 10 then
		s = s .. "\n"
	end
	return s
end

-- -D / --dump-strings / --dump-po-strings: the $"…" strings, in order, nothing run
local function dump_strings(src, po, label)
	local out, i, n, line, dq = {}, 1, #src, 1, false
	while i <= n do
		local c = src:sub(i, i)
		if c == "\n" then
			line = line + 1
		elseif c == "\\" then
			i = i + 1
			if src:sub(i, i) == "\n" then
				line = line + 1
			end
		elseif c == '"' then
			dq = not dq
		elseif not dq and c == "'" then
			local j = src:find("'", i + 1, true) or n
			local _, nls = src:sub(i, j):gsub("\n", "")
			line, i = line + nls, j
		elseif not dq and c == "#" and (i == 1 or src:sub(i - 1, i - 1):find("[%s;&|()]")) then
			i = (src:find("\n", i, true) or n + 1) - 1
		elseif not dq and c == "$" and src:sub(i + 1, i + 1) == '"' then
			local j = i + 2
			while j <= n and src:sub(j, j) ~= '"' do
				j = j + (src:sub(j, j) == "\\" and 2 or 1)
			end
			local s = src:sub(i + 2, j - 1)
			if po then
				out[#out + 1] = "#: " .. label .. ":" .. line .. '\nmsgid "' .. s .. '"\nmsgstr ""\n'
			else
				out[#out + 1] = '"' .. s .. '"\n'
			end
			local _, nls = s:gsub("\n", "")
			line, i = line + nls, j
		end
		i = i + 1
	end
	io.write(table.concat(out))
end

-- --pretty-print (eval.c pretty_print_loop): each command as bash prints it (posix
-- style), a blank/comment-only stretch as one empty line; nothing is run
local function pretty_print(sh, src)
	local P, D = require("parser"), require("deparse")
	local ok, ast = pcall(P.parse, src)
	local out, lastnl, prev = {}, false, 1
	local dp = D.posix
	D.posix = true
	for _, lg in ipairs(ok and ast.lines or {}) do
		if lg.perr then
			break
		end
		local _, nls = src:sub(prev, (lg.spos or prev) - 1):gsub("\n", "")
		if nls >= (prev == 1 and 1 or 2) and not lastnl then
			out[#out + 1] = "\n"
		end
		local t = {}
		for k, st in ipairs(lg.stmts) do
			t[k] = D.command_text(st)
		end
		out[#out + 1] = table.concat(t, "; ") .. "\n"
		lastnl, prev = false, lg.pos or prev
	end
	D.posix = dp
	if not lastnl then
		out[#out + 1] = "\n"
	end
	io.write(table.concat(out))
	if not ok or (ast.lines[#ast.lines] or {}).perr then
		sh.opt_n = true -- (report the syntax error as a run would, executing nothing)
		require("tier").run_tiered(src, sh)
		sh.status = 1
	else
		sh.status = 0
	end
end

-- Set up `sh` for the parsed invocation (options, $0 and the positional parameters, the
-- startup files) and say what to run. `istty` (for a caller that knows): stdin and stderr
-- are terminals — probed when nil.
function M.start(sh, inv, istty)
	local name, args = inv.name, inv.argv
	local base = name:match("[^/]*$")
	local login = inv.login or name:byte(1) == 45 -- (--login, -l, or '-bash': a login shell)
	if base:byte(1) == 45 then
		base = base:sub(2)
	end
	sh.shellname = base ~= "" and base or "bash"
	-- invoked as sh (act_like_sh): ~/.profile and $ENV, not $BASH_ENV; posix mode after the
	-- startup files (as run.lua did, dash/ash count too)
	local sh_like = base == "sh" or base == "dash" or base == "ash"
	sh.argv0 = name
	local I = require("interp")
	local set_opt = I._int.set_opt
	if inv.posix then
		set_opt(sh, "opt_posix", true)
	end
	sh.line_editing = not inv.noediting -- (bash's no_line_editing; -o emacs/vi turn it back on)
	for _, s in ipairs(inv.sets) do
		if s[1] ~= "opt_r" then
			set_opt(sh, s[1], s[2])
		end
	end
	local le0 = sh.line_editing
	local restricted = inv.restricted or base == "rbash"
	for _, s in ipairs(inv.sets) do
		if s[1] == "opt_r" then
			restricted = s[2]
		end
	end
	if inv.verbose then
		sh.opt_v = true
	end
	inv.login_shell = login
	if login then
		sh.shopt.login_shell = true
		sh.login_shell = true
	end
	if restricted then
		sh.shopt.restricted_shell = true
	end
	-- what to run: -c's string, a script, else stdin (interactive on a terminal)
	local code, i, n = inv.code, inv.i, #args
	local kind, payload = "code", code
	if not code then
		if args[i] and not inv.stdin then
			kind, payload = "file", args[i]
			i = i + 1
		else
			kind = "stdin"
		end
	end
	local interactive = inv.forced_i
	if interactive == nil and kind == "stdin" then
		if istty == nil then
			istty = ffi.C.isatty(0) == 1 and ffi.C.isatty(2) == 1
		end
		interactive = istty
	end
	if interactive then
		sh.opt_i = true
		if kind == "stdin" then
			kind = "repl"
		end
		sh.shopt.expand_aliases = true -- (init_interactive: expand_aliases = interactive_shell)
		-- (initialize_shell_variables: an interactive shell's MAILCHECK, an integer)
		if sh.vars.MAILCHECK == nil then
			sh:set_str("MAILCHECK", sh.opt_posix and "600" or "60")
		end
		sh.vars.MAILCHECK.int = true
		if sh.vars.PS1 == nil then
			sh:set_str("PS1", "\\s-\\v\\$ ")
		end
		if sh.vars.PS2 == nil then
			sh:set_str("PS2", "> ")
		end
		if sh.vars.HISTFILE == nil then -- (an interactive shell sets $HISTFILE, even `-i -c`)
			sh:set_str("HISTFILE", (os.getenv("HOME") or "") .. "/.bash_history")
			sh.histfile_default = true
		end
	else
		sh.line_editing = nil -- (init_noninteractive)
		for _, v in ipairs({ "PS1", "PS2" }) do -- (a non-interactive shell unbinds them)
			if sh.vars[v] then
				sh.vars[v] = nil
				ffi.C.unsetenv(v)
			end
		end
	end
	-- -O shopts (run_shopt_alist)
	if inv.shopts then
		local valid = I._int.SHOPT_DEFAULT
		for _, so in ipairs(inv.shopts) do
			if valid and valid[so[1]] == nil then
				err(name .. ": line 0: " .. so[1] .. ": invalid shell option name\n")
				sh.status = 2
				return "exit"
			end
			sh.shopt[so[1]] = so[2]
		end
	end
	if sh.lc_startup_warn then -- (set_default_lang's setlocale failure, in shell_initialize)
		err(name .. ": " .. sh.lc_startup_warn .. "\n")
		sh.lc_startup_warn = nil
	end
	-- the environment's exported functions and $SHELLOPTS (shell_initialize: after the
	-- command-line options, so --posix gates the function names)
	if sh.fimports then
		rt.import_functions(sh)
	end
	if sh.shellopts_import then
		for o in sh.shellopts_import:gmatch("[^:]+") do
			if rt.SETOPT[o] then
				sh[rt.SETOPT[o]] = true
			end
		end
	end
	if inv.lists then -- bare -o/+o/-O/+O (the -o listing shows the invocation defaults)
		local em = sh.line_editing
		for _, l in ipairs(inv.lists) do
			if l == "-o" or l == "+o" then
				sh.line_editing = le0 -- (listed before init_noninteractive)
				require(rt.BUILTIN_LAZY.set)(sh, "set", { "set", l })
				sh.line_editing = em
			else
				require(rt.BUILTIN_LAZY.shopt)(sh, "shopt", l == "" and { "shopt" } or { "shopt", l })
			end
		end
		io.flush()
	end
	-- $0 and the positional parameters (bind_args), before the startup files run
	if kind == "code" then
		sh.opt_c = true
		sh:set_str("BASH_EXECUTION_STRING", code)
		if args[i] then
			sh.argv0 = args[i]
			i = i + 1
		end
	else
		if kind ~= "file" then
			sh.opt_s = true
		end
	end
	if inv.stdin then
		sh.opt_s = true
	end
	for j = i, n do
		sh.nparams = sh.nparams + 1
		sh.params[sh.nparams] = args[j]
	end
	if kind == "file" then
		sh.argv0 = payload -- ($0 is the script's name during the startup files too)
	end
	-- the startup files, with errexit off; an `exit` in one ends the shell
	if login or inv.rcfile or sh.opt_i or sh.vars.BASH_ENV then
		local e = sh.opt_e
		sh.opt_e = false
		local ok, x = pcall(startup_files, sh, inv, sh_like)
		sh.opt_e = e
		if not ok then
			if type(x) == "table" and x.__curse_exit then
				io.flush()
				sh.status = x.__curse_exit
				return "exit"
			end
			error(x, 0)
		end
		sh.status = 0
	end
	if sh_like then
		set_opt(sh, "opt_posix", true)
	end
	if restricted then
		rt.make_restricted(sh)
	end
	if kind == "file" then
		payload = open_script(sh, inv, payload)
		if not payload then
			return "exit"
		end
		sh.main_source = inv.found -- (found on $PATH: BASH_SOURCE is the full path, $0 the name)
	end
	if inv.dump or inv["dump-strings"] or inv["dump-po-strings"] then
		if kind == "code" or kind == "file" then
			dump_strings(payload, inv["dump-po-strings"], kind == "code" and "-c" or sh.argv0)
		end
		sh.status = 0
		return "exit"
	end
	if inv["pretty-print"] and not sh.opt_i and (kind == "code" or kind == "file") then
		pretty_print(sh, payload)
		return "exit"
	end
	return kind, payload
end

return M
