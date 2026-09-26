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
local Invoke = require("invoke") -- the invocation (options, startup files): shared with the daemon

-- argv as the shell got it. argv[0] is its name (error prefix, \s, sh => posix mode): the
-- launcher's $0 forwarded as CURSE_ARGV0, else ours — the static binary's argv[0], or for
-- the dev `luajit lua/run.lua` form, plain bash.
local a0 = os.getenv("CURSE_ARGV0") or arg[0] or "bash"
if a0:find("run%.lua$") then
	a0 = "bash"
end
local argv = { a0 }
for k = 1, #arg do
	argv[k + 1] = arg[k]
end

-- Dev form: `run.lua SCRIPT MODE [args]` — a mode keyword right after the script picks the
-- execution tier (else it and the rest are the script's positional parameters).
local MODES = { tiered = true, compiled = true, interp = true, cached = true }

local function finish(sh)
	-- Propagate $? as the process exit code (so `exit N`, `false`, etc. are visible to
	-- the caller). Background jobs finish before the process can; flush stdout first.
	io.flush()
	rt.sched_drain()
	io.flush()
	os.exit(sh and sh.status or 0)
end

-- (the shell first: its startup locale is the one invocation errors and --help speak)
local sh = rt.Shell.new()
local inv, st = Invoke.parse(argv)
if not inv then
	io.flush()
	os.exit(st)
end
local mode = "tiered"
do -- (a mode keyword after the script: not a positional parameter)
	local si = inv.i
	if not inv.code and not inv.stdin and argv[si] and MODES[argv[si + 1]] then
		mode = argv[si + 1]
		table.remove(argv, si + 1)
	end
end
rt.shlvl_start(sh) -- (a new shell: $SHLVL + 1, exported)
rt.startup_ignored(sh) -- signals ignored at entry stay ignored (untrappable)
rt.sig_setup(sh) -- (SIGQUIT ignored; SIGINT's default, not luajit's `interrupted!`)
local kind, src = Invoke.start(sh, inv)
if kind == "exit" then
	finish(sh)
elseif kind == "repl" or kind == "stdin" then
	require("repl").run(sh) -- (non-interactive "stdin": line at a time from fd 0, bash)
	finish(sh)
elseif sh.opt_t and kind ~= "code" then -- (started -t: one command, read by the interpreter)
	interp.run_lazy(sh, src)
elseif kind == "code" or mode == "tiered" then
	-- interpret, and switch to compiled code where a loop turns hot (compiled into the
	-- shared cache, so the next run starts compiled) — the daemon's own path
	local T = require("tier")
	T.run_tiered(src, sh)
	pcall(T.flush_stores)
elseif mode == "cached" then
	-- persistent artifact cache: warm hit skips parse+emit; cold compiles+stores; any
	-- cache failure falls back to running uncached (reported on stderr for visibility)
	local _, how = require("cache").run(src, sh)
	if os.getenv("CURSE_CACHE_DEBUG") then
		io.stderr:write("[cache: " .. how .. "]\n")
	end
elseif mode == "compiled" then
	local T = require("tier") -- pulls emit + cache; only the compiled path needs them
	-- The compiler THROWS `curse-nocompile:` for a program it can't faithfully compile
	-- (e.g. alias expansion, which needs line-at-a-time parsing). That's the honest
	-- tiered behavior — run it in the interpreter, exactly as the daemon/cache path does
	-- on the same signal. Any OTHER compile error still propagates.
	local sa = (sh.opt_a or sh.opt_r) or nil -- (started allexport/restricted: tier.run_tiered)
	local pst = ((sh.opt_posix and "p" or "") .. (sh.shopt.extglob and "x" or "")):match(".+") -- (tier.parse_start)
	T.note_text(sh, src)
	sh.main_src = sh.main_src or src
	local ok, mod = pcall(T.compile, T.parse_start(src, pst), (sh.opt_x or sa) and { xtrace = sh.opt_x, startattr = sa } or nil)
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
else -- interp
	interp.run_lazy(sh, src) -- lazy: instant start, never parses past exit
end
finish(sh)
