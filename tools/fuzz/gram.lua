-- Grammar-aware mutation engine for the AFL++ custom mutator (gram_mutator.c).
--
-- Runs as a helper process: build/luajit tools/fuzz/gram.lua SRCROOT, speaking a
-- length-prefixed request/response protocol on stdin/stdout (see serve() below). It
-- drives curse's OWN parser (lua/parser.lua) and unparser (lua/deparse.lua, the
-- `declare -f` printer): a script that parses is mutated as an AST (subtrees swapped
-- across queue entries by kind, replaced by generated ones, wrapped in contexts that
-- change how they run: functions, eval, source, traps, subshells, pipelines, hot loops
-- that cross the tier compile threshold), then printed back. A script that doesn't
-- parse, and a share of those that do, get token-level edits instead: truncation at a
-- token boundary, closers dropped/duplicated/swapped, reserved words out of place,
-- lexical ambiguities, line continuations, odd bytes. Nothing here ever runs the
-- script; the parser is only asked to read it.
--
-- Also: gram.lua SRCROOT --classify FILE...  (parse-validity of files, for measurement)
--       gram.lua SRCROOT --sample N SEED     (N generated mutations of a small seed, to eyeball)
local ROOT = assert(arg[1], "usage: gram.lua SRCROOT [--classify FILE...]")
package.path = ROOT .. "/lua/?.lua;" .. package.path
require("runtime")
local P = require("parser")
local D = require("deparse")

