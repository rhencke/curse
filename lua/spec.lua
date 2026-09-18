-- Oils spec-test conformance runner for curse (progress scoreboard, comparing
-- curse's output to the host-bash oracle). Parses Oils'
-- spec/*.test.sh cases and runs each snippet through curse-Lua.
--
--   luajit lua/spec.lua [--interp|--compiled|--cached] [--verbose] [--diff]
--                       [--live] [--divergence] [file-substr…]
--
-- ASSERTION MODEL (hybrid, user-directed). Each case carries golden metadata
-- (`## STDOUT:`/`## stdout:`/`## stdout-json:`/`## status:`, with per-shell
-- `## OK|BUG|N-I <shell> …` variants). The GOLDEN scoreboard compares curse's
-- output against the BASH-resolved expectation exactly as Oils' own sh_spec.py
-- does — status always, stdout ONLY when a stdout block is present (so
-- status-only cases like `$RANDOM`/`$PPID` are judged on status alone, which a
-- live bash-vs-curse diff can never pass). A LIVE cross-check still runs host
-- bash so we can flag where the golden files diverge from host bash 5.2.37
-- (`--divergence`), guarding the switch from the old live-diff metric.
--
-- Runs each case as a SUBPROCESS with a timeout, so a hanging/exiting/crashing
-- case can't take down the runner.
local mode = "interp"
local verbose = false
local diff = false
local show_live = false -- also print the live-bash pass total
local show_diverge = false -- list cases where golden ≠ host bash
local memprof = false -- --mem: report peak child RSS (find the OOM culprit)
local filters = {}
for _, a in ipairs(arg) do
	if a == "--interp" or a == "--compiled" or a == "--cached" then
		mode = a:sub(3)
	elseif a == "--verbose" then
		verbose = true
	elseif a == "--diff" then
		verbose = true
		diff = true
	elseif a == "--live" then
		show_live = true
	elseif a == "--divergence" or a == "--diverge" then
		show_diverge = true
		show_live = true
	elseif a == "--mem" then
		memprof = true
	elseif a:sub(1, 2) == "--" then -- ignore unknown flags
	else
		filters[#filters + 1] = a
	end
end
-- Peak-RSS watermark (--mem). getrusage(RUSAGE_CHILDREN).ru_maxrss is a MONOTONIC
-- high-water-mark (KB on Linux) over all reaped children, so a case that RAISES it just
-- set a new memory high — the escalation log names the culprits tripping the OOM guard.
-- Run on ONE file (`spec.lua --compiled --mem FILE`) to get that file's isolated peak.
local peak_kb
if memprof then
	local ffi = require("ffi")
	ffi.cdef([[ struct curse_ru { long d[18]; }; int getrusage(int who, struct curse_ru *u); ]])
	local ru = ffi.new("struct curse_ru")
	peak_kb = function()
		ffi.C.getrusage(-1, ru)
		return tonumber(ru.d[4])
	end -- CHILDREN; ru_maxrss @ d[4]
end

-- Absolute paths: each case runs in its own cwd, so the luajit binary, run.lua,
-- and the bundle must be absolute or they'd resolve against the case's cwd.
local ROOT = (io.popen("pwd"):read("*a") or ""):gsub("%s+$", "")
local SPEC = ROOT .. "/reference/oil/spec"
local LUAJIT = ROOT .. "/.bench-lua/luajit"
local RUNLUA = ROOT .. "/lua/run.lua"
local BUNDLE = ROOT .. "/dist/curse.bc"
local TIMEOUT = 2 -- cases are tiny; this only bounds hangs (e.g. `while true`)
-- The locale Oils records its golden files under (spec-common.sh). Host bash is a
-- codepoint-aware shell here, so the golden `${#μ}==1` etc. only align with a live
-- bash run under the SAME locale; curse honors this once it is locale-aware.
local LOCALE = "C.UTF-8"

-- temp workspace (per run); each case gets a fresh cwd so file side effects don't
-- leak between cases.
local TMPROOT = os.getenv("TMPDIR") or "/tmp"
-- /tmp is often a tmpfs (RAM-backed): a run killed before its cleanup (line ~end)
-- leaks its whole workspace into RAM. Reap any stale ones (>30 min old, so a
-- concurrent run's is never touched) at startup so leaks can't accumulate.
os.execute("find " .. TMPROOT .. " -maxdepth 1 -name 'curse-spec-*' -mmin +30 -exec rm -rf {} + 2>/dev/null")
local TMP = TMPROOT .. "/curse-spec-" .. tostring(os.time())
os.execute("mkdir -p " .. TMP)

-- curse is `luajit run.lua`; wrap it in a tiny exec script named after the shell
-- we're impersonating (SHNAME="bash"), living ALONE in SHBIN so we can put it
-- first on the tested shell's PATH. This models "curse installed as /bin/bash".
local SHNAME = "bash"
local SHBIN = TMP .. "/shbin"
os.execute("mkdir -p " .. SHBIN)
local SH = SHBIN .. "/" .. SHNAME
do
	local f = io.open(SH, "w")
	f:write(
		"#!/bin/sh\nexport CURSE_BUNDLE="
			.. BUNDLE
			.. ' CURSE_ARGV0="$0"\nexec '
			.. LUAJIT
			.. " "
			.. RUNLUA
			.. ' "$@"\n'
	)
	f:close()
	os.execute("chmod +x " .. SH)
end

local function readfile(p)
	local f = io.open(p, "r")
	if not f then
		return nil
	end
	local s = f:read("*a")
	f:close()
	return s
end

-- A case is OSH/YSH-specific — NOT a bash-behavior test — when its `case $SH in
-- … esac` guard sends bash to exit/return (bash skips the whole case).
local function osh_only(code)
	for seg in code:gmatch("case%s+%$SH%s+in(.-)esac") do
		for pats, bw in seg:gmatch("([%w%*%?@_%-%.:| ]+)%)%s*(%a+)") do
			if bw == "exit" or bw == "return" then
				for alt in (pats .. "|"):gmatch("%s*([%w%*%?@_%-%.:]+)%s*|") do
					local pat = "^" .. alt:gsub("[%.%-]", "%%%0"):gsub("%*", ".*"):gsub("%?", ".") .. "$"
					if ("bash"):match(pat) then
						return true
					end
				end
			end
		end
	end
	return false
end

-- ---- J8/JSON string decoder for `## stdout-json: "…"` (exact expected bytes) ----
-- `\uXXXX` and `\u{…}` are codepoints -> UTF-8 bytes; `\xXX` is a raw byte; plus
-- the usual \n \t \r \\ \" \/ \b \f \0.
local function utf8_encode(cp)
	if cp < 0x80 then
		return string.char(cp)
	elseif cp < 0x800 then
		return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
	elseif cp < 0x10000 then
		return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
	else
		return string.char(
			0xF0 + math.floor(cp / 0x40000),
			0x80 + math.floor(cp / 0x1000) % 0x40,
			0x80 + math.floor(cp / 0x40) % 0x40,
			0x80 + cp % 0x40
		)
	end
end
local function json_decode(s)
	-- s includes the surrounding quotes; strip them.
	s = s:match('^%s*"(.*)"%s*$') or s
	local o, i, n = {}, 1, #s
	while i <= n do
		local c = s:sub(i, i)
		if c == "\\" then
			local e = s:sub(i + 1, i + 1)
			if e == "n" then
				o[#o + 1] = "\n"
				i = i + 2
			elseif e == "t" then
				o[#o + 1] = "\t"
				i = i + 2
			elseif e == "r" then
				o[#o + 1] = "\r"
				i = i + 2
			elseif e == "b" then
				o[#o + 1] = "\b"
				i = i + 2
			elseif e == "f" then
				o[#o + 1] = "\f"
				i = i + 2
			elseif e == "0" then
				o[#o + 1] = "\0"
				i = i + 2
			elseif e == "\\" or e == '"' or e == "/" then
				o[#o + 1] = e
				i = i + 2
			elseif e == "x" then
				o[#o + 1] = string.char(tonumber(s:sub(i + 2, i + 3), 16) or 0)
				i = i + 4
			elseif e == "u" then
				if s:sub(i + 2, i + 2) == "{" then
					local hex = s:match("^{(%x+)}", i + 2)
					o[#o + 1] = utf8_encode(tonumber(hex, 16) or 0)
					i = i + 2 + #hex + 2
				else
					o[#o + 1] = utf8_encode(tonumber(s:sub(i + 2, i + 5), 16) or 0)
					i = i + 6
				end
			else
				o[#o + 1] = e
				i = i + 2
			end
		else
			o[#o + 1] = c
			i = i + 1
		end
	end
	return table.concat(o)
end

-- Does a `## OK|BUG|N-I <shells> …` variant apply to bash? (shells are `/`-joined)
local function shells_match_bash(shells)
	for sh in (shells .. "/"):gmatch("([%w]+)/") do
		if sh == "bash" or sh == "osh" then
			return true
		end
	end
	return false
end

-- ---- case parser: capture CODE and the golden META region for each case ----
local function parse_cases(text)
	local cases, cur, inMeta = {}, nil, false
	for line in (text .. "\n"):gmatch("(.-)\n") do
		local name = line:match("^#### (.*)")
		if name then
			if cur then
				cases[#cases + 1] = cur
			end
			cur = { name = name, code = {}, meta = {} }
			inMeta = false
		elseif cur then
			if line == "##" or line:sub(1, 3) == "## " then
				inMeta = true
				cur.meta[#cur.meta + 1] = line
			elseif inMeta then
				cur.meta[#cur.meta + 1] = line -- block body (e.g. STDOUT lines up to ## END)
			else
				cur.code[#cur.code + 1] = line
			end
		end
	end
	if cur then
		cases[#cases + 1] = cur
	end
	local out = {}
	for _, c in ipairs(cases) do
		c.code = table.concat(c.code, "\n")
		if c.code:match("%S") and not osh_only(c.code) then
			out[#out + 1] = c
		end
	end
	return out
end

-- Resolve the BASH expectation from a case's meta region. Returns
-- { status = N, out = STR|nil, check_out = bool }. A bash-specific variant
-- (OK/BUG/N-I bash) overrides the default block for its channel.
local function parse_meta(meta)
	-- Collect candidate values per channel; `bash` variants beat the default.
	local status = { def = nil, bash = nil }
	local stdout = { def = nil, bash = nil } -- string value, or false to mean "block present but empty"
	local i, m = 1, #meta
	while i <= m do
		local line = meta[i]
		-- optional variant prefix: `## OK|BUG|N-I <shells> `
		local rest = line:match("^##%s+(.*)$")
		if rest then
			local kind, shells, tail = rest:match("^(OK)%s+([%w/]+)%s+(.*)$")
			if not kind then
				kind, shells, tail = rest:match("^(BUG)%s+([%w/]+)%s+(.*)$")
			end
			if not kind then
				kind, shells, tail = rest:match("^(N%-I)%s+([%w/]+)%s+(.*)$")
			end
			local bashvar = kind and shells_match_bash(shells)
			local body = tail or rest -- the channel directive (no variant prefix)
			-- status
			local st = body:match("^status:%s*(%-?%d+)")
			if st then
				if kind == nil then
					status.def = tonumber(st)
				elseif bashvar then
					status.bash = tonumber(st)
				end
			-- single-line stdout
			elseif body:match("^stdout:") then
				local v = body:match("^stdout:%s?(.*)$") or ""
				v = v .. "\n"
				if kind == nil then
					stdout.def = v
				elseif bashvar then
					stdout.bash = v
				end
			elseif body:match("^stdout%-json:") then
				local v = json_decode(body:match("^stdout%-json:%s*(.*)$") or "")
				if kind == nil then
					stdout.def = v
				elseif bashvar then
					stdout.bash = v
				end
			elseif body:match("^STDOUT:") then
				-- multi-line block until `## END`
				local lines = {}
				i = i + 1
				while
					i <= m
					and not meta[i]:match("^##%s+END")
					and not meta[i]:match("^##%s*$")
					and meta[i] ~= "## END"
				do
					-- stop if another directive starts (defensive; blocks normally end at ## END)
					if
						meta[i]:match("^##%s+%u")
						or meta[i]:match("^##%s+OK")
						or meta[i]:match("^##%s+BUG")
						or meta[i]:match("^##%s+N%-I")
					then
						break
					end
					lines[#lines + 1] = meta[i]
					i = i + 1
				end
				local v = #lines > 0 and (table.concat(lines, "\n") .. "\n") or ""
				if kind == nil then
					stdout.def = v
				elseif bashvar then
					stdout.bash = v
				end
			end
		end
		i = i + 1
	end
	local out = stdout.bash ~= nil and stdout.bash or stdout.def
	return {
		status = status.bash ~= nil and status.bash or (status.def ~= nil and status.def or 0),
		out = out,
		check_out = out ~= nil,
	}
end

-- Run a shell command string with a timeout in `cwd`; stdout + exit status.
local outp = TMP .. "/out"
local stp = TMP .. "/st"
local BINPATH = SPEC .. "/bin:" .. ROOT .. "/.bench-lua/shim" -- argv.py + python2 shim
local CAP = 4000000
local function run(cmdstr, cwd, shval, pathpre)
	os.execute(
		"cd "
			.. cwd
			.. " && { export LC_ALL="
			.. LOCALE
			.. " TMP="
			.. cwd
			.. " TMPDIR="
			.. cwd
			.. " SH='"
			.. shval
			.. "' CURSE_BUNDLE="
			.. BUNDLE
			.. " PATH="
			.. (pathpre or "")
			.. BINPATH
			.. ":$PATH; timeout "
			.. TIMEOUT
			.. " "
			.. cmdstr
			.. " ; echo $? >"
			.. stp
			.. "; } 2>/dev/null | head -c "
			.. CAP
			.. " >"
			.. outp
	)
	return readfile(outp) or "", tonumber((readfile(stp) or "0"):match("%d+") or "0")
end

-- ---- list spec files ----
local files = {}
do
	local p = io.popen("ls " .. SPEC .. "/*.test.sh 2>/dev/null")
	if p then
		for line in p:lines() do
			files[#files + 1] = line
		end
		p:close()
	end
end
local function is_oil(path)
	local b = path:match("[^/]+$") or ""
	return b:match("^ysh%-") or b:match("^hay") or b:match("^tea") or b:match("^osh%-") or b:match("%-osh%.test") -- OSH-specific files
end
if #filters > 0 then
	local kept = {}
	for _, f in ipairs(files) do
		for _, s in ipairs(filters) do
			if f:find(s, 1, true) then
				kept[#kept + 1] = f
				break
			end
		end
	end
	files = kept
else
	local kept = {}
	for _, f in ipairs(files) do
		if not is_oil(f) then
			kept[#kept + 1] = f
		end
	end
	files = kept
end

local codep = TMP .. "/case.sh"
local function write_code(code)
	local f = io.open(codep, "w")
	f:write(code)
	f:close()
end

local function curse_cmd()
	local haveb = io.open(BUNDLE, "r")
	if haveb then
		haveb:close()
	end
	local envp = "env CURSE_ARGV0=" .. SH .. (haveb and (" CURSE_BUNDLE=" .. BUNDLE) or "") .. " "
	return envp .. LUAJIT .. " " .. RUNLUA .. " " .. codep .. " " .. mode
end

-- THREE metrics, per case:
--  (1) golden : curse vs the recorded golden (status always; stdout iff a block).
--  (2) live   : curse vs host bash, BOTH stdout and status (the old metric).
--  (3) STRUCT : curse vs host bash for VALUES, but stdout checked ONLY when the
--               golden asserts stdout — Oils' pass STRUCTURE against the honest
--               host-bash-5.2.37 oracle. PRIMARY scoreboard: it penalizes neither
--               nondeterministic output (status-only cases) NOR stale goldens
--               (pinned to old bash), so it is the real "curse == host bash, judged
--               as Oils judges" number we drive to 100%.
local total, goldPass, livePass, structPass, divergences = 0, 0, 0, 0, 0
local perFile = {}
local mem_peak, mem_log = 0, {} -- --mem: running peak (KB) and the new-high escalation log
for _, path in ipairs(files) do
	local cases = parse_cases(readfile(path) or "")
	local cwd = TMP .. "/cwd"
	os.execute("rm -rf " .. cwd .. "; mkdir -p " .. cwd)
	local gp, lp, sp = 0, 0, 0
	for _, c in ipairs(cases) do
		local exp = parse_meta(c.meta)
		write_code(c.code)
		local bout, bst = run("bash " .. codep, cwd, SHNAME) -- oracle: clean PATH -> real bash
		os.execute("rm -rf " .. cwd .. "/* 2>/dev/null")
		local cout, cst = run(curse_cmd(), cwd, SHNAME, SHBIN .. ":") -- curse: SHBIN first -> `bash` = curse
		os.execute("rm -rf " .. cwd .. "/* 2>/dev/null")
		if memprof then -- a new peak = this case (its bash or curse child) is a memory high
			local p = peak_kb()
			if p > mem_peak then
				mem_log[#mem_log + 1] = { kb = p, prev = mem_peak, file = path:match("[^/]+$"), case = c.name }
				mem_peak = p
			end
		end
		local gok = (cst == exp.status) and (not exp.check_out or cout == exp.out)
		local lok = (cout == bout) and (cst == bst)
		local sok = (cst == bst) and (not exp.check_out or cout == bout)
		if gok then
			gp = gp + 1
		end
		if lok then
			lp = lp + 1
		end
		if sok then
			sp = sp + 1
		end
		if show_diverge and (bst ~= exp.status or (exp.check_out and bout ~= exp.out)) then
			divergences = divergences + 1
			io.write(
				("  DIVERGE %s: %s\n    golden=[%s](%d) hostbash=[%s](%d)\n"):format(
					path:match("[^/]+$"),
					c.name,
					exp.check_out and exp.out:gsub("\n", "\\n") or "<no-stdout-check>",
					exp.status,
					bout:gsub("\n", "\\n"),
					bst
				)
			)
		end
		if verbose and not sok then
			io.write(("  FAIL %s: %s\n"):format(path:match("[^/]+$"), c.name))
			if diff then
				io.write(
					("    CODE: %s\n    want%s=[%s](%d)  curse=[%s](%d)\n"):format(
						c.code:gsub("\n", "\\n"),
						exp.check_out and "" or "(status-only)",
						bout:gsub("\n", "\\n"),
						bst,
						cout:gsub("\n", "\\n"),
						cst
					)
				)
			end
		end
		total = total + 1
	end
	goldPass = goldPass + gp
	livePass = livePass + lp
	structPass = structPass + sp
	perFile[#perFile + 1] = { file = path:match("[^/]+$"), pass = sp, n = #cases }
end

table.sort(perFile, function(a, b)
	return a.n > b.n
end)
io.write("\nper-file (pass/total):\n")
for _, f in ipairs(perFile) do
	local pct = f.n == 0 and 0 or math.floor(f.pass / f.n * 100 + 0.5)
	io.write(("  %3d/%3d  %3d%%  %s\n"):format(f.pass, f.n, pct, f.file))
end
local pct = total == 0 and "0" or ("%.1f"):format(structPass / total * 100)
io.write(("\nspec conformance (%s): %d/%d cases (%s%%) across %d files\n"):format(mode, structPass, total, pct, #files))
if show_live then
	io.write(
		("  golden-only (vs recorded spec): %d/%d   pure-live (stdout+status vs host bash): %d/%d   golden-vs-hostbash divergences: %d\n"):format(
			goldPass,
			total,
			livePass,
			total,
			divergences
		)
	)
end
if memprof then
	io.write("\npeak child-RSS escalation (each line set a new high — the memory culprits):\n")
	for _, m in ipairs(mem_log) do
		io.write(("  %8.1f MB  %s: %s\n"):format(m.kb / 1024, m.file, m.case))
	end
	io.write(("PEAK child RSS: %.1f MB (%d KB) across %d files\n"):format(mem_peak / 1024, mem_peak, #files))
end
os.execute("rm -rf " .. TMP)
