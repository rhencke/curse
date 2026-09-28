-- Targeted in-process fuzz targets (harness.c FUZZ_TARGET=NAME; README "Targeted fuzzers").
--
-- Each target turns the fuzz input (a small text in the target's own language) into ONE
-- shell snippet. The same snippet runs on both sides of the differential:
--   curse: in the forkserver child, in a shell set up ONCE before forking (all modules
--          loaded, prelude run): `( eval "$__q" ) </dev/null 2>&1` with __q = the snippet,
--          through curse's parser + interpreter -- no process or shell startup per input;
--   bash:  a persistent bash 5.2.21 coprocess (bashco.h) running the same driver file,
--          whose loop runs the same line for each request.
-- Both sides print merged stdout+stderr and the subshell's status; any byte difference
-- is a finding. The driver file is the same path on both sides, so error prefixes
-- (`DRV: line 2: ...`, `DRV: eval: line 3: ...`) match too.
--
-- Input languages (an optional first line `#@ opt opt ...` turns on shell options:
-- extglob nocasematch nocaseglob globasciiranges dotglob nullglob failglob xpg_echo
-- posix utf8 noglob; see HDR):
--   arith   an arithmetic expression; evaluated as data: `$(( $__e ))`, or (a first byte
--           `=`) as a variable's value `x=$__e; $(( x ))`; then the variables it can set.
--   pexp    the words of ONE command `__w WORDS` (literal shell text: ${...} operators,
--           quoting, arrays, substrings); __w prints each field as <...>. Gated: see gate().
--   printf  line 1 the format, every further line one argument (data).
--   glob    line 1 a pattern, line 2 a string (data): [[ == ]], case, # ## % %% / // /# /%.
--   read    line 1 `U` (IFS unset) or `=VALUE`, line 2 read options, the rest the data read
--           (a here-string) and field-split unquoted.
--   regex   line 1 `v RE` (the regex as data: [[ $s =~ $re ]]) or `l RHS` (literal shell
--           text after =~, gated), line 2 the string; status + BASH_REMATCH.
--   parse   a script, only parsed: `eval $'set -n\n'"$q"` (bash's parse_and_execute skips
--           execution under -n in a non-interactive shell): syntax OK/error, message, line.
--   deparse the same, then (when it parses) the script as a function body printed back by
--           `declare -f` (the function never runs): the parse tree, as bash prints it.
local rt = require("runtime")
local interp = require("interp")
local Invoke = require("invoke")
local P = require("parser")

local M = {}
local byte, char, concat = string.byte, string.char, table.concat

-- ---- the shared prelude (line 1 of the driver; runs once per side) -----------------------
-- Fixed variables every target can use; dangerous builtins disabled; restricted mode (no
-- output redirection, cd, PATH changes, command names with a slash, exec).
local PRELUDE = concat({
	"__w() { printf '<%s>' \"$@\"; echo; }",
	"w='hello world' x=3 e='' n=5 i=0 y=-7 big=9223372036854775807 s='x+1' r='r' z=010 h=0x1F",
	"g='[ab]*' p='*o*' bs='a\\q' q=$'it\\'s \"q\"' nl=$'a\\nb' t=$'\\t x \\t'",
	"a=(one 'two three' '' four) m=([3]=c [1]=a [7]=g); declare -A A=([k]=v [k2]='x y' [0]=zero)",
	"declare -i ii=3; declare -u up=Mixed; declare -l lo=MiXeD; declare -n ref=w",
	"set -- p1 'p 2' '' '*'",
	"unset u",
	"enable -n kill exec ulimit suspend wait fg bg disown",
	"enable -n enable",
	"set -r",
}, "; ")

M.LOOP = 'while IFS= read -r -d "" __q; do ( eval "$__q" ) </dev/null 2>&1; printf "\\0\\1%s:%d\\n" NONCE "$?"; done'

function M.driver(nonce)
	return PRELUDE .. "\n" .. M.LOOP:gsub("NONCE", nonce) .. "\n"
end

-- ---- helpers -------------------------------------------------------------------------------
-- any bytes -> a $'...' word (every byte outside a small safe set as \xHH: nothing in it
-- is ever shell syntax)
local function dq(s)
	return "$'" .. s:gsub("[^%w _.,:/+=%-]", function(c)
		return ("\\x%02x"):format(byte(c))
	end) .. "'"
end
M.dq = dq

local HDR = {
	extglob = "shopt -s extglob", nocasematch = "shopt -s nocasematch", nocaseglob = "shopt -s nocaseglob",
	globasciiranges = "shopt -u globasciiranges", dotglob = "shopt -s dotglob", nullglob = "shopt -s nullglob",
	failglob = "shopt -s failglob", xpg_echo = "shopt -s xpg_echo", posix = "set -o posix",
	utf8 = "LC_ALL=C.UTF-8", noglob = "set -f", nopatsub = "shopt -u patsub_replacement",
}
-- "#@ opts\n" -> the option commands, the rest of the input
local function header(s)
	local h, rest = s:match("^#@([^\n]*)\n(.*)$")
	if not h then
		return "", s
	end
	local out = {}
	for w in h:gmatch("%S+") do
		if HDR[w] then
			out[#out + 1] = HDR[w] .. "; "
		end
	end
	return concat(out), rest
end

-- Nondeterminism / environment differences that are not bugs (fuzz.sh known.tsv NOISE, the
-- in-loop version): process ids, clocks, random numbers, the shells' own variable sets
local NOISE = {
	"RANDOM", "SRANDOM", "EPOCH", "BASHPID", "SECONDS", "PPID", "%$%$", "%$!", "BASH_COMMAND",
	"%${![A-Z_]", "%$_", "%${_", "BASH", "HISTCMD", "LINENO", "SHLVL", "COMP_", "FUNCNAME",
	"OLDPWD", "PWD", "PIPESTATUS", "GROUPS", "HOSTTYPE", "MACHTYPE", "OSTYPE", "COLUMNS", "LINES",
	"%$%-", "%${%-", "SHELLOPTS", "BASHOPTS", "DIRSTACK", "READLINE", "TMOUT", "IFS=.-[^ ]*BASH",
	"%${!%*", "%${!@", "%${!#", -- (${!*} / ${!@} / ${!#} indirect through the positional list)
}
local function noisy(s)
	for _, pat in ipairs(NOISE) do
		if s:find(pat) then
			return true
		end
	end
	return false
end

-- code-shaped inputs (pexp, regex l): never a command or process substitution anywhere, and
-- curse's parser must see exactly ONE statement of the expected kind with no redirections
local function gate(snip, kind)
	if snip:find("%$%(") or snip:find("`", 1, true) or snip:find("[<>]%(") or snip:find("\0", 1, true) then
		return false
	end
	local ok, ast = pcall(P.parse, snip)
	if not ok or type(ast) ~= "table" or #ast.stmts ~= 1 then
		return false
	end
	local st = ast.stmts[1]
	if st.t ~= kind or (st.redirs and #st.redirs > 0) then
		return false
	end
	if kind == "simple" and not (st.words and st.words[1] and st.words[1].src == "__w") then
		return false
	end
	if st.assigns and #st.assigns > 0 then
		return false
	end
	return true
end

local function lines(s)
	local t = {}
	for l in (s .. "\n"):gmatch("([^\n]*)\n") do
		t[#t + 1] = l
	end
	return t
end

-- ---- the targets: input -> snippet (nil: skip this input) -----------------------------------
local B = {}

function B.arith(s)
	local h, e = header(s)
	if e:find("%$%(") or e:find("`", 1, true) or noisy(e) then
		return nil
	end
	local show = '; declare -p x y n i ii a A 2>&1'
	if e:sub(1, 1) == "=" then
		return h .. "__v=" .. dq(e:sub(2)) .. '; x=$__v; echo "$(( x ))"' .. show
	end
	return h .. "__e=" .. dq(e) .. '; echo "$(( $__e ))"' .. show
end

function B.pexp(s)
	local h, w = header(s)
	if w:find("\n", 1, true) or noisy(w) then
		return nil
	end
	if w:find("@P", 1, true) and w:find("\\", 1, true) then -- (prompt escapes: \t \d \# \! ...)
		return nil
	end
	local cmd = "__w " .. w
	if not gate(cmd, "simple") then
		return nil
	end
	return h .. cmd .. '; declare -p w x e u a A n i 2>&1'
end

function B.printf(s)
	local h, rest = header(s)
	local l = lines(rest)
	local fmt = l[1] or ""
	local args = {}
	local plain = true
	for k = 2, #l do
		args[#args + 1] = dq(l[k])
		if not l[k]:match("^%d+$") then
			plain = false
		end
	end
	if #l >= 2 and l[#l] == "" then -- (a trailing newline ends the last argument)
		args[#args] = nil
	end
	-- %(fmt)T with no/empty/negative argument is the current time: only all-digit arguments
	-- at least one per directive make it deterministic
	if fmt:find("%(", 1, true) then
		local nd = select(2, fmt:gsub("%%%%", ""):gsub("%b()", ""):gsub("%%", ""))
		if not plain or #args < nd then
			return nil
		end
	end
	local a = concat(args, " ")
	return h .. "TZ=UTC; __f=" .. dq(fmt) .. '; printf -- "$__f" ' .. a .. '; echo "|st=$?"; printf -v __v -- "$__f" ' .. a
		.. '; echo "st=$?"; declare -p __v 2>&1'
end

function B.glob(s)
	local h, rest = header(s)
	local l = lines(rest)
	local p, str = dq(l[1] or ""), dq(l[2] or "")
	return h .. "__p=" .. p .. "; __s=" .. str
		.. '; [[ $__s == $__p ]]; echo "dbr=$?"; case $__s in $__p) echo case=1;; *) echo case=0;; esac'
		.. '; __w "${__s#$__p}" "${__s##$__p}" "${__s%$__p}" "${__s%%$__p}"'
		.. '; __w "${__s/$__p/<&>}" "${__s//$__p/X}" "${__s/#$__p/X}" "${__s/%$__p/X}"'
end

local ROPT = { ["-r"] = 0, ["-s"] = 0, ["-a"] = "arr", ["-d"] = "chr", ["-n"] = "num", ["-N"] = "num" }
function B.read(s)
	local h, rest = header(s)
	local ifs, opts, data = rest:match("^([^\n]*)\n([^\n]*)\n(.*)$")
	if not ifs then
		return nil
	end
	local set
	if ifs == "U" then
		set = "unset IFS"
	elseif ifs:sub(1, 1) == "=" then
		set = "IFS=" .. dq(ifs:sub(2))
	else
		return nil
	end
	local o, toks, k = {}, {}, 1
	for t in opts:gmatch("%S+") do
		toks[#toks + 1] = t
	end
	local arr = false
	while k <= #toks do
		local t, kind = toks[k], ROPT[toks[k]]
		if kind == 0 then
			o[#o + 1] = t
		elseif kind == "arr" then
			o[#o + 1] = "-a __arr"
			arr = true
		elseif kind == "chr" then
			o[#o + 1] = t .. " " .. dq(toks[k + 1] or "")
			k = k + 1
		elseif kind == "num" and toks[k + 1] and toks[k + 1]:match("^%-?%d+$") and #toks[k + 1] <= 20 then
			o[#o + 1] = t .. " " .. toks[k + 1]
			k = k + 1
		end
		k = k + 1
	end
	local names = arr and "" or " __r1 __r2 __r3"
	return h .. "__d=" .. dq(data) .. "; " .. set .. '; __w $__d; __w "$__d" ${__d}x; read ' .. concat(o, " ")
		.. names .. ' <<< "$__d"; echo "st=$?"; declare -p __r1 __r2 __r3 __arr 2>&1'
end

function B.regex(s)
	local h, rest = header(s)
	local l = lines(rest)
	local mode, re = (l[1] or ""):match("^([vl]) (.*)$")
	if not mode then
		return nil
	end
	local str = dq(l[2] or "")
	local show = '; echo "st=$?"; declare -p BASH_REMATCH 2>&1'
	if mode == "v" then
		return h .. "__s=" .. str .. "; __re=" .. dq(re) .. "; [[ $__s =~ $__re ]]" .. show
	end
	if noisy(re) then
		return nil
	end
	local cmd = "[[ $__s =~ " .. re .. " ]]"
	if not gate(cmd, "dbracket") then
		return nil
	end
	return h .. "__s=" .. str .. "; " .. cmd .. show
end

function B.parse(s)
	local h, src = header(s)
	if src:find("\0", 1, true) then
		return nil
	end
	-- (a subshell of its own: nothing at all runs after set -n)
	return h .. "__p=" .. dq(src) .. [=[; ( eval $'set -n\n'"$__p" ) 2>&1; echo "parse=$?"]=]
end

-- deparse: when the script parses (stage 1 = parse), it as a function body, printed back
-- by `declare -f` (the function is never called). A script that parses on its own can't
-- close our `{ … }` early -- as a body it can only fail to parse too.
function B.deparse(s)
	local h, src = header(s)
	if src:find("\0", 1, true) then
		return nil
	end
	return h .. "__p=" .. dq(src) .. [=[; ( eval $'set -n\n'"$__p" ) 2>&1; __st=$?; echo "parse=$__st"; ]=]
		.. [=[if [[ $__st = 0 ]]; then eval "__f() {"$'\n'"$__p"$'\n}' 2>&1 && declare -f __f; fi]=]
end

-- ---- the harness side ------------------------------------------------------------------------
local sh
function M.setup(target, drvpath)
	assert(B[target], "unknown target " .. tostring(target))
	M.target = target
	sh = rt.Shell.new()
	for k in pairs(sh.vars) do -- (AFL's own variables stay in the process environment, where
		if k:match("^_*AFL") then -- __AFL_INIT reads them, but not in the shell's)
			sh.vars[k] = nil
		end
	end
	local inv = assert(Invoke.parse({ "bash", drvpath }))
	local kind, src = Invoke.start(sh, inv)
	assert(kind == "file", "driver start: " .. tostring(kind))
	interp.run_lazy(sh, src:match("^[^\n]*"), nil, 1)
	M.sh = sh
	io.flush()
	return true
end

function M.build(input)
	if input:find("\0", 1, true) then
		return nil
	end
	local ok, snip = pcall(B[M.target], input)
	if not ok then
		error("targets.lua build: " .. tostring(snip))
	end
	return snip
end

function M.run(snip)
	sh:set_str("__q", snip)
	interp.run_lazy(sh, '( eval "$__q" ) </dev/null 2>&1', nil, 2)
	io.flush()
	return sh.status or 0
end

M.targets = {}
for k in pairs(B) do
	M.targets[#M.targets + 1] = k
end
table.sort(M.targets)
return M