local random, floor, concat = math.random, math.floor, table.concat
local function r(n) return random(n) end
local function pick(t) return t[random(#t)] end
local function chance(p) return random() < p end

-- ---- parsing ---------------------------------------------------------------------
-- ok: a table of statements with no parse error anywhere; "perr": a syntax error the
-- parser reports; "throw": one it raises (EOF inside a construct, …)
-- The tree is a deep copy: the parser memoizes parts of what it returns (word tables,
-- by text), so mutating its own tables in place would poison later parses.
local function deepcopy(v, memo)
	if type(v) ~= "table" then
		return v
	end
	local c = memo[v]
	if c then
		return c
	end
	c = {}
	memo[v] = c
	for k, x in pairs(v) do
		c[deepcopy(k, memo)] = deepcopy(x, memo)
	end
	return setmetatable(c, getmetatable(v))
end
local function parse(src, nocopy)
	local ok, ast = pcall(P.parse, src)
	if not ok or type(ast) ~= "table" then
		return nil, "throw"
	end
	for _, st in ipairs(ast.stmts) do
		if st.t == "parse_error" then
			return nil, "perr"
		end
	end
	if nocopy then
		return ast, "ok"
	end
	return { stmts = deepcopy(ast.stmts, {}) }, "ok"
end

local CMD = {}
for t in ("simple assignlist pipeline andor background group subshell coproc if whilec forin select forc case arithcmd dbracket funcdef noop"):gmatch("%S+") do
	CMD[t] = true
end
local SKIP = { jcx = true, lgspan = true, _pst = true }

-- every command slot (parent, key, node) and every word (a table with a source text)
local function collect(ast)
	local slots, words, seen = {}, {}, {}
	local function walk(node)
		for k, v in pairs(node) do
			if type(v) == "table" and not SKIP[k] and not seen[v] then
				seen[v] = true
				if CMD[v.t] then
					slots[#slots + 1] = { node, k, v }
				elseif v.k == "word" and type(v.src) == "string" then
					words[#words + 1] = v
				end
				walk(v)
			end
		end
	end
	walk(ast.stmts)
	return slots, words
end

local function print_ast(ast)
	local out = {}
	for _, st in ipairs(ast.stmts) do
		local ok, s = pcall(D.command_text, st)
		if not ok or s == nil or (s == "" and st.t ~= "noop") then
			return nil -- (something deparse can't print exactly)
		end
		out[#out + 1] = s
	end
	return concat(out, "\n") .. "\n"
end

local function node_text(node)
	local ok, s = pcall(D.command_text, node)
	return ok and s ~= "" and s or nil
end

-- text -> one command node (nil if it isn't exactly one parseable statement)
local function text_node(text)
	local ast = parse(text)
	if ast and #ast.stmts == 1 then
		return ast.stmts[1]
	end
	if ast then -- (several statements: as one group)
		ast = parse("{ " .. text .. "\n}")
		return ast and #ast.stmts == 1 and ast.stmts[1] or nil
	end
end

-- ---- the fragment pool: subtrees seen in queue entries, by kind -------------------
local POOL, POOLN, POOL_MAX = {}, 0, 3000
local function pool_add(kind, text)
	if not text or #text > 400 then
		return
	end
	local p = POOL[kind]
	if not p then
		p = {}
		POOL[kind] = p
	end
	if #p < POOL_MAX then
		p[#p + 1] = text
	else
		p[r(#p)] = text
	end
	POOLN = POOLN + 1
end
local harvested = setmetatable({}, { __mode = "k" })
local HARV, HARVN = {}, 0
local function harvest(src)
	if HARV[src] then
		return
	end
	HARVN = HARVN + 1
	if HARVN > 20000 then
		HARV, HARVN = {}, 0
	end
	HARV[src] = true
	local ast = parse(src, true)
	if not ast then
		return
	end
	local slots, words = collect(ast)
	for _, s in ipairs(slots) do
		local t = node_text(s[3])
		pool_add(s[3].t, t)
		pool_add("cmd", t)
	end
	for _, w in ipairs(words) do
		pool_add("word", w.src)
	end
end
local function pool_pick(kind)
	local p = POOL[kind]
	return p and #p > 0 and p[r(#p)] or nil
end

-- ---- generator: random bash from the grammar of bash-5.2.21 parse.y ----------------
local G = {}
local budget -- (node budget of the current generation: keeps fragments small)
local hd -- (here-document bodies pending for the next newline)
local ctr = 0 -- (fresh loop-counter names: every generated loop terminates)
local function fresh()
	ctr = ctr + 1
	return "_g" .. ctr
end

local NAMES = { "a", "b", "x", "i", "A", "f", "_", "v", "IFS", "OPTIND", "REPLY", "PIPESTATUS",
	"FUNCNAME", "LINENO", "BASH_REMATCH", "BASH_ARGV", "BASH_LINENO", "BASH_SOURCE", "FUNCNEST",
	"GLOBIGNORE", "OPTARG", "OPTERR", "PS4", "HOME", "PWD", "OLDPWD", "BASH_ALIASES", "MAPFILE",
	"COLUMNS", "TIMEFORMAT", "BASH_COMMAND", "BASH_SUBSHELL", "SHLVL", "UID" }
local SPECIAL = { "?", "#", "@", "*", "-", "0", "1", "2", "_", "!" }
local NUMS = { "0", "1", "2", "3", "7", "-1", "10", "255", "256", "9223372036854775807",
	"-9223372036854775808", "9223372036854775808", "18446744073709551616", "2#101", "16#ff",
	"36#zz", "64#_@", "64#@", "1#1", "65#1", "0x7fffffffffffffff", "0x10", "010", "08", "0777",
	"1e3", "4294967296", "2147483648", "-2147483649", "0012", "10#08", "-0" }
local LITS = { "a", "b", "abc", "x y", "", " ", "*", "?", "[a]", "-n", "-e", "--", "-", "=", "%s",
	"\\", "\\n", "a\tb", "é", "\xff\xfe", "\xc3", "a\r", "~", "~root", "~+", "~-", "{a,b}", "{1..3}",
	"{a..e..2}", "{z..a}", "{1..10..-3}", "{x}", "{,}", ".", "..", "/", "/dev/null", "f", "g",
	"*.sh", "[!a]*", "@(a|b)", "!(x)", "+(ab)", "*(a)", "?(a)", "[[:alpha:]]", "[[:digit:]]*",
	"a=b", "a[1]=b", "A[k]", "%", "#", "a#b", "\\$x", "'", "\"", "\\'" }

local function word() return G.word() end

function G.name()
	return chance(0.7) and pick({ "a", "b", "x", "i", "A", "f", "v" }) or pick(NAMES)
end

function G.num()
	return chance(0.5) and tostring(r(12) - 2) or pick(NUMS)
end

function G.sq(s) -- (single-quote any text)
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

function G.arith(d)
	d = d or 0
	budget = budget - 1
	if d > 3 or budget < 0 or chance(0.3) then
		local k = r(8)
		if k <= 3 then return G.num() end
		if k <= 5 then return G.name() end
		if k == 6 then return G.name() .. "[" .. G.arith(d + 1) .. "]" end
		if k == 7 then return "$" .. G.name() end
		return "${#" .. G.name() .. "}"
	end
	local k = r(10)
	if k <= 4 then
		return G.arith(d + 1) .. " " .. pick({ "+", "-", "*", "/", "%", "**", "<<", ">>", "&", "|", "^", "&&", "||", "<", ">", "<=", ">=", "==", "!=", "," }) .. " " .. G.arith(d + 1)
	elseif k == 5 then
		return pick({ "-", "+", "!", "~", "++", "--" }) .. G.arith(d + 1)
	elseif k == 6 then
		return G.name() .. pick({ "++", "--" })
	elseif k == 7 then
		return G.name() .. " " .. pick({ "=", "+=", "-=", "*=", "/=", "%=", "<<=", ">>=", "&=", "|=", "^=" }) .. " " .. G.arith(d + 1)
	elseif k == 8 then
		return G.arith(d + 1) .. " ? " .. G.arith(d + 1) .. " : " .. G.arith(d + 1)
	elseif k == 9 then
		return "(" .. G.arith(d + 1) .. ")"
	end
	return pick({ "$(( " .. G.arith(d + 1) .. " ))", "$(echo " .. G.num() .. ")", "\"" .. G.num() .. "\"", "'1'", "$[" .. G.arith(d + 1) .. "]", "a[" .. G.arith(d + 1) .. "]++" })
end

function G.pexp()
	budget = budget - 1
	local nm = chance(0.8) and G.name() or pick(SPECIAL)
	local sub = ""
	if chance(0.25) then
		sub = "[" .. pick({ "@", "*", "0", "1", "-1", "k", "i+1", "$i", "\"k\"", "x y" }) .. "]"
	end
	local k = r(16)
	if k <= 2 then return "$" .. nm end
	if k == 3 then return "${" .. nm .. sub .. "}" end
	if k == 4 then return "${#" .. nm .. sub .. "}" end
	if k == 5 then return "${!" .. pick({ nm, nm .. "*", nm .. "@", nm .. "[@]", nm .. "[*]" }) .. "}" end
	local w = budget > 0 and chance(0.6) and G.word(true) or pick({ "", "w", "*", "a*", "?", "\\}" })
	if k <= 8 then return "${" .. nm .. sub .. pick({ "-", ":-", "=", ":=", "?", ":?", "+", ":+" }) .. w .. "}" end
	if k <= 10 then return "${" .. nm .. sub .. pick({ "#", "##", "%", "%%" }) .. w .. "}" end
	if k == 11 then return "${" .. nm .. sub .. pick({ "/", "//", "/#", "/%" }) .. w .. pick({ "", "/", "/" .. word() }) .. "}" end
	if k == 12 then return "${" .. nm .. sub .. pick({ "^", "^^", ",", ",,", "~", "~~" }) .. pick({ "", "a", "[a-m]", "?" }) .. "}" end
	if k == 13 then return "${" .. nm .. sub .. ":" .. pick({ "0", "1", "-1", " -2", "(-1)", "1:2", "x", "$i", "2:-1", "9223372036854775807" }) .. "}" end
	if k == 14 then return "${" .. nm .. sub .. "@" .. pick({ "Q", "E", "P", "A", "a", "U", "u", "L", "K", "k", "x", "" }) .. "}" end
	if k == 15 then return "${" .. pick({ "", "!", "#" }) .. pick({ " a", "a b", "1a", "@a", "", "!", "$", "=", "a[" }) .. "}" end
	return "$" .. pick(SPECIAL)
end

function G.word(inner)
	budget = budget - 1
	local parts, n = {}, (budget > 0 and chance(0.3)) and r(3) or 1
	for _ = 1, n do
		local k = r(20)
		local p
		if k <= 5 or budget < 0 then
			p = chance(0.5) and pick(LITS) or G.num()
			if p:find("[ \t'\"\\\r]") and not inner then
				p = chance(0.5) and G.sq(p) or "\"" .. p:gsub("[\"\\$`]", "\\%0") .. "\""
			end
		elseif k <= 9 then
			p = G.pexp()
		elseif k == 10 then
			p = "\"" .. G.pexp() .. pick({ "", " ", "x", "$" .. G.name() }) .. "\""
		elseif k == 11 then
			p = "$(( " .. G.arith() .. " ))"
		elseif k == 12 then
			p = "$[" .. G.arith() .. "]"
		elseif k == 13 then
			p = "$(" .. G.list(2, true) .. ")"
		elseif k == 14 then
			p = "`" .. G.simple():gsub("[`\\]", "\\%0") .. "`"
		elseif k == 15 then
			p = "$'" .. pick({ "\\n", "\\t", "\\x41", "\\u263a", "\\U0001F600", "\\0101", "\\c?", "\\e", "\\'", "\\x", "\\xff", "a b", "\\cA", "\\" }) .. "'"
		elseif k == 16 then
			p = "$\"" .. pick({ "hi", "$x", "" }) .. "\""
		elseif k == 17 then
			p = pick({ "<(", ">(" }) .. G.simple() .. ")"
		elseif k == 18 then
			p = "\"" .. pick({ "$@", "$*", "${a[@]}", "${@:2}", "${*:1:1}", "$@$@", "x$@y", "${!a[@]}" }) .. "\""
		elseif k == 19 then
			p = pick({ "$@", "$*", "${a[@]}", "${a[*]}", "${A[@]}", "${!A[@]}", "\"${a[@]:1}\"" })
		else
			p = pick({ "\\ ", "\\\n", "\\'", "''", "\"\"", "$", "\"$\"", "$$", "\\$", "${}", "\"`echo a`\"", "\"$(echo \"a b\")\"" })
		end
		parts[#parts + 1] = p
	end
	return concat(parts)
end

local REDIR_TGT = { "f", "g", "/dev/null", "\"$x\"", "$a", "''", "*", "f*" }
function G.redir()
	budget = budget - 1
	local fd = chance(0.3) and pick({ "0", "1", "2", "3", "9", "10", "255", "{fd}", "{v}", "{a[1]}", "99999999999" }) or ""
	local k = r(12)
	if k <= 3 then return fd .. pick({ ">", ">>", "<", "<>", ">|" }) .. " " .. pick(REDIR_TGT) end
	if k <= 5 then return fd .. pick({ ">&", "<&" }) .. pick({ "1", "2", "0", "-", "3", "$fd", "3-", "f", "10" }) end
	if k == 6 then return pick({ "&>", "&>>", ">&" }) .. " " .. pick(REDIR_TGT) end
	if k == 7 then return fd .. "<<< " .. word() end
	-- here-document
	local dl = pick({ "EOF", "E", "!", "-", "a b", "EOF", "''", "$x", "\\", "e\"f\"", "" })
	local ql = pick({ dl, "'" .. dl .. "'", "\"" .. dl .. "\"", "\\" .. dl, dl })
	local strip = chance(0.3)
	local body = {}
	for _ = 1, r(3) - 1 do
		body[#body + 1] = (strip and "\t" or "") .. pick({ "text", "$x", "${a:-b}", "$(echo hi)", "`echo b`", "\\$x", "a\\", "$((1+2))", "\t\tx", "'q'", "\"q\"", "EOF ", " EOF" })
	end
	local term = dl:gsub("^'", ""):gsub("'$", "")
	term = chance(0.9) and term or pick({ "", term .. " ", " " .. term, "\t" .. term })
	hd[#hd + 1] = concat(body, "\n") .. (#body > 0 and "\n" or "") .. (strip and chance(0.5) and "\t" or "") .. term
	return fd .. (strip and "<<-" or "<<") .. ql
end

local function flush_hd(out)
	if #hd > 0 then
		out[#out + 1] = "\n" .. concat(hd, "\n")
		hd = {}
		return true
	end
end

local SET_OPTS = { "-e", "-u", "-x", "-v", "-f", "-C", "-a", "-b", "-h", "-k", "-B", "-H", "-P", "-T", "-E",
	"+e", "+u", "+x", "+f", "-o pipefail", "-o posix", "+o posix", "-o errtrace", "-o functrace",
	"-o noglob", "-o nounset", "-o errexit", "-o xtrace", "-o", "+o", "-o emacs", "--", "-", "-e -o pipefail" }
local SHOPTS = { "extglob", "nullglob", "failglob", "nocasematch", "nocaseglob", "globstar", "lastpipe",
	"xpg_echo", "expand_aliases", "dotglob", "inherit_errexit", "globasciiranges", "extdebug",
	"sourcepath", "shift_verbose", "patsub_replacement", "assoc_expand_once", "localvar_inherit",
	"localvar_unset", "compat31", "compat32", "compat40", "compat41", "compat42", "compat43",
	"compat44", "noexpand_translation", "varredir_close", "execfail", "checkhash", "cdable_vars" }
local SIGS = { "EXIT", "ERR", "DEBUG", "RETURN", "USR1", "USR2", "INT", "TERM", "HUP", "0", "SIGUSR1", "CHLD", "PIPE", "QUIT", "ALRM" }
local DECL_F = { "-i", "-a", "-A", "-n", "-u", "-l", "-r", "-x", "-g", "-p", "-f", "-F", "-t", "-I", "-ia", "-il", "-Ai", "-ul", "+x", "+i", "-an", "--" }
local PRINTF_F = { "%s", "%d", "%5.2f", "%q", "%b", "%*d", "%-*s", "%x %o %X", "%e %g", "%c", "%i %u",
	"%.*s", "%%", "%v", "\\x41\\u263a\\0101", "%s\\n", "%(%Y)T", "%10s|", "%-3d|", "%#x", "%+d", "% d",
	"%.3s", "%05d", "%'d", "%a", "%Q", "%1$s", "%.0f", "%ld", "%hhd", "%s %s", "\\c", "%b\\n" }

-- per-builtin argument shapes
local BUILTINS = {
	echo = function() return pick({ "", "-n ", "-e ", "-E ", "-ne ", "-- " }) .. G.words(r(3)) end,
	printf = function() return pick({ "", "-v " .. G.name() .. " ", "-v 'a[1]' ", "-- " }) .. G.sq(pick(PRINTF_F)) .. " " .. G.words(r(3) - 1) end,
	read = function() return pick({ "-r ", "", "-a " .. G.name() .. " ", "-d '' ", "-n 2 ", "-N 3 ", "-t 0 ", "-s ", "-u 0 ", "-p x " }) .. G.name() .. " " .. pick({ "", G.name() }) .. " <<< " .. word() end,
	declare = function() return pick(DECL_F) .. " " .. G.assign() end,
	typeset = function() return pick(DECL_F) .. " " .. G.name() end,
	["local"] = function() return pick({ "", "-", "-n ", "-i ", "-a ", "-A ", "-r " }) .. G.assign() end,
	export = function() return pick({ "", "-n ", "-f ", "-p" }) .. G.assign() end,
	readonly = function() return pick({ "", "-a ", "-A ", "-f ", "-p" }) .. G.assign() end,
	unset = function() return pick({ "", "-v ", "-f ", "-n " }) .. pick({ G.name(), "a[1]", "'a[@]'", "A[k]", "a[-1]" }) end,
	set = function() return pick(SET_OPTS) .. (chance(0.3) and " " .. G.words(2) or "") end,
	shopt = function() return pick({ "-s ", "-u ", "-p ", "-q ", "-o ", "" }) .. pick(SHOPTS) end,
	shift = function() return pick({ "", "1", "2", "-1", "99", "x" }) end,
	getopts = function() return G.sq(pick({ "ab:c", ":a:", "", "x" })) .. " " .. G.name() .. " " .. G.words(r(3) - 1) end,
	let = function() return G.sq(G.arith()) end,
	test = function() return G.testargs() end,
	["["] = function() return G.testargs() .. " ]" end,
	trap = function() return pick({ "-p", "-l", "--", "- " .. pick(SIGS), G.sq(G.simple()) .. " " .. pick(SIGS), "'' " .. pick(SIGS), G.sq(G.simple()) .. " " .. pick(SIGS) .. " " .. pick(SIGS) }) end,
	kill = function() return pick({ "-USR1 $$", "-s USR2 $$", "-0 $$", "-l", "-l 130", "-l USR1", "%1", "$!", "-n 10 $$", "-USR1 %%", "-9 %1", "-L" }) end,
	wait = function() return pick({ "", "-n", "$!", "%1", "%%", "-f", "-p " .. G.name() .. " -n" }) end,
	jobs = function() return pick({ "", "-l", "-p", "-r", "-s", "%1", "-x echo %1" }) end,
	alias = function() return G.name() .. "=" .. G.sq(pick({ "echo", "if", "{", "for", "case", "ls ", "echo x ", "(", "]]", "then", "done", "a=", "#" })) end,
	unalias = function() return pick({ "-a", G.name() }) end,
	type = function() return pick({ "", "-a ", "-t ", "-p ", "-P ", "-f " }) .. pick({ "if", "echo", "f", "nosuch", "[[", "type" }) end,
	command = function() return pick({ "-v ", "-V ", "-p ", "" }) .. pick({ "echo x", "f", "if", "nosuch", "declare -a q" }) end,
	builtin = function() return pick({ "echo x", "nosuch", "declare -g q=1", "" }) end,
	mapfile = function() return pick({ "-t ", "-d '' ", "-n 1 ", "-s 1 ", "-O 2 ", "", "-C 'echo' -c 1 " }) .. G.name() .. " <<< " .. G.sq("a\nb\nc") end,
	cd = function() return pick({ "/", "-", "..", "nosuch", "", "-P .", "-L ..", "~" }) end,
	pwd = function() return pick({ "", "-P", "-L" }) end,
	pushd = function() return pick({ "/", "+1", "-0", "" }) end,
	popd = function() return pick({ "", "+1", "-n" }) end,
	dirs = function() return pick({ "", "-v", "-c", "+0", "-l" }) end,
	umask = function() return pick({ "", "022", "-S", "u=rwx,g=,o=", "0777", "8" }) end,
	exit = function() return pick({ "", "0", "1", "256", "-1", "x", "$?" }) end,
	["return"] = function() return pick({ "", "0", "3", "256", "-1", "x" }) end,
	["break"] = function() return pick({ "", "1", "2", "0", "-1" }) end,
	["continue"] = function() return pick({ "", "1", "2", "0" }) end,
	eval = function() return G.sq(G.list(2)) end,
	source = function() return pick({ "/dev/null", "nosuch", "f", "./f", "<(echo echo hi)" }) .. " " .. G.words(r(2) - 1) end,
	exec = function() return pick({ "3>f", "{fd}>&1", "3>&-", ">&2", "<&-", "nosuch" }) end,
	[":"] = function() return G.words(r(3) - 1) end,
	["true"] = function() return "" end,
	["false"] = function() return "" end,
	caller = function() return pick({ "", "0", "1" }) end,
	compgen = function() return pick({ "-W 'a b ab' -- a", "-v x", "-A function", "-b ec", "-k fi" }) end,
	complete = function() return pick({ "-p", "-W 'x y' f", "-r f" }) end,
	enable = function() return pick({ "-n echo", "echo", "-a", "-p", "nosuch" }) end,
	hash = function() return pick({ "", "-r", "-p /x f", "-t f" }) end,
	disown = function() return pick({ "", "-a", "%1", "-h" }) end,
	times = nil,
	f = function() return G.words(r(3) - 1) end,
	g = function() return G.words(r(3) - 1) end,
	nosuch = function() return "" end,
}
local BNAMES = {}
for k in pairs(BUILTINS) do
	BNAMES[#BNAMES + 1] = k
end
table.sort(BNAMES)

function G.words(n)
	local t = {}
	for i = 1, n do
		t[i] = word()
	end
	return concat(t, " ")
end

function G.testargs()
	local k = r(4)
	if k == 1 then return pick({ "-z", "-n", "-e", "-f", "-d", "-v", "-o", "-R", "-t", "!" }) .. " " .. word() end
	if k == 2 then return word() .. " " .. pick({ "=", "==", "!=", "-eq", "-lt", "-ge", "<", ">", "-nt", "-ef", "=~" }) .. " " .. word() end
	if k == 3 then return pick({ "", "x", "-a", "(", "!", "! !", "( x )", "x -a y -o z" }) end
	return word() .. " " .. word() .. " " .. word() .. " " .. word()
end

function G.cond(d)
	d = d or 0
	budget = budget - 1
	local k = r(8)
	if d < 2 and k == 1 then return G.cond(d + 1) .. pick({ " && ", " || " }) .. G.cond(d + 1) end
	if d < 2 and k == 2 then return pick({ "! ", "( " }) .. G.cond(d + 1) .. (chance(0.5) and "" or " )") end
	if k <= 4 then
		return word() .. " " .. pick({ "==", "=", "!=", "=~", "<", ">", "-eq", "-ne", "-lt", "-gt", "-le", "-ge", "-nt", "-ot", "-ef" }) .. " " .. pick({ word(), "@(a|b)*", "a*", "^a(b)?$", "[[:space:]]", "'a*'", "\"$x\"", "(a|b", "x\\ y" })
	end
	if k <= 6 then
		return pick({ "-z", "-n", "-e", "-f", "-d", "-v", "-o", "-R", "-a", "-t", "-s", "-r" }) .. " " .. pick({ word(), "a[1]", "A[k]", "x" })
	end
	return word()
end

function G.assign()
	budget = budget - 1
	local nm = G.name()
	local k = r(7)
	if k <= 3 then return nm .. pick({ "=", "+=" }) .. (chance(0.3) and "" or word()) end
	if k == 4 then return nm .. "[" .. pick({ "0", "1", "-1", "k", "i+1", "$x", "@", "\"a b\"", "", "9223372036854775807" }) .. "]" .. pick({ "=", "+=" }) .. word() end
	if k == 5 then return nm .. pick({ "=", "+=" }) .. "(" .. G.words(r(3) - 1) .. pick({ "", " [5]=x", " [k]=v", " [1]+=y", " [@]=z", " \"$@\"" }) .. ")" end
	if k == 6 then return nm .. "=" .. G.num() end
	return nm .. "=" .. "\"" .. G.pexp() .. "\""
end

function G.simple()
	budget = budget - 1
	local out = {}
	if chance(0.2) then
		for _ = 1, r(2) do
			out[#out + 1] = G.assign()
		end
	end
	if #out == 0 or chance(0.6) then
		local nm = pick(BNAMES)
		out[#out + 1] = nm
		local f = BUILTINS[nm]
		local a = f and budget > 0 and f() or ""
		if a ~= "" then
			out[#out + 1] = a
		end
	end
	if chance(0.2) then
		out[#out + 1] = G.redir()
	end
	return concat(out, " ")
end

local function body(n)
	return G.list(n or 2)
end

function G.compound()
	budget = budget - 1
	local k = r(16)
	local c
	if k == 1 then
		c = "if " .. body(1) .. "; then " .. body() .. (chance(0.3) and "; elif " .. body(1) .. "; then " .. body() or "") .. (chance(0.4) and "; else " .. body() or "") .. "; fi"
	elseif k == 2 then
		local v = fresh()
		c = pick({ "while", "until" }) .. " " .. pick({ "(( " .. v .. "++ < " .. r(4) .. " ))", "((" .. v .. "++ >= " .. r(4) .. "))" }) .. "; do " .. body() .. "; done"
		if c:sub(1, 5) == "until" then
			c = c:gsub("<", ">=", 1)
		end
	elseif k == 3 then
		c = "for " .. G.name() .. pick({ " in " .. G.words(r(3)), "", " in", " in \"$@\"" }) .. pick({ "; ", "\n" }) .. "do " .. body() .. "; done"
	elseif k == 4 then
		local v = fresh()
		c = "for ((" .. v .. "=0; " .. v .. "<" .. r(4) .. "; " .. v .. "++)); do " .. body() .. "; done"
	elseif k == 5 then
		c = "select " .. G.name() .. " in " .. G.words(r(2)) .. "; do " .. body() .. "; break; done"
	elseif k == 6 then
		local items = {}
		for _ = 1, r(3) do
			items[#items + 1] = pick({ "", "(" }) .. pick({ "a", "*", "a|b", "@(x|y)", "[a-c]*", "?", "\"$x\"", "''", "!(a)", "x\\)", "$(echo a)", "esac", "in" }) .. ") " .. body(1) .. pick({ ";;", ";&", ";;&", ";;" })
		end
		c = "case " .. word() .. " in " .. concat(items, " ") .. " esac"
	elseif k == 7 then
		c = "{ " .. body() .. "; }"
	elseif k == 8 then
		c = "( " .. body() .. " )"
	elseif k == 9 then
		c = "(( " .. G.arith() .. " ))"
	elseif k == 10 then
		c = "[[ " .. G.cond() .. " ]]"
	elseif k == 11 then
		c = pick({ "f() ", "function f ", "function f() ", "g () ", "f()\n" }) .. pick({ "{ " .. body() .. "; }", "( " .. body() .. " )", "if true; then " .. body() .. "; fi" })
	elseif k == 12 then
		c = "coproc " .. pick({ "", "C " }) .. "{ " .. body(1) .. "; }"
	elseif k == 13 then
		c = pick({ "time ", "time -p ", "! ", "! ! " }) .. G.pipeline()
	elseif k == 14 then
		c = "for ((;;)); do " .. body(1) .. "; break; done"
	else
		return G.simple()
	end
	if chance(0.15) then
		c = c .. " " .. G.redir()
	end
	return c
end

function G.command()
	if budget > 0 and chance(0.35) then
		return G.compound()
	end
	return G.simple()
end

function G.pipeline()
	local t = { G.command() }
	while budget > 0 and chance(0.25) do
		t[#t + 1] = pick({ " | ", " | ", " |& " }) .. G.command()
	end
	return concat(t)
end

function G.list(n, nested)
	local out = {}
	local saved
	if nested then
		saved, hd = hd, {}
	end
	for i = 1, math.max(1, r(n or 2)) do
		if i > 1 then
			local sep = pick({ "; ", " && ", " || ", " & ", "\n" })
			if sep == "\n" and flush_hd(out) then
				out[#out + 1] = "\n"
			else
				out[#out + 1] = sep
			end
		end
		out[#out + 1] = G.pipeline()
		if budget < 0 then
			break
		end
	end
	if nested then
		if flush_hd(out) then
			out[#out + 1] = "\n"
		end
		hd = saved
	end
	return concat(out)
end

-- a fresh top-level fragment (its here-documents closed)
local function gen(kind, size)
	budget, hd = size or (4 + r(10)), {}
	local s
	if kind == "word" then
		s = G.word()
	elseif kind == "simple" then
		s = G.simple()
	else
		s = G.list(2)
	end
	local out = { s }
	flush_hd(out)
	return concat(out)
end
local function gen_line(size)
	return gen("list", size) .. "\n"
end

-- ---- preambles: options, locale, IFS, attributes, aliases -------------------------
local LOCALES = { "C", "POSIX", "C.UTF-8", "en_US.UTF-8", "en_US.utf8", "en_US.iso885915", "ja_JP.eucjp", "zh_CN.gbk", "zh_CN.gb18030", "tr_TR.UTF-8", "nosuch" }
local IFSV = { "''", "' '", "':'", "' :'", "$' \\t\\n'", "'::'", "'ab'", "$'\\n'", "'\\'", "'*'", "' x '", "'é'" }
local function preamble()
	local k = r(8)
	if k == 1 then return "set " .. pick(SET_OPTS) end
	if k == 2 then return "shopt -s " .. pick(SHOPTS) end
	if k == 3 then return "IFS=" .. pick(IFSV) end
	if k == 4 then return pick({ "LC_ALL=", "LC_CTYPE=", "LANG=", "export LC_ALL=" }) .. pick(LOCALES) end
	if k == 5 then return "declare " .. pick(DECL_F) .. " " .. G.name() .. pick({ "", "=1", "=x", "=(1 2)", "=a" }) end
	if k == 6 then return "shopt -s expand_aliases; alias " .. pick({ "a", "x", "echo", "if", "f", "for", "do", "done" }) .. "=" .. G.sq(pick({ "echo ", "if", "{ ", "for i in 1;", "case", "(", "! ", "a=1 ", "#", "x; echo", "do", "done", "then :;", "\\", "'" })) end
	if k == 7 then return pick({ "set -euo pipefail", "set -o posix", "set -x", "set -v", "shopt -s extglob nullglob", "shopt -s failglob", "shopt -s nocasematch", "shopt -s lastpipe", "shopt -s xpg_echo", "shopt -s globstar", "PS4='+ ${LINENO} '", "FUNCNEST=3", "TIMEFORMAT=%R" }) end
	return pick({ "trap 'echo trap $?' EXIT", "trap 'echo err $LINENO' ERR", "trap ': $BASH_COMMAND' DEBUG", "trap 'echo usr1' USR1", "a=(1 2 3) A=([k]=v [x]=y); declare -A A 2>/dev/null", "declare -n r=a", "declare -i n=" .. G.num(), "readonly ro=1", "exec 3>&1", "f() { echo f \"$@\"; return 3; }" })
end

-- ---- light tokenizer (token boundaries only; never fails) --------------------------
-- -> list of { s, e, k } with k: "w" word, "o" operator, "n" newline, "b" blanks,
-- "c" comment, "h" here-document body
local OPS = { ";;&", "<<-", "<<<", "&>>", ";;", ";&", "&&", "||", "|&", ">>", "<<", "<&", ">&", "&>", "<>", ">|", "|", "&", ";", "<", ">", "(", ")" }
local function scan_nested(s, i, n, close) -- i after the opener; returns the index after close
	local depth = 1
	while i <= n do
		local c = s:sub(i, i)
		if c == "\\" then
			i = i + 2
		elseif c == "'" and close ~= "`" then
			local j = s:find("'", i + 1, true)
			i = (j or n) + 1
		elseif c == "\"" and close ~= "`" then
			i = scan_nested(s, i + 1, n, "\"")
		elseif c == "`" and close ~= "`" then
			i = scan_nested(s, i + 1, n, "`")
		elseif close == "\"" and c == "\"" or close == "`" and c == "`" then
			return i + 1
		elseif c == "$" and s:sub(i + 1, i + 1) == "(" then
			i = scan_nested(s, i + 2, n, ")")
		elseif c == "$" and s:sub(i + 1, i + 1) == "{" then
			i = scan_nested(s, i + 2, n, "}")
		elseif close == ")" and c == "(" then
			depth, i = depth + 1, i + 1
		elseif close == "}" and c == "{" then
			depth, i = depth + 1, i + 1
		elseif c == close and close ~= "\"" and close ~= "`" then
			depth = depth - 1
			i = i + 1
			if depth == 0 then
				return i
			end
		else
			i = i + 1
		end
	end
	return n + 1
end

local function tokens(s)
	local t, i, n = {}, 1, #s
	local pend = {} -- here-document delimiters awaiting the next newline
	local steps = 0
	while i <= n do
		steps = steps + 1
		if steps > 100000 then
			break
		end
		local c = s:sub(i, i)
		local st = i
		if c == "\n" then
			i = i + 1
			t[#t + 1] = { st, i - 1, "n" }
			for _, dl in ipairs(pend) do -- skip each here-document body
				local b = i
				while i <= n do
					local e = s:find("\n", i, true) or n + 1
					local line = s:sub(i, e - 1)
					i = e + 1
					if line == dl.d or (dl.strip and line:gsub("^\t+", "") == dl.d) then
						break
					end
				end
				if i > b then
					t[#t + 1] = { b, math.min(i - 1, n), "h" }
				end
			end
			pend = {}
		elseif c == " " or c == "\t" then
			local e = s:find("[^ \t]", i) or n + 1
			i = e
			t[#t + 1] = { st, i - 1, "b" }
		elseif c == "#" and (st == 1 or s:sub(st - 1, st - 1):find("[ \t\n;&|()<>]")) then
			i = (s:find("\n", i, true) or n + 1)
			t[#t + 1] = { st, i - 1, "c" }
		else
			local op
			for _, o in ipairs(OPS) do
				if s:sub(i, i + #o - 1) == o then
					op = o
					break
				end
			end
			if op then
				i = i + #op
				t[#t + 1] = { st, i - 1, "o" }
				if op == "<<" or op == "<<-" then -- the delimiter word follows
					local j = s:find("[^ \t]", i) or n + 1
					local e = j
					while e <= n and not s:sub(e, e):find("[ \t\n;&|()<>]") do
						e = e + 1
					end
					local d = s:sub(j, e - 1):gsub("[\"'\\]", "")
					if d ~= "" then
						pend[#pend + 1] = { d = d, strip = op == "<<-" }
					end
				end
			else
				while i <= n do
					c = s:sub(i, i)
					if c:find("[ \t\n;&|()<>]") then
						if (c == "(" ) and i > st and s:sub(i - 1, i - 1):find("[@!?*+=]") then -- extglob / a=( )
							i = scan_nested(s, i + 1, n, ")")
						else
							break
						end
					elseif c == "\\" then
						i = i + 2
					elseif c == "'" then
						i = (s:find("'", i + 1, true) or n) + 1
					elseif c == "\"" or c == "`" then
						i = scan_nested(s, i + 1, n, c)
					elseif c == "$" and s:sub(i + 1, i + 1) == "(" then
						i = scan_nested(s, i + 2, n, ")")
					elseif c == "$" and (s:sub(i + 1, i + 1) == "{" or s:sub(i + 1, i + 1) == "[") then
						i = scan_nested(s, i + 2, n, s:sub(i + 1, i + 1) == "{" and "}" or "]")
					else
						i = i + 1
					end
				end
				if i > n + 1 then
					i = n + 1
				end
				t[#t + 1] = { st, i - 1, "w" }
			end
		end
	end
	return t
end

-- ---- token-level operators (work on anything, parseable or not) --------------------
local CLOSERS = { "fi", "done", "esac", "}", ")", "]]", "))", "then", "do", "in", ";;", ";&", ";;&", "`", "\"", "'", "EOF", "]" }
local RESERVED = { "if", "then", "else", "elif", "fi", "case", "esac", "for", "select", "while", "until", "do", "done", "in", "function", "time", "{", "}", "!", "[[", "]]", "coproc", ";;", ";&", ";;&", "((", "))", "(", ")", "&", "|", "&&", ";" }
local AMBIG = {
	{ "$((", "$( (" }, { "$( (", "$((" }, { "((", "( (" }, { "( (", "((" }, { "$[", "$((" }, { "$((", "$[" },
	{ "))", ") )" }, { ") )", "))" }, { "]]", "] ]" }, { "${", "$ {" }, { "`", "$(" }, { "$(", "`" },
	{ ";;", ";&" }, { ";&", ";;&" }, { ";;&", ";;" }, { "<<", "<<-" }, { "<<-", "<<" }, { "<<", "<<<" },
	{ ">&", "&>" }, { "&>", ">&" }, { "|", "|&" }, { "&&", "&" }, { "||", "|" }, { "\"", "'" }, { "'", "\"" },
	{ "[[", "[" }, { "]]", "]" }, { "=~", "==" }, { "==", "=~" }, { "{", "{ " }, { "{ ", "{" }, { " }", "}" },
	{ "$'", "'" }, { "\"", "$\"" }, { "${!", "${#" }, { "${#", "${!" }, { "@(", "(" }, { "(", "@(" }, { "!(", "! (" },
	{ "\n", ";" }, { ";", "\n" }, { "\n", " " }, { "do", "{" }, { "done", "}" }, { "then", "{" }, { "fi", "}" },
}

local function span_text(s, tk)
	return s:sub(tk[1], tk[2])
end

local TOK = {}
function TOK.trunc(s, t) -- EOF inside a construct: cut at a token boundary
	if #t == 0 then return s end
	local tk = t[r(#t)]
	return s:sub(1, chance(0.8) and tk[2] or tk[1] - 1)
end
function TOK.trunc_byte(s)
	return s:sub(1, r(#s + 1) - 1)
end
function TOK.closer(s, t) -- drop / duplicate / swap a closer
	local cand = {}
	for idx, tk in ipairs(t) do
		local x = span_text(s, tk)
		for _, c in ipairs(CLOSERS) do
			if x == c or (tk[3] == "w" and x:sub(-#c) == c) then
				cand[#cand + 1] = idx
				break
			end
		end
	end
	if #cand == 0 then return nil end
	local tk = t[pick(cand)]
	local x = span_text(s, tk)
	local k = r(4)
	local rep
	if k == 1 then rep = x:sub(1, -2) -- drop its last byte (or all of a 1-byte one)
	elseif k == 2 then rep = x .. (chance(0.5) and " " or "") .. x
	elseif k == 3 then rep = pick(CLOSERS)
	else rep = "" end
	return s:sub(1, tk[1] - 1) .. rep .. s:sub(tk[2] + 1)
end
function TOK.reserved(s, t) -- a reserved word / operator at a token boundary
	local at = #t > 0 and t[r(#t)] or { 1, 0 }
	local w = pick(RESERVED)
	local pos = chance(0.5) and at[1] or at[2] + 1
	return s:sub(1, pos - 1) .. pick({ " ", "", "\n" }) .. w .. pick({ " ", "", ";", "\n" }) .. s:sub(pos)
end
function TOK.ambig(s)
	local order = {}
	for i = 1, #AMBIG do order[i] = i end
	for _ = 1, 12 do
		local a = AMBIG[order[r(#order)]]
		local hits, p = {}, 1
		while true do
			local i = s:find(a[1], p, true)
			if not i or #hits > 50 then break end
			hits[#hits + 1] = i
			p = i + 1
		end
		if #hits > 0 then
			local i = pick(hits)
			return s:sub(1, i - 1) .. a[2] .. s:sub(i + #a[1])
		end
	end
	return nil
end
function TOK.bsnl(s) -- a line continuation at any byte
	local i = r(#s + 1)
	return s:sub(1, i - 1) .. "\\\n" .. s:sub(i)
end
function TOK.hash(s, t) -- `#` mid-word vs after a blank
	local i = r(#s + 1)
	return s:sub(1, i - 1) .. pick({ "#", " #", "#x ", "\\#", "'#'" }) .. s:sub(i)
end
function TOK.bytes(s) -- NUL, invalid UTF-8, CRLF, a lone CR, multibyte
	local k = r(5)
	if k == 1 then return (s:gsub("\n", "\r\n", r(3))) end
	local i = r(#s + 1)
	return s:sub(1, i - 1) .. pick({ "\0", "\xff", "\xc3", "\xe2\x82", "\r", "é", "\xa1\\", "\x81\x5c", "\t", "\v", "\f" }) .. s:sub(i)
end
function TOK.dup_tok(s, t) -- duplicate or delete a token range
	if #t == 0 then return nil end
	local a = r(#t)
	local b = math.min(#t, a + r(4) - 1)
	local seg = s:sub(t[a][1], t[b][2])
	if chance(0.5) then
		return s:sub(1, t[b][2]) .. seg .. s:sub(t[b][2] + 1)
	end
	return s:sub(1, t[a][1] - 1) .. s:sub(t[b][2] + 1)
end
function TOK.swap_tok(s, t)
	local ws = {}
	for i, tk in ipairs(t) do
		if tk[3] == "w" or tk[3] == "o" then ws[#ws + 1] = i end
	end
	if #ws < 2 then return nil end
	local i, j = pick(ws), pick(ws)
	if i == j then return nil end
	if i > j then i, j = j, i end
	local a, b = t[i], t[j]
	return s:sub(1, a[1] - 1) .. span_text(s, b) .. s:sub(a[2] + 1, b[1] - 1) .. span_text(s, a) .. s:sub(b[2] + 1)
end
function TOK.num(s) -- a digit run -> a boundary value
	local hits, p = {}, 1
	while #hits < 50 do
		local i, e = s:find("%d+", p)
		if not i then break end
		hits[#hits + 1] = { i, e }
		p = e + 1
	end
	if #hits == 0 then return nil end
	local h = pick(hits)
	return s:sub(1, h[1] - 1) .. pick(NUMS) .. s:sub(h[2] + 1)
end
function TOK.word(s, t) -- a word -> a generated word / a pool word
	local ws = {}
	for _, tk in ipairs(t) do
		if tk[3] == "w" then ws[#ws + 1] = tk end
	end
	if #ws == 0 then return nil end
	local tk = pick(ws)
	local w = chance(0.5) and pool_pick("word") or gen("word")
	return s:sub(1, tk[1] - 1) .. w .. s:sub(tk[2] + 1)
end
function TOK.heredoc(s) -- here-document quirks
	local k = r(5)
	if k == 1 then
		local i = s:find("<<[^<]")
		if i then return s:sub(1, i + 1) .. pick({ "-", "'", "\"", "\\", " " }) .. s:sub(i + 2) end
	elseif k == 2 then -- indent a delimiter line with tabs / spaces
		local lines = {}
		for l in (s .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
		local i = r(#lines)
		lines[i] = pick({ "\t", "  ", "\t\t" }) .. lines[i]
		return concat(lines, "\n")
	elseif k == 3 then
		return "x=$(cat <<EOF\n" .. s .. "\nEOF\n)\n" -- a here-document inside $( )
	elseif k == 4 then
		local i = r(#s + 1)
		return s:sub(1, i - 1) .. " <<" .. pick({ "E", "'E'", "-E", "\"E\"" }) .. s:sub(i) .. "\n" .. pick({ "", "\t" }) .. "E\n"
	end
	return s .. "\n" .. pick({ "EOF", "E", "\tEOF" }) .. "\n"
end
function TOK.extglob(s, t) -- extglob toggled between lines vs on the same line
	local ln = {}
	for l in (s .. (s:sub(-1) == "\n" and "" or "\n")):gmatch("(.-)\n") do ln[#ln + 1] = l end
	local i = r(#ln + 1)
	local ins = pick({ "shopt -s extglob", "shopt -u extglob", "shopt -s extglob; ", "shopt -s extglob; echo @(a|b)", "shopt -u extglob; [[ a == @(a) ]]" })
	if ins:sub(-2) == "; " and ln[i] then
		ln[i] = ins .. ln[i]
	else
		table.insert(ln, i, ins)
	end
	return concat(ln, "\n") .. "\n"
end
function TOK.alias(s, t) -- an alias that changes later parsing
	local ws = {}
	for _, tk in ipairs(t) do
		local x = span_text(s, tk)
		if tk[3] == "w" and x:match("^[%w_]+$") then ws[#ws + 1] = x end
	end
	local nm = #ws > 0 and pick(ws) or "a"
	local val = pick({ "if", "then", "{", "}", "(", "for x in", "case x in", "echo ", "!", "time", "done", "fi", "esac", "do", "#", "\\", "a=1 ", "$(", "[[", "]]", "x;", "\n", "coproc" })
	return "shopt -s expand_aliases\nalias " .. nm .. "=" .. G.sq(val) .. pick({ "\n", "; " }) .. s
end
function TOK.splice(s, t, add) -- a token range of another queue entry
	if not add or #add == 0 then return nil end
	local ta = tokens(add)
	if #ta == 0 then return nil end
	local a = r(#ta)
	local b = math.min(#ta, a + r(8) - 1)
	local seg = add:sub(ta[a][1], ta[b][2])
	local at = #t > 0 and t[r(#t)] or { 1, 0 }
	if chance(0.5) then -- replace a token range
		local c = math.min(#t, (#t > 0 and r(#t) or 0))
		if c > 0 then
			local lo, hi = t[math.min(c, #t)], t[math.min(#t, c + r(4) - 1)]
			return s:sub(1, lo[1] - 1) .. seg .. s:sub(hi[2] + 1)
		end
	end
	return s:sub(1, at[2]) .. seg .. s:sub(at[2] + 1)
end
function TOK.cad(s) -- code as data: mutate the text inside a single-quoted string (eval/trap/source bodies)
	local hits, p = {}, 1
	while #hits < 30 do
		local i = s:find("'", p, true)
		if not i then break end
		local j = s:find("'", i + 1, true)
		if not j then break end
		hits[#hits + 1] = { i, j }
		p = j + 1
	end
	if #hits == 0 then return nil end
	local h = pick(hits)
	local inner = s:sub(h[1] + 1, h[2] - 1)
	local tk = tokens(inner)
	local ops = { "trunc", "closer", "reserved", "ambig", "word", "num", "dup_tok" }
	local m = TOK[pick(ops)](inner, tk) or inner .. "; " .. gen("simple")
	return s:sub(1, h[1] - 1) .. G.sq(m) .. s:sub(h[2] + 1)
end

-- ---- wrappers: the same code in another context --------------------------------
local function hot_n()
	return pick({ 101, 120, 150, 160, 200, 250 })
end
local WRAP = {
	fn = function(x) return pick({ "f() { " .. x .. "\n}; f a b", "function f { " .. x .. "\n}; f; f", "f() ( " .. x .. "\n); f 1", "f() { local a b=2 x; " .. x .. "\n}; f x; echo $?" }) end,
	eval = function(x) return "eval " .. G.sq(x) end,
	source = function(x) return "printf '%s\\n' " .. G.sq(x) .. " > s; " .. pick({ ". ./s", "source ./s a b", "f() { . ./s; }; f" }) end,
	trap = function(x) return pick({ "trap " .. G.sq(x) .. " EXIT", "trap " .. G.sq(x) .. " USR1; kill -USR1 $$", "trap " .. G.sq(x) .. " ERR; false", "trap " .. G.sq(x) .. " RETURN; f() { :; }; f", "trap " .. G.sq(x) .. " DEBUG; :" }) end,
	sub = function(x) return pick({ "( " .. x .. "\n)", "{ " .. x .. "\n}", "x=$( " .. x .. "\n); echo \"[$x]\"", "echo \"$(" .. x .. "\n)\"", "{ " .. x .. "\n} | { read -r l; echo \"$l\"; }", ": | { " .. x .. "\n}", "{ " .. x .. "\n} &\nwait", "coproc { " .. x .. "\n}; wait", "{ " .. x .. "\n} 2>&1 >/dev/null", "! { " .. x .. "\n}", "time { " .. x .. "\n} 2>/dev/null", "{ " .. x .. "\n} > >(read -r l; echo \"$l\")" }) end,
	loop = function(x) local v = fresh(); return pick({ "for " .. v .. " in 1 2 3; do " .. x .. "\ndone", "while ((" .. v .. "++ < 3)); do " .. x .. "\ndone", "until ((" .. v .. "++ >= 2)); do " .. x .. "\ndone", "for " .. v .. " in 1 2; do " .. x .. "\nbreak; done" }) end,
	-- tier pressure: loops that go hot (the default threshold is 100 iterations) so the
	-- compiled tier and OSR / fragment resume run the body, some only AFTER the switch
	hot = function(x)
		local v, n = fresh(), hot_n()
		return pick({
			"for ((" .. v .. "=0; " .. v .. "<" .. n .. "; " .. v .. "++)); do " .. x .. "\ndone",
			v .. "=0; while ((" .. v .. "++ < " .. n .. ")); do " .. x .. "\ndone",
			"for ((" .. v .. "=0; " .. v .. "<" .. n .. "; " .. v .. "++)); do if ((" .. v .. " >= " .. pick({ 99, 100, 101, 110 }) .. ")); then " .. x .. "\nfi; done",
			"for ((" .. v .. "=0; " .. v .. "<" .. n .. "; " .. v .. "++)); do ((" .. v .. " == " .. pick({ 0, 99, 100, 101, n - 1 }) .. ")) && { " .. x .. "\n}; done",
			"f() { " .. x .. "\n}; for ((" .. v .. "=0; " .. v .. "<" .. n .. "; " .. v .. "++)); do f " .. v .. "; done",
			"( for ((" .. v .. "=0; " .. v .. "<" .. n .. "; " .. v .. "++)); do " .. x .. "\ndone )",
			"y=$(for ((" .. v .. "=0; " .. v .. "<" .. n .. "; " .. v .. "++)); do " .. x .. "\ndone); echo \"${#y}\"",
			"for ((" .. v .. "=0; " .. v .. "<" .. n .. "; " .. v .. "++)); do " .. x .. "\ndone | { while read -r l; do :; done; echo \"$l\"; }",
			"for ((" .. v .. "=0; " .. v .. "<" .. n .. "; " .. v .. "++)); do " .. x .. "\ndone &\nwait",
			"eval 'for ((" .. v .. "=0; " .. v .. "<" .. n .. "; " .. v .. "++)); do '" .. G.sq(x) .. "'\ndone'",
			"f() { for ((" .. v .. "=0; " .. v .. "<" .. n .. "; " .. v .. "++)); do " .. x .. "\ndone; }; f",
			v .. "=0; until ((" .. v .. "++ >= " .. n .. ")); do " .. x .. "\n[[ " .. v .. " -gt 105 ]] && continue; done",
			"for " .. v .. " in {1.." .. n .. "}; do " .. x .. "\ndone",
		})
	end,
}
local WRAPN = { "fn", "eval", "source", "trap", "sub", "loop", "hot", "hot", "hot" }

-- ---- AST-level operators ------------------------------------------------------------
local AST = {}
function AST.replace(ast, slots, words, add) -- a subtree -> same-kind subtree of another entry / pool
	if #slots == 0 then return nil end
	local s = pick(slots)
	local src
	if add and chance(0.4) then
		local a = parse(add)
		if a then
			local sl = collect(a)
			local same = {}
			for _, x in ipairs(sl) do
				if x[3].t == s[3].t then same[#same + 1] = x end
			end
			local c = #same > 0 and pick(same) or sl[1] and pick(sl)
			if c then
				s[1][s[2]] = c[3]
				return "splice"
			end
		end
	end
	src = chance(0.6) and pool_pick(s[3].t) or pool_pick("cmd")
	local node = src and text_node(src)
	if not node then return nil end
	s[1][s[2]] = node
	return "pool"
end
function AST.gen(ast, slots) -- a subtree -> a generated one
	if #slots == 0 then return nil end
	local s = pick(slots)
	local node = text_node(gen("list"))
	if not node then return nil end
	s[1][s[2]] = node
	return "gen"
end
function AST.wrap(ast, slots) -- a subtree -> itself in another context
	if #slots == 0 then return nil end
	local s = pick(slots)
	local x = node_text(s[3])
	if not x then return nil end
	local w = pick(WRAPN)
	local node = text_node(WRAP[w](x))
	if not node then return nil end
	s[1][s[2]] = node
	return "wrap-" .. w
end
function AST.word(ast, slots, words, add)
	if #words == 0 then return nil end
	local w = pick(words)
	local k = r(4)
	if k == 1 then
		w.src = pool_pick("word") or gen("word")
	elseif k == 2 then
		w.src = gen("word")
	elseif k == 3 then
		local o = pick(words)
		w.src, o.src = o.src, w.src
	else
		w.src = pick({ "\"" .. w.src .. "\"", w.src .. gen("word"), "${x:-" .. w.src .. "}", "$(echo " .. w.src .. ")", "\"${x-" .. w.src .. "}\"", "'" .. w.src .. "'", "`echo " .. w.src .. "`" })
	end
	return "word"
end
function AST.dup(ast, slots) -- a statement duplicated / dropped / moved at the top level
	local st = ast.stmts
	if #st == 0 then return nil end
	local i = r(#st)
	local k = r(3)
	if k == 1 then
		table.insert(st, r(#st + 1), st[i])
	elseif k == 2 and #st > 1 then
		table.remove(st, i)
	else
		local x = table.remove(st, i)
		table.insert(st, r(#st + 1), x)
	end
	return "stmt"
end
local ASTN = { "replace", "replace", "gen", "wrap", "wrap", "word", "word", "dup" }

-- ---- the mutation driver --------------------------------------------------------------
local STATS = { calls = 0, out_ok = 0, out_perr = 0, out_throw = 0, in_ok = 0, in_bad = 0, ops = {} }
local function count(op)
	STATS.ops[op] = (STATS.ops[op] or 0) + 1
end

local TOKN = { "trunc", "trunc", "closer", "closer", "reserved", "ambig", "ambig", "bsnl", "hash", "bytes",
	"dup_tok", "swap_tok", "num", "word", "word", "heredoc", "extglob", "alias", "splice", "splice", "cad", "cad", "trunc_byte" }

local function one(s, add)
	local k = r(100)
	if k <= 45 then -- structural
		local ast = parse(s)
		if not ast and chance(0.7) then
			k = 100 -- (unparseable: mostly token-level edits instead)
		end
		if ast then
			local slots, words = collect(ast)
			local op = pick(ASTN)
			local res = AST[op](ast, slots, words, add)
			if res then
				local out = print_ast(ast)
				if out then
					return out, "ast-" .. res
				end
			end
		end
	end
	if k <= 55 then -- insert a generated statement / a whole generated script
		local lines = {}
		for l in (s .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
		if chance(0.15) or #s == 0 then
			return gen_line(8 + r(20)), "gen-script"
		end
		table.insert(lines, r(#lines + 1), gen("list"))
		return concat(lines, "\n"), "gen-line"
	end
	if k <= 62 then -- wrap the whole script (or a line of it)
		local w = pick(WRAPN)
		if chance(0.5) then
			return WRAP[w](s) .. "\n", "wrap-" .. w
		end
		local lines = {}
		for l in (s .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
		local i = r(#lines)
		if lines[i] ~= "" then
			lines[i] = WRAP[w](lines[i])
		end
		return concat(lines, "\n"), "wrapl-" .. w
	end
	if k <= 67 then
		return preamble() .. pick({ "\n", "; " }) .. s, "pre"
	end
	local t = tokens(s)
	for _ = 1, 4 do
		local op = pick(TOKN)
		local out = TOK[op](s, t, add)
		if out and out ~= s then
			return out, "tok-" .. op
		end
	end
	return nil
end

local function mutate(s, add, max)
	STATS.calls = STATS.calls + 1
	harvest(s)
	if add and #add > 0 and chance(0.1) then
		harvest(add)
	end
	local n = chance(0.7) and 1 or (1 + r(3))
	local descs = {}
	local out = s
	for _ = 1, n do
		local o, d = one(out, add)
		if o then
			out = o
			descs[#descs + 1] = d
			count(d)
		end
	end
	max = math.min(max, 16384) -- (the harness reads 64 KB; big scripts only slow the loop)
	if #out > max then
		out = out:sub(1, max)
	end
	if #descs == 0 then
		out = TOK.bsnl(s)
		descs[1] = "tok-fallback"
	end
	return out, concat(descs, "+")
end

local function classify(s)
	local _, why = parse(s, true)
	return why
end

-- ---- the targeted fuzzers' input languages (GRAM_TARGET; harness FUZZ_TARGET, targets.lua) --
-- Each target's input is a small text in one subsystem's language (targets.lua has the
-- formats). A small generator per language, plus language-agnostic edits on the text:
-- a random span replaced by a generated fragment / a dictionary token / a span of the splice
-- partner, spans dropped or duplicated, digit runs set to boundary values, and the `#@`
-- options header toggled. `parse` inputs are scripts: the script mutator above serves them.
local TG = {}
local TVARS = { "x", "y", "n", "i", "ii", "s", "r", "z", "h", "big", "u", "w", "e", "a", "A", "m", "up", "lo", "ref", "g", "p", "bs", "q", "nl", "t" }
local HDRS = { "extglob", "nocasematch", "nocaseglob", "globasciiranges", "dotglob", "nullglob", "failglob", "xpg_echo", "posix", "utf8", "noglob", "nopatsub" }
local function nosub(s) -- (targets.lua refuses these: never generate them)
	return (s:gsub("%$%(", "$ ("):gsub("`", "'"):gsub("([<>])%(", "%1 ("))
end
local function tvar() return pick(TVARS) end
local function tnum() return chance(0.6) and tostring(r(20) - 5) or pick(NUMS) end

TG.arith = {}
function TG.arith.frag(d)
	d = d or 0
	if d > 3 or chance(0.3) then
		local k = r(10)
		if k <= 3 then return tnum() end
		if k <= 6 then return tvar() end
		if k == 7 then return tvar() .. "[" .. TG.arith.frag(d + 1) .. "]" end
		if k == 8 then return pick({ "a", "A", "m" }) .. "[" .. pick({ "0", "1", "-1", "k", "k2", "@", "*", "x", "i++", "$x", "\"k\"", "'k'", "" }) .. "]" end
		if k == 9 then return pick({ "$x", "${x}", "${#w}", "$n", "${a[1]}", "${A[k]}", "$1", "$#", "\"1\"", "'1'", "$[1]", "$((1))" }) end
		return pick({ "0x", "08", "09", "1#", "2#2", "37#1", "64#_", "64#@@", "10#", "#", "0b1", "1.5", "1e2", " ", "", "\t", "\n", "\\", "@", "é" })
	end
	local k = r(11)
	if k <= 4 then
		return TG.arith.frag(d + 1) .. pick({ "", " " }) .. pick({ "+", "-", "*", "/", "%", "**", "<<", ">>", "&", "|", "^", "&&", "||", "<", ">", "<=", ">=", "==", "!=", ",", "=", "+=", "-=", "*=", "/=", "%=", "<<=", ">>=", "&=", "|=", "^=", "**=", "===", "=<", "<>", "!" }) .. pick({ "", " " }) .. TG.arith.frag(d + 1)
	elseif k == 5 then
		return pick({ "-", "+", "!", "~", "++", "--", "- -", "+ +", "!!", "~-" }) .. TG.arith.frag(d + 1)
	elseif k == 6 then
		return tvar() .. pick({ "++", "--", "[1]++", "[k]--" })
	elseif k == 7 then
		return TG.arith.frag(d + 1) .. " ? " .. TG.arith.frag(d + 1) .. " : " .. TG.arith.frag(d + 1)
	elseif k == 8 then
		return "(" .. TG.arith.frag(d + 1) .. ")"
	elseif k == 9 then
		return TG.arith.frag(d + 1) .. pick({ " ? ", " : ", "(", ")", "[", "]", "?:", "," })
	elseif k == 10 then
		return tvar() .. "=" .. TG.arith.frag(d + 1)
	end
	return pick({ "a[", "A[", "m[" }) .. TG.arith.frag(d + 1) .. "]" .. pick({ "", "=", "+=", "++", " = " .. TG.arith.frag(d + 1) })
end
function TG.arith.gen()
	return (chance(0.15) and "=" or "") .. nosub(TG.arith.frag())
end
TG.arith.dict = { "+", "-", "*", "/", "%", "**", "<<", ">>", "?", ":", "(", ")", "[", "]", ",", "=", "++", "--", "#", "0x", "08", "64#", "9223372036854775807", "-9223372036854775808", "a[", "A[k]", "x", "u", " ", "$" }

TG.pexp = {}
local POPS = { "-", ":-", "=", ":=", "?", ":?", "+", ":+", "#", "##", "%", "%%", "/", "//", "/#", "/%", "^", "^^", ",", ",,", "~", "~~", ":", "@Q", "@E", "@P", "@A", "@a", "@U", "@u", "@L", "@K", "@k" }
local PSUB = { "", "", "", "[@]", "[*]", "[0]", "[1]", "[-1]", "[k]", "[k2]", "[x+1]", "[$n]", "[\"k\"]", "[' ']", "[]", "[@", "[9223372036854775807]" }
function TG.pexp.pword(d)
	d = d or 0
	local k = r(12)
	if d > 2 or k <= 3 then
		return pick({ "a", "*", "?", "[ab]", "o", "l*", "\\*", "'x y'", "\"$w\"", "$p", "${g}", "", " ", "&", "\\&", "\\/", "/", "}", "\\}", "@(o|l)", "+(l)", "!(x)", "*(o)", "[[:space:]]", "[^a]", "[!a-m]", "é", "\\", "'", "\"", "${x}", "$1", "$@", "${a[@]}", "\"${a[@]}\"", "~", "\t" })
	end
	if k <= 7 then return TG.pexp.expn(d + 1) end
	return TG.pexp.pword(d + 1) .. TG.pexp.pword(d + 1)
end
function TG.pexp.expn(d)
	d = d or 0
	local nm = chance(0.85) and tvar() or pick({ "@", "*", "#", "1", "2", "3", "0", "?", "-", "x y", "", "!", "9", "10" })
	local sub = pick(PSUB)
	local k = r(10)
	if k == 1 then return "$" .. nm end
	if k == 2 then return "${" .. pick({ "#", "!", "" }) .. nm .. sub .. "}" end
	local op = pick(POPS)
	local arg = ""
	if op == ":" then
		arg = pick({ "0", "1", "-1", " -2", "(-1)", "1:2", "x", "$n", "2:-1", "n:1", "-3:-1", "9223372036854775807", "1:", ":", "a[1]", "1 ? 1 : 0" })
	elseif op:sub(1, 1) == "@" then
		arg = ""
	elseif op == "/" or op == "//" or op == "/#" or op == "/%" then
		arg = TG.pexp.pword(d) .. pick({ "", "/", "/" .. TG.pexp.pword(d) })
	elseif op == "^" or op == "^^" or op == "," or op == ",," or op == "~" or op == "~~" then
		arg = pick({ "", "a", "[a-m]", "?", "*", "[[:upper:]]", "o" })
	else
		arg = TG.pexp.pword(d)
	end
	return "${" .. nm .. sub .. op .. arg .. "}"
end
function TG.pexp.gen()
	local parts = {}
	for _ = 1, 1 + r(3) do
		local e = TG.pexp.expn()
		local k = r(4)
		if k == 1 then e = "\"" .. e .. "\"" elseif k == 2 then e = "x" .. e .. "'y'" end
		parts[#parts + 1] = e
	end
	return nosub(concat(parts, " "))
end
TG.pexp.dict = { "${", "}", "\"", "'", "[@]", "[*]", ":-", ":=", "#", "##", "%", "%%", "//", "/#", "/%", "^^", ",,", "@Q", "@E", "@A", "@a", "@K", ":1:2", "$@", "$*", "${!", "${#", "\\", "*", "?", "[", "]", "&" }

TG.printf = {}
local CONV = { "d", "i", "o", "u", "x", "X", "e", "E", "f", "F", "g", "G", "a", "A", "c", "s", "b", "q", "Q", "(%Y-%m-%d)T", "(%s)T", "n", "%", "y", "", "ld", "lld", "hd", "zu", "jd", "Lf", "hhd" }
function TG.printf.fmt()
	local out = {}
	for _ = 1, 1 + r(4) do
		local k = r(6)
		if k <= 3 then
			out[#out + 1] = "%" .. (chance(0.4) and pick({ "-", "+", " ", "#", "0", "'", "-0", "+ ", "#0", "--" }) or "")
				.. (chance(0.4) and pick({ "5", "*", "0", "12", "-3", "99999999999", "1$", "2$*", "*1$" }) or "")
				.. (chance(0.35) and pick({ ".", ".0", ".3", ".*", ".99", ".-1" }) or "") .. pick(CONV)
		elseif k == 4 then
			out[#out + 1] = pick({ "\\n", "\\t", "\\\\", "\\x41", "\\x4", "\\xg", "\\0101", "\\101", "\\u263a", "\\U0001F600", "\\c", "\\e", "\\a", "\\'", "\\\"", "\\?", "\\", "\\q", "\\x", "\\u", "%%" })
		else
			out[#out + 1] = pick({ "a", "x=", " ", "|", "é", "\xff", "-", "\t" })
		end
	end
	return concat(out)
end
local PARGS = { "0", "1", "-1", "42", "3.14159", "-0", "1e3", "0x1F", "0X1f", "010", "08", "'a", "\"é", "'", "\"", "", " 12", "12 ", "abc", "9223372036854775807", "9223372036854775808", "-9223372036854775809", "18446744073709551615", "inf", "-inf", "nan", "1.5e308", "1e-320", "\\n", "a\\cb", "\\0101", "%s", "0.5", "+7", "--1", "1,5", "0x", "1a" }
function TG.printf.gen()
	local l = { TG.printf.fmt() }
	for _ = 1, r(4) - 1 do
		l[#l + 1] = pick(PARGS)
	end
	return concat(l, "\n")
end
TG.printf.dict = { "%", "%s", "%d", "%b", "%q", "%Q", "%c", "%x", "%(%s)T", "%*d", "%.*s", "%-5s", "\\", "\\x", "\\0", "\\u", "\\c", "\n", "'a", "0x", "9223372036854775807" }

TG.glob = {}
function TG.glob.pat(d)
	d = d or 0
	local out = {}
	for _ = 1, 1 + r(3) do
		local k = r(12)
		if k <= 3 then
			out[#out + 1] = pick({ "a", "b", "ab", "x", ".", "-", "é", "A", " ", "]", "!", "^", "/", "\\", "\xff" })
		elseif k <= 5 then
			out[#out + 1] = pick({ "*", "?", "**", "*?", "\\*", "\\?", "\\[", "\\\\" })
		elseif k <= 8 then
			local body = pick({ "ab", "a-c", "!a", "^a", "]a", "!]", "a-", "-a", "[:alpha:]", "[:digit:][:space:]", "[:foo:]", "[.a.]", "[=a=]", "\\]", "z-a", "é", "[", "a\\-z", "![:upper:]", "" })
			out[#out + 1] = "[" .. body .. (chance(0.9) and "]" or "")
		elseif d < 2 then
			local alts = {}
			for _ = 1, 1 + r(3) do alts[#alts + 1] = TG.glob.pat(d + 1) end
			out[#out + 1] = pick({ "@(", "*(", "+(", "?(", "!(" }) .. concat(alts, "|") .. (chance(0.92) and ")" or "")
		else
			out[#out + 1] = "a"
		end
	end
	return concat(out)
end
function TG.glob.str()
	local out = {}
	for _ = 1, r(6) - 1 do
		out[#out + 1] = pick({ "a", "b", "ab", "x", ".", "-", "é", "A", " ", "]", "[", "!", "*", "?", "/", "\\", "\xff", "abab", "aaa", "B", "(", "|", ")" })
	end
	return concat(out)
end
function TG.glob.gen()
	return TG.glob.pat() .. "\n" .. TG.glob.str()
end
TG.glob.dict = { "*", "?", "[", "]", "[!", "[^", "[:alpha:]", "[:upper:]", "@(", "*(", "+(", "?(", "!(", "|", ")", "\\", "-", "é" }

TG.read = {}
function TG.read.gen()
	local ifs = chance(0.2) and "U" or "=" .. pick({ "", " ", ":", " :", " \t", ":,", "x", "\\", " x ", "::", "\t", "é", " \t:" })
	local opts = {}
	for _ = 1, r(4) - 1 do
		local o = pick({ "-r", "-s", "-a", "-d", "-n", "-N" })
		if o == "-d" then o = o .. " " .. pick({ ":", "x", "", "\\", " " }) end
		if o == "-n" or o == "-N" then o = o .. " " .. pick({ "0", "1", "3", "-1", "9223372036854775807", "99" }) end
		opts[#opts + 1] = o
	end
	local data = {}
	for _ = 1, 1 + r(5) do
		data[#data + 1] = pick({ "a", "b c", " ", "\t", ":", "::", "a:b", "\\", "\\ ", "\\:", "\\\n", "\n", "x", "é", "  lead", "trail  ", "a,b" })
	end
	return ifs .. "\n" .. concat(opts, " ") .. "\n" .. concat(data)
end
TG.read.dict = { "U", "=", "-r", "-a", "-d", "-n", "-N", "\\", "\n", " ", "\t", ":" }

TG.regex = {}
function TG.regex.re(d)
	d = d or 0
	local out = {}
	for _ = 1, 1 + r(3) do
		local k = r(12)
		if k <= 3 then
			out[#out + 1] = pick({ "a", "b", "ab", "x", "é", "A", " ", "-", "/", "]", "}", "{", "\\" })
		elseif k <= 5 then
			out[#out + 1] = pick({ ".", "^", "$", "\\.", "\\1", "\\2", "\\w", "\\b", "\\<", "\\n", "\\(", "\\" })
		elseif k <= 7 then
			out[#out + 1] = "[" .. pick({ "ab", "a-c", "^a", "]a", "[:alpha:]", "[:digit:]", "[:foo:]", "[.a.]", "[=a=]", "a-", "\\]", "z-a", "é" }) .. (chance(0.9) and "]" or "")
		elseif k <= 9 then
			out[#out + 1] = pick({ "*", "+", "?", "{2}", "{1,}", "{,2}", "{2,1}", "{", "*?", "**", "+*", "{99999}", "{1,3}" })
		elseif d < 2 then
			local alts = {}
			for _ = 1, 1 + r(2) do alts[#alts + 1] = TG.regex.re(d + 1) end
			out[#out + 1] = "(" .. concat(alts, "|") .. (chance(0.9) and ")" or "")
		else
			out[#out + 1] = "()"
		end
	end
	return concat(out)
end
function TG.regex.gen()
	local re = TG.regex.re()
	if chance(0.5) then
		local lit = {}
		for c in re:gmatch(".") do lit[#lit + 1] = c end
		-- literal form: some chars quoted, a variable spliced in, shell-special chars escaped
		local out = {}
		for _, c in ipairs(lit) do
			if c:match("[ ;&|<>]") then c = "\\" .. c end
			out[#out + 1] = c
		end
		local s = concat(out)
		local k = r(4)
		if k == 1 then s = "\"" .. s .. "\""
		elseif k == 2 then s = s .. "\".\"" .. pick({ "$p", "$g", "${w}", "'x*'" })
		elseif k == 3 then s = "'" .. s:gsub("'", "") .. "'" .. s end
		return "l " .. nosub(s) .. "\n" .. TG.glob.str()
	end
	return "v " .. re .. "\n" .. TG.glob.str()
end
TG.regex.dict = { "(", ")", "|", "*", "+", "?", "{", "}", "[", "]", "^", "$", ".", "\\", "[:alpha:]", "\"", "'", "$p", "l ", "v " }

-- language-agnostic edits
local function span(s)
	local i = r(#s + 1)
	return i, math.min(#s, i + r(8) - 1)
end
local function tone(tg, s, add)
	local L = TG[tg]
	local hdr, body = s:match("^(#@[^\n]*\n)(.*)$")
	hdr, body = hdr or "", hdr and body or s
	local k = r(100)
	if k <= 12 or #body == 0 then
		return hdr .. L.gen(), "t-gen"
	elseif k <= 20 then
		local opts = {}
		for _ = 1, r(3) do opts[#opts + 1] = pick(HDRS) end
		return (chance(0.2) and "" or "#@ " .. concat(opts, " ") .. "\n") .. body, "t-hdr"
	end
	local i, j = span(body)
	local pre, mid, post = body:sub(1, i - 1), body:sub(i, j), body:sub(j + 1)
	if k <= 45 then -- a span -> a generated fragment of the language
		local f = L.frag and L.frag() or L.gen()
		f = f:gsub("\n.*", "")
		return hdr .. pre .. f .. post, "t-frag"
	elseif k <= 60 then
		return hdr .. pre .. pick(L.dict) .. (chance(0.5) and mid or "") .. post, "t-dict"
	elseif k <= 68 then
		return hdr .. pre .. post, "t-drop"
	elseif k <= 74 then
		return hdr .. pre .. mid .. mid .. post, "t-dup"
	elseif k <= 82 and add and #add > 0 then
		local a, b = r(#add), r(#add)
		if a > b then a, b = b, a end
		return hdr .. pre .. add:sub(a, math.min(b, a + 16)) .. post, "t-splice"
	elseif k <= 90 then
		local d0, d1 = body:find("%-?%d+")
		if d0 then
			return hdr .. body:sub(1, d0 - 1) .. pick(NUMS) .. body:sub(d1 + 1), "t-num"
		end
		return hdr .. pre .. tnum() .. post, "t-num"
	elseif k <= 95 then
		return hdr .. pre .. pick({ "\n", "\\", "'", "\"", "\0", "\xff", "é", "\t", " ", "}", "{", "$" }) .. post, "t-byte"
	end
	return hdr .. body:sub(1, r(#body + 1) - 1), "t-trunc"
end
local function tmutate(tg, s, add, max)
	STATS.calls = STATS.calls + 1
	local n = chance(0.6) and 1 or (1 + r(3))
	local out, descs = s, {}
	for _ = 1, n do
		local o, d = tone(tg, out, add)
		if o then
			out = nosub(o)
			descs[#descs + 1] = d
			count(d)
		end
	end
	max = math.min(max, 2048)
	if #out > max then
		out = out:sub(1, max)
	end
	return out, concat(descs, "+")
end
local TARGET = os.getenv("GRAM_TARGET")
if TARGET and not TG[TARGET] then
	TARGET = nil -- (parse, or a script mode: the script mutator)
end
if TARGET then
	mutate = function(s, add, max)
		return tmutate(TARGET, s, add, max)
	end
	classify = function()
		return "ok"
	end
end

-- ---- the protocol -----------------------------------------------------------------------
-- request:  "M" u32 seed u32 max u32 len <len bytes> u32 addlen <addlen bytes>
-- response: u32 len <len bytes> u8 dlen <dlen bytes>
-- stats go to $GRAM_STATS (rewritten every 500 calls); every 8th output is classified.
local function u32(s, i)
	local a, b, c, d = s:byte(i, i + 3)
	return a + b * 256 + c * 65536 + d * 16777216
end
local function p32(n)
	return string.char(n % 256, floor(n / 256) % 256, floor(n / 65536) % 256, floor(n / 16777216) % 256)
end

local function write_stats()
	local path = os.getenv("GRAM_STATS")
	if not path then return end
	local f = io.open(path .. ".tmp", "w")
	if not f then return end
	local cl = STATS.out_ok + STATS.out_perr + STATS.out_throw
	f:write(string.format("calls %d\nclassified %d\nparse_ok %d\nparse_perr %d\nparse_throw %d\nvalid_frac %.3f\ninput_parse_ok %d\ninput_parse_bad %d\npool %d\n",
		STATS.calls, cl, STATS.out_ok, STATS.out_perr, STATS.out_throw, cl > 0 and STATS.out_ok / cl or 0, STATS.in_ok, STATS.in_bad, POOLN))
	local ks = {}
	for k in pairs(STATS.ops) do ks[#ks + 1] = k end
	table.sort(ks)
	for _, k in ipairs(ks) do
		f:write("op ", k, " ", STATS.ops[k], "\n")
	end
	f:close()
	os.rename(path .. ".tmp", path)
end

local function serve()
	local inp, out = io.stdin, io.stdout
	out:setvbuf("full")
	while true do
		local h = inp:read(13)
		if not h or #h < 13 or h:sub(1, 1) ~= "M" then
			break
		end
		local seed, max, len = u32(h, 2), u32(h, 6), u32(h, 10)
		local s = len > 0 and inp:read(len) or ""
		local al = u32(inp:read(4), 1)
		local add = al > 0 and inp:read(al) or nil
		math.randomseed(seed)
		local ok, res, desc = pcall(mutate, s, add, max)
		if not ok then
			io.stderr:write("gram: ", tostring(res), "\n")
			res, desc = TOK.bsnl(s), "lua-error"
		end
		if STATS.calls % 8 == 0 then
			local c = classify(res)
			STATS["out_" .. c] = STATS["out_" .. c] + 1
			local ci = classify(s)
			STATS[ci == "ok" and "in_ok" or "in_bad"] = STATS[ci == "ok" and "in_ok" or "in_bad"] + 1
		end
		if STATS.calls % 500 == 0 then
			write_stats()
		end
		desc = desc:sub(1, 200)
		out:write(p32(#res), res, string.char(#desc), desc)
		out:flush()
	end
	write_stats()
end

if arg[2] == "--classify" then
	local c = { ok = 0, perr = 0, throw = 0 }
	for i = 3, #arg do
		local f = io.open(arg[i], "rb")
		if f then
			local s = f:read("a")
			f:close()
			local why = classify(s)
			c[why] = c[why] + 1
		end
	end
	local n = c.ok + c.perr + c.throw
	print(string.format("files %d ok %d perr %d throw %d valid_frac %.3f", n, c.ok, c.perr, c.throw, n > 0 and c.ok / n or 0))
elseif arg[2] == "--sample" or arg[2] == "--time" then
	local n, seed = tonumber(arg[3]) or 10, tonumber(arg[4]) or 1
	local s = io.read("a")
	local cur = s
	for i = 1, n do
		math.randomseed(seed + i)
		local t0 = os.clock()
		local o, d = mutate(cur, s, 65536)
		local dt = os.clock() - t0
		if arg[2] == "--sample" then
			io.write("==== ", d, " [", classify(o), "]\n", o, "\n")
		elseif dt > 0.02 then
			io.write(string.format("SLOW %.3fs %s len=%d->%d i=%d\n", dt, d, #cur, #o, i))
		end
		if arg[5] == "chain" then cur = o end
	end
else
	serve()
end
