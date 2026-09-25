-- curse LuaJIT-backend entry point.
--   luajit lua/run.lua <script.sh> [tiered|compiled|interp]
-- Modes:
--   tiered   (default) interpret from t=0 while a detached process transpiles,
--            then OSR into the compiled Lua. Needs $CURSE_LUAJIT (or "luajit").
--   compiled transpile + load + run (no interpreter window) — steady-state speed.
--   interp   pure tree-walking interpreter.
-- Prefer a precompiled bytecode bundle (one file open, no source parsing —
-- ~1ms/invocation faster). Fall back to loading modules from source if the
-- bundle is absent or unloadable (e.g. built for a different LuaJIT).
-- The bundle registers all curse modules into package.preload. A self-contained
-- static binary has it EMBEDDED (curse_load_bundle in luajit.c ran it before us),
-- so the modules are already preloaded — skip the disk load entirely. Otherwise
-- load dist/curse.bc from disk, falling back to source on the package path.
if not package.preload["tier"] then
	-- Source fallback path, made ABSOLUTE from the startup cwd: modules (incl. the
	-- lazy b_* builtins) may require() mid-script, after the script has cd'd, so a
	-- relative "lua/?.lua" would then miss. (The bundle path preloads everything and
	-- doesn't hit this.)
	local dir = arg[0] and arg[0]:match("^(.*)/[^/]+$") or "lua"
	if dir:sub(1, 1) ~= "/" then
		dir = (os.getenv("PWD") or ".") .. "/" .. dir
	end
	local srcpath = dir .. "/?.lua;"
	local bundle = os.getenv("CURSE_BUNDLE") or "dist/curse.bc"
	local bf = io.open(bundle, "rb")
	if bf then
		bf:close()
		if not pcall(function()
			assert(loadfile(bundle))()
		end) then
			package.path = srcpath .. package.path
		end
	else
		package.path = srcpath .. package.path
	end
end
-- Require only what the chosen mode needs. runtime + interp (which pulls parser)
-- cover the interp and interactive paths; the compile/tier machinery (tier -> emit
-- + cache, ~0.18ms of load+init) is pulled in lazily ONLY by the compiled/tiered/
-- cached branches below. A plain `interp` or interactive start never loads emit.
local rt = require("runtime")
local interp = require("interp")

local sh

-- Collect leading shell options (as `sh -e -u -o NAME -O NAME` before -c/script).
local ai, presets = 1, {}
local rcfile, norc -- --rcfile FILE / --norc: an interactive shell sources FILE first
while true do
	local a = arg[ai]
	if a == "-e" or a == "+e" then
		presets[#presets + 1] = { f = "opt_e", on = a == "-e" }
		ai = ai + 1
	elseif a == "-i" then
		presets[#presets + 1] = { f = "opt_i", on = true }
		ai = ai + 1
	elseif a == "-x" or a == "+x" then
		presets[#presets + 1] = { f = "opt_x", on = a == "-x" }
		ai = ai + 1
	elseif a == "-v" or a == "+v" then
		presets[#presets + 1] = { f = "opt_v", on = a == "-v" }
		ai = ai + 1
	elseif
		a == "-l"
		or a == "--login"
		or a == "-s"
		or a == "-B"
		or a == "+B"
		or a == "-h"
		or a == "+h"
	then
		ai = ai + 1 -- accepted, no-op
	elseif a == "--help" then
		io.write("curse: a bash-compatible shell.\nusage: curse [options] [script [args]]\n")
		os.exit(0)
	elseif a == "--" or a == "-" then
		ai = ai + 1
		break -- end of options (script/args follow)
	elseif a == "-u" or a == "+u" then
		presets[#presets + 1] = { f = "opt_u", on = a == "-u" }
		ai = ai + 1
	elseif a == "-C" or a == "+C" then
		presets[#presets + 1] = { f = "opt_C", on = a == "-C" }
		ai = ai + 1
	elseif a == "-o" or a == "+o" then
		presets[#presets + 1] = { o = arg[ai + 1], on = a == "-o" }
		ai = ai + 2
	elseif a == "-O" or a == "+O" then
		presets[#presets + 1] = { shopt = arg[ai + 1], on = a == "-O" }
		ai = ai + 2
	elseif a == "--norc" or a == "--noprofile" then
		norc = true
		ai = ai + 1
	elseif a == "--rcfile" then
		rcfile = arg[ai + 1]
		ai = ai + 2
	elseif a and a:match("^%-[eiuxCoOlvsBhc]+$") and #a > 2 then
		-- bundled short flags: `-eu`, `-oo errexit noglob`, `-ex`, `-uc CMD` … (bash
		-- bundles single-char options; each `o`/`O` in the bundle takes the NEXT word as
		-- its argument, consumed left-to-right; a `c` is re-queued as a plain `-c`).
		local wi, has_c = ai, false
		for k = 2, #a do
			local f = a:sub(k, k)
			if f == "e" then
				presets[#presets + 1] = { f = "opt_e", on = true }
			elseif f == "u" then
				presets[#presets + 1] = { f = "opt_u", on = true }
			elseif f == "x" then
				presets[#presets + 1] = { f = "opt_x", on = true }
			elseif f == "v" then
				presets[#presets + 1] = { f = "opt_v", on = true }
			elseif f == "C" then
				presets[#presets + 1] = { f = "opt_C", on = true }
			elseif f == "i" then
				presets[#presets + 1] = { f = "opt_i", on = true }
			elseif f == "o" then
				wi = wi + 1
				presets[#presets + 1] = { o = arg[wi], on = true }
			elseif f == "O" then
				wi = wi + 1
				presets[#presets + 1] = { shopt = arg[wi], on = true }
			elseif f == "c" then
				has_c = true
			end -- l/s/B/h: accepted no-ops
		end
		ai = wi + 1
		if has_c then
			ai = ai - 1
			arg[ai] = "-c" -- (the bundle's last consumed word slot now holds the -c)
		end
	elseif a and a:sub(1, 2) == "--" then
		-- an unrecognized long option (e.g. bash rejects `--rcdir`) is a usage error
		io.stderr:write("curse: " .. a .. ": invalid option\n")
		io.flush()
		os.exit(2)
	else
		break
	end
end
-- `-o NAME` / `+o NAME`: same long-option names as the `set -o` builtin.
local OMAP = {
	errexit = "opt_e",
	errtrace = "opt_errtrace",
	functrace = "opt_functrace",
	hashall = "opt_h",
	histexpand = "opt_H",
	history = "opt_history",
	ignoreeof = "opt_ignoreeof",
	["interactive-comments"] = "opt_icomments",
	keyword = "opt_k",
	monitor = "opt_m",
	noclobber = "opt_C",
	noexec = "opt_n",
	noglob = "opt_f",
	nolog = "opt_nolog",
	notify = "opt_b",
	nounset = "opt_u",
	onecmd = "opt_t",
	physical = "opt_P",
	pipefail = "opt_pipefail",
	posix = "opt_posix",
	privileged = "opt_p",
	verbose = "opt_v",
	vi = "opt_vi",
	xtrace = "opt_x",
}
-- Which shell are we mimicking? By our invocation basename, like busybox/bash
-- (bash run as `sh` goes posix). The wrapper/launcher forwards its $0 as
-- CURSE_ARGV0; absent that, we default to bash. Drives \s (prompt) and, for a
-- posix-named invocation, posix mode.
local SHELLNAME = (os.getenv("CURSE_ARGV0") or arg[0] or "bash"):match("[^/]+$") or "bash"
local SH_IS_POSIX = SHELLNAME == "sh" or SHELLNAME == "dash" or SHELLNAME == "ash"
-- Default interactive prompt. bash's own compiled default is `\s-\v\$ `, but Debian's
-- /etc/bash.bashrc (read for interactive shells even under --rcfile) sets this one, and
-- curse impersonates Debian bash — so an interactive shell with PS1 unset gets it. Set
-- BEFORE the rcfile so a user's rc can still override it. `[[ ]]` keeps the backslashes
-- literal (they are prompt escapes, decoded later by ${PS1@P}).
local DEFAULT_PS1 = [[${debian_chroot:+($debian_chroot)}\u@\h:\w\$ ]]
local function apply(s)
	s.shellname = SHELLNAME
	rt.shlvl_start(s) -- (a new shell: $SHLVL + 1, exported)
	rt.startup_ignored(s) -- signals ignored at entry stay ignored (untrappable)
	if s.fimports then
		rt.import_functions(s) -- exported functions (BASH_FUNC_name%%) from the environment
	end
	if SH_IS_POSIX then
		s.opt_posix = true
	end
	-- Options inherited via an exported $SHELLOPTS (set by a parent shell): enable
	-- each named set -o option we recognize, so e.g. cross-process `set -x` traces.
	if s.shellopts_import then
		for name in s.shellopts_import:gmatch("[^:]+") do
			if OMAP[name] then
				s[OMAP[name]] = true
			end
		end
	end
	for _, p in ipairs(presets) do
		if p.f then
			s[p.f] = p.on
		elseif p.o and OMAP[p.o] then
			s[OMAP[p.o]] = p.on
		elseif p.shopt then
			s.shopt[p.shopt] = p.on
		end
	end
end

-- An interactive shell sources --rcfile (unless --norc) before running -c/REPL; a
-- real `exit` in the rc file ends the whole shell here (skipping -c), like bash.
local function source_rc(sh)
	if not (sh.opt_i and rcfile and not norc) then
		return
	end
	local ok, err = pcall(interp.source_file, sh, rcfile)
	if not ok then
		if type(err) == "table" and err.__curse_exit then
			io.flush()
			os.exit(err.__curse_exit)
		else
			error(err)
		end
	end
end

-- Consume one option token into `presets`; returns tokens consumed, or 0 if `a`
-- is not a recognized option (bash accepts these both leading and after -c).
local function opt_consume(a, nexta)
	if a == "-e" or a == "+e" then
		presets[#presets + 1] = { f = "opt_e", on = a == "-e" }
		return 1
	elseif a == "-u" or a == "+u" then
		presets[#presets + 1] = { f = "opt_u", on = a == "-u" }
		return 1
	elseif a == "-C" or a == "+C" then
		presets[#presets + 1] = { f = "opt_C", on = a == "-C" }
		return 1
	elseif a == "-i" then
		presets[#presets + 1] = { f = "opt_i", on = true }
		return 1
	elseif a == "-x" or a == "+x" then
		presets[#presets + 1] = { f = "opt_x", on = a == "-x" }
		return 1
	elseif a == "-v" or a == "+v" then
		presets[#presets + 1] = { f = "opt_v", on = a == "-v" }
		return 1
	elseif
		a == "-l"
		or a == "--login"
		or a == "-s"
		or a == "-B"
		or a == "+B"
		or a == "-h"
		or a == "+h"
	then
		return 1 -- accepted, no-op
	elseif a == "-o" or a == "+o" then
		presets[#presets + 1] = { o = nexta, on = a == "-o" }
		return 2
	elseif a == "-O" or a == "+O" then
		presets[#presets + 1] = { shopt = nexta, on = a == "-O" }
		return 2
	elseif a == "--norc" or a == "--noprofile" then
		return 1
	elseif a == "--rcfile" then
		return 2
	end
	return 0
end

-- `-c CODE [name [args…]]` — run a command string like `sh -c` (`+c` is accepted).
if arg[ai] == "-c" or arg[ai] == "+c" then
	-- bash keeps parsing options after -c until a non-option word (the command
	-- string) or a terminator (`-`/`--`); an unrecognized option is a usage error.
	local j = ai + 1
	while true do
		local a = arg[j]
		if a == nil then
			io.stderr:write("curse: -c: option requires an argument\n")
			io.flush()
			os.exit(2)
		elseif a == "--" or a == "-" then
			j = j + 1
			break
		elseif a:sub(1, 1) == "-" or a:sub(1, 1) == "+" then
			local n = opt_consume(a, arg[j + 1])
			if n == 0 then
				io.stderr:write("curse: " .. a .. ": invalid option\n")
				io.flush()
				os.exit(2)
			end
			j = j + n
		else
			break
		end -- the command string
	end
	local code = arg[j]
	if code == nil then
		io.stderr:write("curse: -c: option requires an argument\n")
		io.flush()
		os.exit(2)
	end
	sh = rt.Shell.new()
	apply(sh)
	sh.opt_c = true
	-- an interactive shell sets $HISTFILE (bash), even for `-i -c`
	if sh.opt_i and sh.vars.HISTFILE == nil then
		sh:set_str("HISTFILE", (os.getenv("HOME") or "") .. "/.bash_history")
		sh.histfile_default = true
	end
	if sh.opt_i and sh.vars.PS1 == nil then
		sh:set_str("PS1", DEFAULT_PS1)
	end
	sh.argv0 = arg[j + 1] or SHELLNAME -- $0 defaults to the shell name (bash), not "curse"
	for k = j + 2, #arg do
		sh.nparams = sh.nparams + 1
		sh.params[sh.nparams] = arg[k]
	end
	source_rc(sh) -- interactive: --rcfile is sourced before the command string
	interp.run_lazy(sh, code)
	io.flush()
	require("runtime").sched_drain() -- (background jobs finish before the process can)
	io.flush()
	os.exit(sh.status or 0)
end

-- No script argument. With a tty on stdin (or -i) start the REPL; otherwise read
-- commands from stdin and run them non-interactively (e.g. `echo cmd | sh`).
if arg[ai] == nil then
	sh = rt.Shell.new()
	apply(sh)
	sh.argv0 = SHELLNAME -- $0 = the shell name (bash)
	local istty = require("ffi").C.isatty(0) == 1
	if sh.opt_i or istty then
		sh.opt_i = true
		if sh.vars.HISTFILE == nil then
			sh:set_str("HISTFILE", (os.getenv("HOME") or "") .. "/.bash_history")
			sh.histfile_default = true
		end
		if sh.vars.PS1 == nil then
			sh:set_str("PS1", DEFAULT_PS1)
		end
		source_rc(sh) -- --rcfile sourced before the interactive session
		require("repl").run(sh)
	else
		require("repl").run(sh) -- non-interactive: line at a time from fd 0 (bash)
	end
	io.flush()
	require("runtime").sched_drain() -- (background jobs finish before the process can)
	io.flush()
	os.exit(sh.status or 0)
end

local script = arg[ai] or error("usage: run.lua <script.sh> [tiered|compiled|interp] | -c CODE | -i")
-- arg[ai+1] is the execution mode ONLY if it's a known mode keyword; otherwise it
-- (and the rest) are the script's positional parameters ($1, $2, …), like bash.
local MODES = { tiered = true, compiled = true, interp = true, cached = true }
local mode, pstart = "tiered", ai + 1
if arg[ai + 1] and MODES[arg[ai + 1]] then
	mode = arg[ai + 1]
	pstart = ai + 2
end
-- A missing/unreadable script is exit 127 (bash), not a Lua assert crash — but
-- under errexit (`-e`/`-o errexit`) bash reports the open failure as exit 1
-- instead (errexit reclassifies it; nounset/xtrace/pipefail/noexec do not).
do
	local sf = io.open(script, "r")
	local errexit = false
	for _, p in ipairs(presets) do
		if p.f == "opt_e" then
			errexit = p.on
		elseif p.o and OMAP[p.o] == "opt_e" then
			errexit = p.on
		end
	end
	if sf then
		-- A NUL byte in the FIRST line makes bash treat the file as a binary and refuse
		-- it ("cannot execute binary file", 126); a NUL on a later line runs fine. Read a
		-- raw chunk (read("*l") stops AT a NUL, so it can't see one) and look before \n.
		local head = sf:read(8192) or ""
		sf:close()
		local nl = head:find("\n", 1, true)
		local first = nl and head:sub(1, nl - 1) or head
		if first:find("\0", 1, true) then
			io.stderr:write("curse: " .. script .. ": cannot execute binary file\n")
			io.flush()
			os.exit(126)
		end
	else
		io.stderr:write("curse: " .. script .. ": No such file or directory\n")
		io.flush()
		os.exit(errexit and 1 or 127)
	end
end
local function setparams(s)
	for k = pstart, #arg do
		s.nparams = s.nparams + 1
		s.params[s.nparams] = arg[k]
	end
end
if mode == "cached" then
	-- persistent artifact cache: warm hit skips parse+emit; cold compiles+stores;
	-- any cache failure falls back to running uncached. This is the CLI/build/boot
	-- path (one-shot invocations that recur), reported on stderr for visibility.
	local Cache = require("cache")
	local f = assert(io.open(script, "r"))
	local src = f:read("*a")
	f:close()
	sh = rt.Shell.new()
	apply(sh)
	sh.argv0 = script
	setparams(sh)
	local _, how = Cache.run(src, sh)
	if os.getenv("CURSE_CACHE_DEBUG") then
		io.stderr:write("[cache: " .. how .. "]\n")
	end
elseif mode == "tiered" then
	local T = require("tier") -- pulls emit + cache; only the tiered path needs them
	sh = rt.Shell.new()
	apply(sh)
	sh.argv0 = script
	setparams(sh)
	-- the daemon's own path: interpret, and switch to compiled code where a loop turns
	-- hot (compiled into the shared cache, so the next run starts compiled)
	local f = assert(io.open(script, "r"))
	local src = f:read("*a")
	f:close()
	T.run_tiered(src, sh)
	pcall(T.flush_stores)
else
	local f = assert(io.open(script, "r"))
	local src = f:read("*a")
	f:close()
	sh = rt.Shell.new()
	apply(sh)
	sh.argv0 = script
	setparams(sh)
	if mode == "compiled" then
		local T = require("tier") -- pulls emit + cache; only the compiled path needs them
		-- The compiler THROWS `curse-nocompile:` for a program it can't faithfully
		-- compile (e.g. alias expansion, which needs line-at-a-time parsing). That's the
		-- honest tiered behavior — run it in the interpreter, exactly as the daemon/cache
		-- path does on the same signal. Any OTHER compile error still propagates.
		local ok, mod = pcall(T.compile, require("parser").parse(src))
		if not ok then
			if T.lm_reason(mod) then -- (a line at a time, each line compiled: aliases, history…)
				T.run_lm(sh, src)
				pcall(T.flush_stores)
			elseif type(mod) == "string" and mod:find("curse%-nocompile") then
				interp.run_lazy(sh, src)
			else
				error(mod)
			end
		else
			interp.finish_run(sh, function()
				T.run_compiled(mod, sh, nil)
			end)
		end
	elseif mode == "interp" then
		interp.run_lazy(sh, src) -- lazy: instant start, never parses past exit
	else
		error("unknown mode: " .. mode)
	end
end

-- Propagate $? as the process exit code (so `exit N`, `false`, etc. are visible
-- to the caller — and to the spec runner). Flush buffered stdout first.
require("runtime").sched_drain() -- (background jobs finish before the process can)
io.flush()
os.exit(sh and sh.status or 0)
