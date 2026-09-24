-- Transpile the AST to a resumable Lua module using a flattened control-flow
-- graph dispatched on a program counter:
--
--   return { loopPc = {id->pc}, stmtPc = {k->pc}, run = function(sh, pc) ... end }
--
-- run() seeds lifted vars from `sh`, then `while true do if pc==N then …; pc=M …`.
-- Because control flow is flattened, run() can be ENTERED at ANY pc — the cond
-- check of any loop, at any nesting depth — and following the pc transitions
-- reconstructs the full continuation (inner loop exits -> outer step -> …). That
-- is general on-stack replacement: the interpreter hands off at a loop back-edge
-- and we jump into compiled code at that loop's cond pc. LuaJIT traces the hot
-- pc path to machine code with ~zero dispatch overhead (measured 1.01x native).
--
-- Vars used only arithmetically (all assignments arithmetic or a numeric
-- literal) are LIFTED to native Lua int64 locals, seeded from `sh` on entry and
-- written back on exit. Everything else stays in `sh`, so both tiers share it.
local M = {}
-- Deterministic iteration: every table walk that can shape the emitted code (lifted-var
-- flush order, serialized AST keys, func_src order, …) goes through spairs, so the same
-- program always compiles to byte-identical Lua (reproducible artifacts; refactors of the
-- emitter can be verified by diffing its output).
local function spairs_lt(a, b)
	local ta, tb = type(a), type(b)
	if ta ~= tb then
		return ta < tb
	end
	if ta == "number" or ta == "string" then
		return a < b
	end
	return tostring(a) < tostring(b)
end
local function spairs(t)
	local keys = {}
	for k in pairs(t) do
		keys[#keys + 1] = k
	end
	table.sort(keys, spairs_lt)
	local i = 0
	return function()
		i = i + 1
		local k = keys[i]
		if k ~= nil then
			return k, t[k]
		end
	end
end

local CMP = { ["=="] = "==", ["!="] = "~=", ["<"] = "<", ["<="] = "<=", [">"] = ">", [">="] = ">=" }
local function lname(n)
	return "v_" .. n
end
-- A valid Lua identifier for the closure of shell function `n`. bash function names
-- may hold -/./=/! etc. (`foo-bar`, `my.helper`), which can't spell a Lua local, so
-- escape every non-identifier byte as `_XX_`. sh.functions is still keyed by the
-- original name (the dispatch key); only the generated identifier is mangled.
local function fnlname(n)
	return "fn_" .. n:gsub("[^%w_]", function(c)
		return ("_%02x_"):format(c:byte())
	end)
end

-- Does the program create an ATTRIBUTED variable — one whose later plain `name=value`
-- assignment isn't a simple string set: readonly (reject), an array (write [0]), or
-- declare -i/-l/-u (arith / case-fold)? Detects the attribute BUILTINS and array
-- assignments. When false, compiled scalar assignments are a bare sh:set_str (zero
-- hot-path cost); when true they route through I.assign_scalar. A var attributed via
-- eval is rare and simply unguarded — no worse than before.
-- variables the shell itself makes readonly (bash): UID=… etc. is an error
local BUILTIN_RO = { UID = 1, EUID = 1, PPID = 1, BASH_VERSINFO = 1, SHELLOPTS = 1, BASHOPTS = 1 }
local EF = {} -- emit-time program flags, grouped so a function referencing several stays one upvalue
EF.has_attr = false
-- Does any node of the tree (every statement, word, arith node — at any depth: &&/||
-- lists, pipelines, conditions, bodies) satisfy `pred`? The program scanners below gate
-- whole code paths on "X appears anywhere", so they must not miss a node shape.
local function any_node(node, pred)
	if type(node) ~= "table" then
		return false
	end
	if pred(node) then
		return true
	end
	for _, v in pairs(node) do
		if type(v) == "table" and any_node(v, pred) then
			return true
		end
	end
	return false
end
local function makes_attr(st)
	if st.t == "arrayassign" then
		return true
	end -- a=(…) makes an array
	if st.t == "assign" and st.index then
		return true
	end -- a[i]=… makes/extends an array
	if (st.t == "assign" or st.t == "simple") and st.name and BUILTIN_RO[st.name] then
		return true -- assigning a shell-readonly var (UID=…) must be rejected: guarded path
	end
	for _, a in ipairs(st.assigns or {}) do
		if BUILTIN_RO[a.name] then
			return true
		end
	end
	if st.t ~= "simple" or not st.words[1] then
		return false
	end
	local c = st.words[1].parts[1] and #st.words[1].parts == 1 and st.words[1].parts[1].lit
	if c == "readonly" or c == "declare" or c == "typeset" or c == "local" or c == "export" then
		return true
	end
	if c == "set" then -- `set -a` / `set -o allexport` makes later plain assigns auto-export
		for j = 2, #st.words do
			local l = st.words[j].parts[1] and st.words[j].parts[1].lit
			if l == "-a" or l == "allexport" or (l and l:match("^%-%a*a")) then
				return true
			end
		end
	end
	return false
end
local function scan_attr(stmts)
	return any_node(stmts, function(n)
		return n.t ~= nil and makes_attr(n)
	end)
end
-- Does the program create a nameref (declare/typeset/local -n)? A plain `name=value`
-- assignment then WRITES THROUGH the nameref (to a var, an array/assoc element, or a
-- detected cycle) — semantics only interp's full assign implements; the native
-- assign_scalar can't. When present, delegate scalar assigns so those work. Rare, so
-- the native fast assign is kept for every ordinary program.
EF.has_nameref = false
EF.has_dyncode = false -- program runs eval/source/. → $(…) bodies can't assume names are externals
-- Does the program run eval / source / . anywhere? If so a command NAME that looks
-- external at compile time could actually be a runtime-defined shell function that
-- mutates state — so a $(…) whose body calls it must FORK for isolation. Absent any
-- dynamic code, a literal non-builtin non-funcdef name is provably an external
-- (a separate process, cannot touch the parent shell), so its $(…) can run in-process.
local function makes_dyncode(st)
	if st.t ~= "simple" or not st.words[1] then
		return false
	end
	local c = st.words[1].parts[1] and #st.words[1].parts == 1 and st.words[1].parts[1].lit
	return c == "eval" or c == "source" or c == "."
end
local function scan_dyncode(stmts)
	return any_node(stmts, function(n)
		return n.t == "simple" and makes_dyncode(n)
	end)
end
local function makes_nameref(st)
	if st.t ~= "simple" or not st.words[1] then
		return false
	end
	local c = st.words[1].parts[1] and #st.words[1].parts == 1 and st.words[1].parts[1].lit
	if c ~= "declare" and c ~= "typeset" and c ~= "local" then
		return false
	end
	for j = 2, #st.words do
		local l = st.words[j].parts[1] and st.words[j].parts[1].lit
		if l and l:match("^%-%a*n") then
			return true
		end
		if l and l:sub(1, 1) ~= "-" then
			break
		end -- past the flags
	end
	return false
end
local function scan_nameref(stmts)
	return any_node(stmts, function(n)
		return n.t == "simple" and makes_nameref(n)
	end)
end
-- Does any word in the program READ a call-stack var (FUNCNAME/BASH_SOURCE/BASH_LINENO)?
-- Gates funcstack/linestack/srcstack maintenance around compiled calls (else zero cost).
local DEBUGSTACK_VAR = { FUNCNAME = 1, BASH_SOURCE = 1, BASH_LINENO = 1 }
-- BASH_LINENO/FUNCNAME/BASH_SOURCE can also be read as an arith VAR node inside
-- $((…)) / (( )) (`echo $((BASH_LINENO))`); walk the arith tree for one.
local function arith_reads_debugstack(e)
	if type(e) ~= "table" then
		return false
	end
	if e.k == "var" and DEBUGSTACK_VAR[e.name] then
		return true
	end
	return arith_reads_debugstack(e.e)
		or arith_reads_debugstack(e.l)
		or arith_reads_debugstack(e.r)
		or arith_reads_debugstack(e.c)
		or arith_reads_debugstack(e.a)
		or arith_reads_debugstack(e.b)
end
local function word_reads_debugstack(w)
	for _, p in ipairs(w.parts) do
		if (p.var and DEBUGSTACK_VAR[p.var]) or (p.pexp and DEBUGSTACK_VAR[p.pexp.name]) then
			return true
		end
		-- an INDIRECT expansion ${!ref} can name FUNCNAME/BASH_SOURCE/BASH_LINENO at
		-- runtime (`ref=FUNCNAME; echo ${!ref}`) — can't know statically, so maintain the
		-- call stack whenever one is present (rare; cost is per-call enterFunc/leaveFunc).
		if p.pexp and (p.pexp.op == "indirect" or p.pexp.via_indirect) then
			return true
		end
		-- code in a STRING (a trap handler, an eval'd string) is expanded at runtime:
		-- a literal naming one of the stacks may read it there
		if p.lit and (p.lit:find("FUNCNAME", 1, true) or p.lit:find("BASH_SOURCE", 1, true)
			or p.lit:find("BASH_LINENO", 1, true) or p.lit:find("caller", 1, true)) then
			return true
		end
		-- p.arith is a source string; arith() can THROW on a malformed expr (only the
		-- parser's own `parith` wrapper turns that into arith_perr), so pcall it — a
		-- parse failure just means "no debugstack ref here" (the stmt delegates anyway).
		if p.arith then
			local ok, ast = pcall(require("parser").arith, p.arith)
			if ok and arith_reads_debugstack(ast) then
				return true
			end
		end
		if p.arithast and arith_reads_debugstack(p.arithast) then
			return true
		end
		local cs = p.cmdsub or p.procsub -- (a $(…)/`…` body runs in this shell's frames)
		if type(cs) == "string" and (cs:find("FUNCNAME", 1, true) or cs:find("BASH_SOURCE", 1, true)
			or cs:find("BASH_LINENO", 1, true) or cs:find("caller", 1, true)) then
			return true
		end
	end
	return false
end
local function reads_debugstack(stmts)
	return any_node(stmts, function(st)
		if st.t == "simple" then
			-- a sourced file can read them out of sight: keep the frames for it; and a
			-- `declare -A NAME=(…)` names the running function in its conversion error
			local p1 = st.words and st.words[1] and st.words[1].parts[1]
			if p1 and (p1.lit == "source" or p1.lit == "." or p1.lit == "caller") then
				return true
			end
			if p1 and st.arrayargs and (p1.lit == "declare" or p1.lit == "typeset" or p1.lit == "local") then
				return true
			end
		end
		if st.parts ~= nil and st.t == nil then -- a word
			return word_reads_debugstack(st)
		end
		return st.k == "var" and DEBUGSTACK_VAR[st.name] ~= nil -- (an arith node: (( … )), x=$(( … )))
	end)
end

-- Does any word READ variable `name` (as $name or ${name…})? Gates per-command
-- maintenance of otherwise-free-to-skip specials ($_ last-arg, $PIPESTATUS).
local function reads_var(stmts, name)
	return any_node(stmts, function(n)
		return (n.parts ~= nil and n.t == nil and (function()
			for _, p in ipairs(n.parts) do
				if p.var == name or (p.pexp and p.pexp.name == name) then
					return true
				end
			end
			return false
		end)()) or (n.k == "var" and n.name == name)
	end)
end

-- Does the program install a `trap … SIG` for one of `sigs` (a set of names)? Used
-- to gate per-command trap hooks (ERR/DEBUG) so a trap-free script pays nothing.
-- Does the program install ANY trap? A forked `&`/pipeline-stage child resets caught
-- SIGNAL traps to default (bash); we compile those constructs only when the program
-- has no traps at all, so the child needs no signal machinery. Recurses broadly
-- (body/clauses/cmd/cmds/items) so a trap anywhere is seen.
local function scan_any_trap(stmts)
	return any_node(stmts, function(st)
		return st.t == "simple" and st.words and st.words[1] and st.words[1].parts[1]
			and st.words[1].parts[1].lit == "trap"
	end)
end

-- Does the program trap a REAL signal (or use a trap spec it can't read statically)?
-- Pseudo-signal traps (EXIT/ERR/DEBUG/RETURN) fire synchronously and are already scoped
-- per subshell/stage/$(…) by the runtime (in_subprogram/in_pipestage/calldepth), so they
-- don't stop those running in-process; a real signal can arrive asynchronously while an
-- in-process body runs on a copied state, so any such trap keeps them on the fork path.
local PSEUDO_SIG = { EXIT = 1, ["0"] = 1, ERR = 1, DEBUG = 1, RETURN = 1, SIGEXIT = 1 }
local function trap_cmd_sigs_pseudo(st)
	local words = {}
	for j = 2, #st.words do
		local w = st.words[j]
		local lit = ""
		for _, p in ipairs(w.parts or {}) do
			if p.lit == nil then
				return false -- a dynamic word: can't tell what it traps
			end
			lit = lit .. p.lit
		end
		words[#words + 1] = lit
	end
	local k = 1
	while words[k] and words[k]:match("^%-") and words[k] ~= "-" do
		if words[k] ~= "-p" and words[k] ~= "-l" and words[k] ~= "--" then
			return false
		end
		k = k + 1
	end
	local rest = {}
	for j = k, #words do
		rest[#rest + 1] = words[j]
	end
	-- `trap - SIG…` (reset to default) and `trap '' SIG…` (ignore) install no HANDLER — an
	-- ignored disposition is inherited by real subshells anyway — so only a real action on a
	-- real signal can deliver asynchronously into an in-process body.
	if #rest >= 2 and (rest[1] == "-" or rest[1] == "") then
		return true
	end
	-- `trap ACTION SIG…` (first word is the action) or `trap SIG` (reset); check every
	-- word that could be a signal spec
	local from = #rest >= 2 and 2 or 1
	for j = from, #rest do
		if not PSEUDO_SIG[rest[j]:upper()] then
			return false
		end
	end
	return true
end
local function scan_sigtrap(node)
	if type(node) ~= "table" then
		return false
	end
	if node.t == "simple" and node.words and node.words[1] and node.words[1].parts[1]
		and node.words[1].parts[1].lit == "trap" and not trap_cmd_sigs_pseudo(node)
	then
		return true
	end
	for _, v in pairs(node) do
		if type(v) == "table" and scan_sigtrap(v) then
			return true
		end
	end
	return false
end
-- Can the program turn on xtrace/verbose? (`set -x`/`-v` in any cluster, `set -o xtrace/
-- verbose`, or a non-literal `set` argument that might.)
local function scan_xtrace(node)
	if type(node) ~= "table" then
		return false
	end
	if node.t == "coproc" then -- a coproc is reaped asynchronously (bash's SIGCHLD); only the
		return true -- interpreter polls for it between commands (rt.coproc_poll)
	end
	if node.name == "FUNCNEST" or node.var == "FUNCNEST" then
		return true -- $FUNCNEST limits call depth: interp's run_function counts it
	end
	if node.lit == "extdebug" then
		return true -- extdebug: a DEBUG trap may skip commands (interp's run_debug handles it)
	end
	if node.lit == "history" or node.lit == "histexpand" or node.lit == "fc" then
		return true -- command history is recorded (and `!` expanded) by interp's line reader
	end
	if node.lit and node.lit:find("\\#", 1, true) then
		return true -- a prompt's \# (command number) counts interp's top-level commands
	end
	if node.lit and node.lit:find("BASH_COMMAND", 1, true) then
		return true -- $BASH_COMMAND (often read in a trap string) tracks interp's statements
	end
	if node.t == "simple" and node.words and node.words[1] and node.words[1].parts[1]
		and node.words[1].parts[1].lit == "set"
	then
		for j = 2, #node.words do
			local l = node.words[j].parts[1] and #node.words[j].parts == 1 and node.words[j].parts[1].lit
			-- (restricted mode too: its checks live only on the interpreter's paths)
			-- (set -k: interp re-reads NAME=value words anywhere as assignments)
			if not l or l == "xtrace" or l == "verbose" or l == "restricted" or l == "keyword"
				or (l:match("^%-%a+$") and l:find("[xvrkH]", 2)) then
				return true
			end
			-- a first non-option word (`set x $i`) or `--` makes the rest positional params
			if l == "--" or l == "-" or not l:match("^[-+]") then
				break
			end
		end
	end
	for _, v in pairs(node) do
		if type(v) == "table" and scan_xtrace(v) then
			return true
		end
	end
	return false
end
-- functrace (set -T / -o functrace) extends DEBUG into subshells, which compiled
-- fragments don't hook — keep those programs on the delegated path.
local function scan_functrace(node)
	if type(node) ~= "table" then
		return false
	end
	if node.t == "simple" and node.words and node.words[1] and node.words[1].parts[1]
		and node.words[1].parts[1].lit == "set"
	then
		for j = 2, #node.words do
			local l = node.words[j].parts[1] and node.words[j].parts[1].lit
			if not l or l == "functrace" or (l:match("^[-+]%a*$") and l:find("T", 1, true)) then
				return true
			end
		end
	end
	for _, v in pairs(node) do
		if type(v) == "table" and scan_functrace(v) then
			return true
		end
	end
	return false
end

local function scan_trap(stmts, sigs)
	return any_node(stmts, function(st)
		if st.t == "simple" and st.words and st.words[1] and st.words[1].parts[1]
			and st.words[1].parts[1].lit == "trap" then
			for j = 2, #st.words do
				local l = st.words[j].parts[1] and st.words[j].parts[1].lit
				if l and sigs[l] then
					return true
				end
			end
		end
		return false
	end)
end

-- Collect literal names targeted by `unset` (skipping -f/-v flags) anywhere in the
-- program. A function whose name is unset must dispatch through sh.functions so the
-- call AFTER the unset fails (127) — a hoisted fn_x would still be callable.
local function collect_unset(stmts, set)
	for _, st in ipairs(stmts or {}) do
		if st.t == "simple" and st.words[1] and st.words[1].parts[1] and st.words[1].parts[1].lit == "unset" then
			for j = 2, #st.words do
				local l = st.words[j].parts[1] and #st.words[j].parts == 1 and st.words[j].parts[1].lit
				if l and l:sub(1, 1) ~= "-" then
					set[l] = true
				end
			end
		end
		if st.body then
			collect_unset(st.body, set)
		end
		if st.cond then
			collect_unset(st.cond, set)
		end
		if st.clauses then
			for _, cl in ipairs(st.clauses) do
				if cl.body then
					collect_unset(cl.body, set)
				end
				if cl.cond then
					collect_unset(cl.cond, set)
				end
			end
		end
	end
end

-- Collect names defined by a NESTED funcdef (one not directly at the top level —
-- inside a function body, loop, if, or case). The compiled tier only hoists an fn_x
-- for top-level funcdefs; a nested def compiles to nothing and its call would resolve
-- as an external command (127). Delegating the def (interp registers it) and the calls
-- (interp dispatches) makes them work while the enclosing body stays compiled.
local function collect_nested_funcdefs(stmts, set, top)
	for _, st in ipairs(stmts or {}) do
		if st.t == "funcdef" then
			if not top then
				set[st.name] = true
			end
			if st.body then
				collect_nested_funcdefs(st.body, set, false)
			end
		else
			if st.body then
				collect_nested_funcdefs(st.body, set, false)
			end
			if st.cond then
				collect_nested_funcdefs(st.cond, set, false)
			end
			if st.clauses then
				for _, cl in ipairs(st.clauses) do
					if cl.body then
						collect_nested_funcdefs(cl.body, set, false)
					end
					if cl.cond then
						collect_nested_funcdefs(cl.cond, set, false)
					end
				end
			end
		end
	end
end

-- serialize a {int->int} pc map to a Lua table literal
local function serialize(t)
	local parts = {}
	for k, v in spairs(t) do
		parts[#parts + 1] = ("[%d]=%d"):format(k, v)
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

-- Serialize an arbitrary AST node (plain tables of strings/numbers/bools) to a
-- Lua literal, so a cold statement can be baked into the compiled source and run
-- by the shared interpreter (delegation). No cycles/functions in the AST.
-- (a loop's source span and its run-time tiering state: never part of the program)
local SER_SKIP = { _srcs = true, _s0 = true, _s1 = true, _h1 = true, _frag = true, _hits = true, _fid = true }
local function ser(v)
	local t = type(v)
	if t == "string" then
		return ("%q"):format(v)
	end
	if t == "number" then
		return tostring(v)
	end
	if t == "boolean" then
		return tostring(v)
	end
	if t ~= "table" then
		return "nil"
	end
	local parts, n = {}, #v
	for i = 1, n do
		parts[#parts + 1] = ser(v[i])
	end
	for k, val in spairs(v) do
		if (type(k) ~= "number" or k < 1 or k > n or k ~= math.floor(k)) and not SER_SKIP[k] then
			parts[#parts + 1] = ("[%s]=%s"):format(ser(k), ser(val))
		end
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

-- Arith with a side effect (assignment / ++ / --) can't sit in a Lua expression
-- position, so a word containing one must be run by the interpreter, not compiled.
-- Dynamic special vars whose VALUE the compiled tier doesn't reproduce (the CFG doesn't
-- track the current line or maintain $_ / the call stack): a read must delegate so the
-- interpreter computes it. (Defined here so xpand_fast can reject them; also gates word
-- reads below.)
local COMPILE_UNSAFE_VAR = {}
for _, n in ipairs({
	"_",
	"LINENO",
	"SECONDS",
	"FUNCNAME",
	"BASH_SOURCE",
	"BASH_LINENO",
	"BASH_COMMAND",
	"RANDOM",
	"SRANDOM",
}) do
	COMPILE_UNSAFE_VAR[n] = true
end
-- A deferred xpand whose raw uses ONLY $name/$digit expansions (no ${…}, $(…), `…`,
-- $*/$@/… specials, or a glued name$): the CFG CAN compile it — parse the raw as a
-- native tree, read each $name like a var, and guard non-lifted operands (see emit_value).
-- `${#name}` of a plain name inside $((…)) is always a number, so it reads natively: the
-- raw text is parsed with each replaced by a reserved identifier, which emit_value
-- renders as rt.var_len (other ${…} forms stay on the interpreter's textual path).
local function xpand_lens(raw)
	return (raw:gsub("%${#([%a_][%w_]*)}", "__curse_len_%1"))
end
local function xpand_fast(raw)
	if raw:find("}[%w_#%${]") or raw:find("[%w_]%${") then -- (text glued to a ${…}: textual)
		return false
	end
	raw = xpand_lens(raw)
	if
		require("runtime").xpand_self_assign(raw) -- (see interp's xpand)
		or raw:find("%$%(")
		or raw:find("\\", 1, true) -- (`\$x` is a literal `$`: the interp's textual path errors)
		or raw:find("`")
		or raw:find("%${")
		or raw:find("%$[^%w_]")
		or raw:find("[%w_]%$")
		or raw:find("}[%w_#]")
	then
		return false
	end
	-- a special whose value the CFG can't reproduce ($LINENO/$RANDOM/$_/…): delegate to interp
	for nm in raw:gmatch("%$([%a_][%w_]*)") do
		if COMPILE_UNSAFE_VAR[nm] then
			return false
		end
	end
	return true
end
-- Split a native arith tree's unique $name operands into NON-lifted (nl — need a
-- run-time numeric guard) and LIFTED (lf — i64 locals, always numeric). On the textual
-- fallback the lifted operands must be flushed to sh first, else the interpreter reads a
-- stale sh value (the authoritative value is the native local) — an infinite loop.
local function xpand_split(e, lifted, nl, lf, seen)
	if type(e) ~= "table" then
		return
	end
	if e.k == "var" and e.dollar and not e.idx and not seen[e.name] then
		seen[e.name] = true
		if lifted[e.name] then
			lf[#lf + 1] = e.name
		else
			nl[#nl + 1] = e.name
		end
	end
	xpand_split(e.e, lifted, nl, lf, seen)
	xpand_split(e.l, lifted, nl, lf, seen)
	xpand_split(e.r, lifted, nl, lf, seen)
	xpand_split(e.c, lifted, nl, lf, seen)
	xpand_split(e.a, lifted, nl, lf, seen)
	xpand_split(e.b, lifted, nl, lf, seen)
end
-- A READ of an array/assoc element in arith (`$(( a[i] ))`): a `var` node with a subscript
-- whose base is a plain name and whose RAW subscript has no cmdsub/procsub (its arith-vs-assoc
-- double path would run a subscript side effect twice). emit_value renders it via
-- rt.arith_read_elem (which contains the nounset/matherr edges). A subscripted WRITE
-- (asgn/post/pre) is NOT this — it stays delegated.
local function arith_elem_ok(e)
	-- gate on idxraw (the RAW subscript), not e.idx: a QUOTED subscript (`A['x']`) sets idxraw but
	-- leaves e.idx nil (its arith parse is skipped), yet it's still an element read rt.array_key
	-- resolves (assoc: dequoted word; indexed: arith_str(raw), which errors on a single quote).
	-- A `var` node is an element READ ($(( a[i] ))); an asgn/post/pre node is an element WRITE
	-- (`(( a[i] = … ))`, `(( a[i]++ ))`) — both carry name+idxraw and compile via rt.arith_elem_*.
	if type(e) ~= "table" or type(e.idxraw) ~= "string" then
		return false
	end
	if e.k ~= "var" and e.k ~= "asgn" and e.k ~= "post" and e.k ~= "pre" then
		return false
	end
	if type(e.name) ~= "string" or not e.name:match("^[%a_][%w_]*$") or COMPILE_UNSAFE_VAR[e.name] then
		return false
	end
	local ok, sw = pcall(require("parser").parse_word, e.idxraw)
	if not ok then
		return false
	end
	for _, p in ipairs(sw.parts) do
		if p.cmdsub or p.procsub then
			return false
		end
	end
	return true
end
local function arith_side_effect(e)
	if type(e) ~= "table" then
		return false
	end
	if e.k == "asgn" or e.k == "post" or e.k == "pre" then
		return true
	end
	-- xpandleaf (${…}), comma, and a NON-compilable array subscript aren't compiled natively —
	-- treat like a side effect so the word/stmt delegates. A FAST xpand ($name only) and a
	-- read-only array element (arith_elem_ok) ARE compiled, so they aren't side effects.
	if e.k == "xpandleaf" or (e.idxraw and not arith_elem_ok(e)) then
		return true
	end
	if e.k == "xpand" then
		return not xpand_fast(e.raw)
	end
	-- comma falls through: a pure `(a, b)` is side-effect-free (recurse into l/r); a
	-- side-effecting operand is detected by the recursion below.
	return arith_side_effect(e.e)
		or arith_side_effect(e.l)
		or arith_side_effect(e.r)
		or arith_side_effect(e.c)
		or arith_side_effect(e.a)
		or arith_side_effect(e.b)
end
-- Arith the CFG codegen cannot render at all (embedded $-expansion, comma, or
-- array-subscripted operands) — distinct from a mere side effect, which forc
-- init/step legitimately have. Such loops/statements delegate to the interpreter.
local function not_compilable(e)
	if type(e) ~= "table" then
		return false
	end
	-- arith_perr = a deferred arith PARSE error (`(( i = '3' ))`): only the interpreter
	-- renders it (prints bash's "syntax error in expression" + aborts the line), so the
	-- enclosing loop/statement must delegate — else emit_value throws an uncaught error.
	if e.k == "xpandleaf" or e.k == "arith_perr" or (e.idxraw and not arith_elem_ok(e)) then
		return true
	end -- comma recurses (emit_value / emit_arith_into render the sequence)
	if e.k == "xpand" then
		if not xpand_fast(e.raw) then
			return true
		end
		-- a fast xpand renders as a VALUE: one whose native tree assigns (`a[$k]=7`,
		-- `$x++`) can't, so the word delegates
		local ok, nat = pcall(require("parser").arith, xpand_lens(e.raw), true)
		return not ok or arith_side_effect(nat) or not_compilable(nat)
	end -- a fast $name xpand compiles
	return not_compilable(e.e)
		or not_compilable(e.l)
		or not_compilable(e.r)
		or not_compilable(e.c)
		or not_compilable(e.a)
		or not_compilable(e.b)
end
-- parser.arith() THROWS on a malformed expression — invalid octal `083`, a quoted
-- operand `'3'` — because only the parser's own `parith` wrapper turns that into an
-- arith_perr node. emit's ANALYSIS (emitable_word, collect_word, func_flags) parses
-- word arith eagerly and must not crash on it, so route every such parse through
-- this guard: a throw becomes an arith_perr leaf, which not_compilable rejects — the
-- word/statement then delegates to the interpreter, which reproduces bash's error.
local function safe_arith(s)
	local ok, a = pcall(require("parser").arith, s)
	if ok then
		return a
	end
	return { k = "arith_perr", raw = s }
end
-- An arith node renderable in VALUE position by emit_value (num/var/param/fast-$name/
-- un/bin/tern) — no side effect and nothing not_compilable rejects. Matches the pure-arith
-- word path (emitable_word via not_compilable), used to vet the OPERANDS of a side-effecting
-- word arith so nothing nested reaches emit_value's unsupported asgn/post/pre/comma cases.
local function arith_val_r(e)
	if type(e) ~= "table" then
		return false
	end
	local k = e.k
	if k == "num" or k == "param" or k == "raw" then
		return true
	end
	if k == "var" then
		return not e.idx and not e.idxraw and not COMPILE_UNSAFE_VAR[e.name]
	end
	if k == "xpand" then
		return xpand_fast(e.raw)
	end -- a fast $name xpand emit_value renders
	if k == "un" then
		return arith_val_r(e.e)
	end
	if k == "bin" then
		return arith_val_r(e.l) and arith_val_r(e.r)
	end
	if k == "tern" then
		return arith_val_r(e.c) and arith_val_r(e.a) and arith_val_r(e.b)
	end
	return false -- asgn/post/pre/comma/xpandleaf/matherr: side effect or non-renderable
end
-- A SIDE-EFFECTING word arith (`echo $((x++))`, `${x:=$((n+=1))}`) that emit_arith_into can
-- render into an IIFE: the side effect sits at the TOP level (a bare ++/--/assignment) with
-- value-position operands — bash evaluates the whole $((…)) once, so one IIFE reproduces it.
-- A side effect nested in an operand (`$(( (x++) + 1 ))`), an array subscript, or a dynamic
-- special ($LINENO/…) is rejected -> the word keeps delegating.
local function arith_word_ok(e)
	if type(e) ~= "table" then
		return false
	end
	local k = e.k
	if k == "asgn" then
		return not e.idx and not e.idxraw and not COMPILE_UNSAFE_VAR[e.name] and arith_val_r(e.e)
	end
	if k == "post" or k == "pre" then
		return not e.idx and not e.idxraw and not COMPILE_UNSAFE_VAR[e.name]
	end
	return arith_val_r(e) -- a value with a nested side effect fails here (operands must be pure)
end
-- Does a subshell body statically run `set`? A fork-compiled subshell body is a
-- straight-line sub-CFG; it can't honor an errexit toggle (`set -e`) that turns
-- on partway through, whereas the interpreter checks errexit per command. So a
-- body that runs `set` is delegated WHOLE to the interpreter (still inside a
-- fork), matching interp exactly. (Errexit INHERITED at entry is handled
-- separately by the runtime `sh.opt_e` guard in the subshell branch.)
local function stmt_runs_set(st)
	local t = st.t
	if t == "simple" then
		local w1 = st.words[1]
		return (w1 and w1.parts[1] and w1.parts[1].lit) == "set"
	elseif t == "background" then
		return stmt_runs_set(st.cmd)
	elseif t == "pipeline" then
		for _, c in ipairs(st.cmds) do
			if stmt_runs_set(c) then
				return true
			end
		end
	elseif t == "andor" then
		for _, it in ipairs(st.items) do
			if stmt_runs_set(it.cmd) then
				return true
			end
		end
	elseif t == "if" or t == "case" then
		for _, cl in ipairs(st.clauses) do
			for _, s in ipairs(cl.body) do
				if stmt_runs_set(s) then
					return true
				end
			end
		end
	elseif st.body then
		for _, s in ipairs(st.body) do
			if stmt_runs_set(s) then
				return true
			end
		end
	end
	return false
end
local function body_runs_set(list)
	for _, st in ipairs(list) do
		if stmt_runs_set(st) then
			return true
		end
	end
	return false
end
-- errexit (`set -e`): after a failing command the shell exits — but only for the
-- statement kinds bash applies it to (a compound's INNER commands fire it; &&/||
-- have their own final-operand rule handled by the delegated interp; conditions
-- run with sh.noerr set, which we honor). In the compiled CFG a native command is
-- never a condition (those are arith or delegate the whole construct), so the same
-- kinds the interpreter checks (see interp errexit_stmt) get this guard. `noerr`
-- is maintained by the interpreter around delegated conditions, so a compiled
-- function called AS a condition (interp sets noerr, then calls the compiled fn)
-- correctly does NOT fire. Off the errexit path (`sh.opt_e` false) it's one branch.
local ERREXIT_TYPES = { simple = 1, pipeline = 1, arithcmd = 1, assign = 1, assignlist = 1, subshell = 1, dbracket = 1 }
local ERRCHK = "if sh.opt_e and sh.noerr == 0 and sh.status ~= 0 then error({ __curse_exit = sh.status }) end"
EF.has_err = false -- program installs an ERR trap → fire it after a failing command
local emit_toplevel = false -- current build_cfg is the top level (ERR only fires there; a
-- compiled function body doesn't track calldepth so it would wrongly fire ERR — bash needs
-- errtrace for that. Subshell bodies live in the top-level CFG but fire_err_trap's runtime
-- in_subprogram check keeps ERR from firing in the forked child.)
local emit_neg_ctx = false -- building a `!`-inverted command's fragment: its own errexit is exempt
-- (bash), but a called function's internal errexit still fires (fn_x, built separately)
local function errchk(st) -- the guard statement for `st`, or "" when errexit never applies
	if emit_neg_ctx then
		return ""
	end -- direct command of a `!`-inverted pipeline: errexit-exempt
	if not (st and ERREXIT_TYPES[st.t] and not st.negate) then
		return ""
	end
	-- Inside a compiled subshell body, an errexit failure exits the SUBSHELL (rt.subshell_exit —
	-- _exit with the status, like the body's normal boundary), NOT the whole shell: raising
	-- __curse_exit would unwind to the parent's finish_run and wrongly run the shell's EXIT trap
	-- in the forked child. noerr (raised for a condition subshell) suppresses it, as always.
	local exitfail = EF.subshell_exit_pc and "rt.subshell_exit(sh.status, sh)" or "error({ __curse_exit = sh.status })"
	if EF.has_err then -- ERR trap fires on the same condition as errexit; set $LINENO to this
		-- command's line, fire ERR (fire_err_trap scopes by calldepth/in_subprogram — inside a
		-- function/subshell only under errtrace), THEN errexit (bash order).
		return ("if sh.noerr == 0 and sh.status ~= 0 then sh.cur_line = %d; I.fire_err_trap(sh); if sh.opt_e then %s end end"):format(
			st.line or 0,
			exitfail
		)
	end
	if EF.subshell_exit_pc then
		return ("if sh.opt_e and sh.noerr == 0 and sh.status ~= 0 then %s end"):format(exitfail)
	end
	return ERRCHK
end
EF.has_debug = false -- program installs a DEBUG trap → fire it before each command
EF.funcstack = false -- program reads $FUNCNAME → maintain sh.funcstack around calls
EF.pipestatus = false -- program reads $PIPESTATUS → set it (=(status)) after each simple cmd
EF.has_trap = false -- program installs any trap → a forked `&`/pipeline child must reset caught signal traps
local emit_redir_funcs = {} -- funcs with a definition redirect (`f(){…} >&2`): delegate them + their calls
local emit_multidef = {} -- names defined by more than one top-level funcdef: a single hoisted
-- fn_x can't represent the sequential redefinition (a call between two defs must see the FIRST
-- body, but the last `fn_x = function…` wins at load), so both the defs and the calls delegate
-- to interp, which registers each def into sh.functions in program order and dispatches live.
-- The DEBUG-trap prefix for a natively-compiled command (else ""). DEBUG fires BEFORE
-- the command with $LINENO = its line. Top-level only (a compiled function body would
-- wrongly fire without functrace — bash fires DEBUG once at the CALL site, which is a
-- top-level command). Delegated commands fire DEBUG via interp's exec_stmt, so this is
-- prepended ONLY to native blocks (exactly one fires).
local function dbg(st)
	-- run_debug scopes by calldepth/in_subprogram (fires inside a function/subshell only
	-- under functrace); calldepth is tracked in fnwrap when a DEBUG trap is present.
	if EF.has_debug then
		return ("I.run_debug(sh, %d); "):format(st.line or 0)
	end
	return ""
end
-- Wrap a compiled function call `s` (function `cmd`, called at source `line`) with
-- call-stack maintenance ($FUNCNAME/BASH_* when read) and, when an ERR/DEBUG trap is
-- present, calldepth tracking — so fire_err_trap/run_debug scope those traps to the
-- function (they fire inside a function only under errtrace/functrace). Zero cost when
-- neither applies. (Inline is disabled when a trap is present, so all calls come here.)
local function fnwrap(cmd, line, s)
	local pre, post = "", ""
	if EF.funcstack then
		pre = ("sh:enterFunc(%q, %d); "):format(cmd, line or 0)
		post = "; sh:leaveFunc()"
	end
	if EF.has_err or EF.has_debug then
		pre = pre .. "sh.calldepth = sh.calldepth + 1; "
		post = post .. "; sh.calldepth = sh.calldepth - 1"
	end
	if EF.has_debug or EF.has_err then -- the callee doesn't inherit DEBUG/ERR (rt.debug_enter)
		pre = pre .. ("local __dbg = rt.debug_enter(sh, %q); "):format(cmd)
		post = post .. "; rt.debug_leave(sh, __dbg)"
	end
	return pre .. s .. post
end
-- Special params emit_word knows how to render (`$-` is the option string, via
-- sh:dash_flags); any OTHER `$special` must delegate, or emit_word would render it
-- empty. A ${#…} LENGTH of one of these still delegates (see emitable_word).
local RENDERABLE_SPECIAL = { ["#"] = 1, ["@"] = 1, ["*"] = 1, ["?"] = 1, ["$"] = 1, ["!"] = 1, ["-"] = 1 }
-- A word emit_word can render (no ${..op..} pexp, no side-effecting arith, no
-- unhandled special param).
-- An empty brace alternative (`{X,,Y,}`) parses to a ZERO-PART word. bash removes it
-- from argv entirely (an unquoted null), and the interpreter yields zero fields for
-- it; the compiled argv builders must skip it too (else they emit a stray "" arg). A
-- quoted empty `""` is ONE part with q=true — a real empty field, never elided.
local function empty_word(w)
	return #w.parts == 0
end
local pexp_compilable, pexp_scalar, emit_pattern_glob, subscript_word -- fwd decl (defined after COMPILE_UNSAFE_VAR)
local function emitable_word(w)
	for _, p in ipairs(w.parts) do
		-- In a program that declares a nameref, a `${ref…}` OPERATOR read (default,
		-- length, subscript, …) may resolve THROUGH the nameref to an array/assoc
		-- ELEMENT — which the native pexp renderers do not deref. Keep those delegating.
		-- A plain scalar read (`$ref`/`${ref}`/`"$ref"`/`foo$ref` — all p.var) compiles:
		-- it renders via rt.nameref_read, which reproduces the interp's element-deref.
		if EF.has_nameref and p.pexp then
			return false
		end
		if p.pexp and not pexp_compilable(p.pexp, p.q) then
			return false
		end
		if p.procsub then
			return false
		end -- <(cmd)/>(cmd): needs the interp's temp-file setup
		if p.special and not RENDERABLE_SPECIAL[p.special] then
			return false
		end
		if p.special and p.lenof then
			return false
		end -- ${#-}/${#?}: LENGTH of a special's value — the scalar renderers emit the value, so delegate
		-- pure value arith renders via emit_value; a side-effecting one (x++/x=…/x+=…) via
		-- emit_arith_into in an IIFE, provided the side effect is top-level (arith_word_ok).
		if p.arith then
			local a = safe_arith(p.arith)
			if not_compilable(a) or (arith_side_effect(a) and not arith_word_ok(a)) then
				return false
			end
		end
		if p.arithast and arith_side_effect(p.arithast) and not arith_word_ok(p.arithast) then
			return false
		end -- inlined arith
	end
	return true
end
-- A word that a compiled command can use directly: emit_word-able AND with no
-- unquoted expansion (would word-split) or unquoted glob char (would path-expand)
-- — those need the interpreter's field engine, so the command is delegated.
local function word_safe(w)
	if not emitable_word(w) then
		return false
	end -- pexp / side-effecting arith
	for _, p in ipairs(w.parts) do
		if p.special == "@" or p.special == "*" then
			return false
		end -- multi-element (even quoted)
		if not p.q then
			if p.var or p.param or p.special or p.cmdsub or p.pexp then
				return false
			end -- unquoted -> splits
			if p.lit and (p.lit:find("[*?%[]") or p.lit:find("[@!+?*]%(")) then
				return false
			end -- unquoted glob / extglob
		end
	end
	return true
end

-- How a NON-lifted arith var read is emitted. Default `sh:aget` parses the value's
-- immediate number (fast, used by whilec/forc/arith-word conditions). Inside a
-- (( )) command the arithcmd codegen swaps in rt.arith_read, which matches interp
-- exactly (nounset + recursive-name-eval + array decay); codegen is synchronous, so
-- this scoped toggle needs no threading through emit_value's recursion.
local arith_varread = "sh:aget(%q)"

-- The whole word as one literal string when every part is literal — sees through a
-- \-escaped name (`\return` parses as parts "r".."eturn"). nil if any part expands.
local function full_lit(w)
	local s = {}
	for _, p in ipairs(w.parts) do
		if p.lit == nil then
			return nil
		end
		s[#s + 1] = p.lit
	end
	return table.concat(s)
end
-- Like full_lit, but only when every part is an UNQUOTED literal (so a quoted `'~'`
-- is excluded) — used to decide tilde expansion, which never touches quoted text.
local function unq_full_lit(w)
	for _, p in ipairs(w.parts) do
		if p.lit == nil or p.q then
			return nil
		end
	end
	return full_lit(w)
end
-- Recognize a control-flow command (break/continue/return) even when written with a
-- \-escaped name or a `builtin`/`command` prefix (`\return`, `builtin return 3`).
-- Returns op, argoffset (index of the first argument), or nil.
local function resolve_cf(st)
	if st.t ~= "simple" or not st.words[1] or st.redirs then
		return nil
	end
	local off = 1
	local c = full_lit(st.words[off])
	while (c == "builtin" or c == "command") and st.words[off + 1] do -- strip nested builtin/command prefixes
		off = off + 1
		c = full_lit(st.words[off])
	end
	if c == "break" or c == "continue" or c == "return" or c == "exit" then
		return c, off + 1
	end
	return nil
end

-- Does this statement list contain a break/continue the CFG can't place as a static
-- jump — a non-literal level (`break $x`), extra args (`continue 1 2 3`), or (in a
-- loop CONDITION) any break/continue at all (loopstack isn't active while the cond is
-- flattened)? Such a loop delegates whole to the interpreter (else the delegated
-- break/continue is lost and the compiled loop spins forever). Descends into if/group
-- but not nested loops/functions/subshells (their break/continue are their own).
local function hard_cf(stmts, in_cond)
	for _, st in ipairs(stmts or {}) do
		local op, argoff = resolve_cf(st)
		if op == "break" or op == "continue" then
			if in_cond then
				return true
			end
			local lvlw = st.words[argoff]
			if
				lvlw
				and (
					not (function()
						local wl = full_lit(lvlw)
						return wl and wl:match("^%d+$")
					end)() or st.words[argoff + 1]
				)
			then
				return true
			end
		end
		if st.t == "if" then
			for _, cl in ipairs(st.clauses) do
				if hard_cf(cl.body, in_cond) then
					return true
				end
			end
		elseif st.t == "group" then
			if hard_cf(st.body, in_cond) then
				return true
			end
		end
	end
	return false
end

-- Command-substitution fragment compilation (emit_word's `$(…)` path). A literal
-- `$(cmd)` inner is KNOWN at this compile time, so it is COMPILED into an inline
-- fragment closure (cs_N) sharing this module's fn_x/upvals — never interpreted.
-- Forward-declared here (build_cfg/assemble are defined far below); emit_frags
-- collects the assembled fragments, emit_frag_ctx carries the analysis context, and
-- emit_frag_n is the id counter. All reset per M.emit.
local build_cfg, assemble, emit_word
local emit_frags, emit_frag_ctx, emit_frag_n

local emit_value, emit_arith_into, etxt_args, arith_binop
-- the error-text args for rt.idiv/imod/ipow (bash's evalerror expression + token), with
-- the enclosing command's name baked in (`((: `) since compiled code keeps no context
etxt_args = function(e)
	if not (e and e.etxt) then
		return ""
	end
	return (", %q, %q"):format((EF.acmd and (EF.acmd .. ": ") or "") .. e.etxt, e.etok or "")
end
emit_value = function(e, lifted)
	local k = e.k
	if k == "num" then
		if e.v:match("^%d+$") and (e.v == "0" or e.v:sub(1, 1) ~= "0") then
			return e.v .. "LL"
		end
		return ("rt.arith_num(%q)"):format(e.v) -- 0x.. / 010 octal / N#.. bases
	end
	if k == "raw" then
		return e.code
	end -- a pre-computed Lua expr (inlined param binding)
	if k == "comma" then -- (a, b): evaluate a for its effect, then b is the value (bash sequence op)
		return ("(function() local _ = %s; return %s end)()"):format(emit_value(e.l, lifted), emit_value(e.r, lifted))
	end
	if k == "var" and e.name == "LINENO" then
		return (tostring(EF.cur_line or 0) .. "LL")
	end -- compile-time line
	if k == "var" and e.idxraw then -- $(( a[i] )): array/assoc element read (gated by arith_elem_ok)
		return ("rt.arith_read_elem(sh, %q, %q, %s)"):format(
			e.name,
			e.idxraw,
			subscript_word(e.idxraw, lifted)
		)
	end
	if k == "var" then
		local ln = e.name:match("^__curse_len_(.+)$") -- (a ${#name}: see xpand_lens)
		if ln then
			return ("rt.var_len(sh, %q)"):format(ln)
		end
		return lifted[e.name] and lname(e.name) or (arith_varread):format(e.name)
	end
	if k == "param" then
		return ("rt.str_to_i64(sh:param(%d))"):format(e.n)
	end
	if k == "xpand" then
		-- $name/$digit arithmetic: bash substitutes each value's TEXT and re-parses, which
		-- agrees with reading the operand natively WHEN the value is a plain number (a number
		-- binds like an atom). Lifted operands are i64 locals — always numeric — so a hot
		-- `(( $i < n ))` compiles to pure native code. A NON-lifted $name is guarded: if its
		-- value isn't numeric, bash re-associates operators, so fall back to the interpreter's
		-- textual substitution (rt.arith_textual). Only reached for a fast xpand (not_compilable).
		local ok, native = pcall(require("parser").arith, xpand_lens(e.raw), true)
		if not ok then
			return ("rt.arith_textual(sh, %q)"):format(e.raw)
		end
		local nl, lf = {}, {}
		xpand_split(native, lifted, nl, lf, {})
		local nat = emit_value(native, lifted)
		if #nl == 0 then
			return nat
		end -- every $-operand is a lifted i64: pure native
		local conds = {}
		for _, nm in ipairs(nl) do
			conds[#conds + 1] = ("rt.arith_isnum(sh,%q)"):format(nm)
		end
		local fb -- fallback: flush any lifted operands to sh, then bash's textual substitution
		if #lf == 0 then
			fb = ("rt.arith_textual(sh,%q)"):format(e.raw)
		else
			local syncs = {}
			for _, nm in ipairs(lf) do
				syncs[#syncs + 1] = ("sh:aset(%q,%s)"):format(nm, lname(nm))
			end
			fb = ("(function() %s; return rt.arith_textual(sh,%q) end)()"):format(table.concat(syncs, "; "), e.raw)
		end
		return ("((%s) and (%s) or %s)"):format(table.concat(conds, " and "), nat, fb)
	end
	if k == "un" then
		if e.op == "-" then
			return "(-(" .. emit_value(e.e, lifted) .. "))"
		end
		if e.op == "!" then
			return "((" .. emit_value(e.e, lifted) .. ") == 0LL and 1LL or 0LL)"
		end
		if e.op == "~" then
			return "bit.bnot(" .. emit_value(e.e, lifted) .. ")"
		end
	end
	if k == "tern" then
		return ("((( %s ) ~= 0LL) and ( %s ) or ( %s ))"):format(
			emit_value(e.c, lifted),
			emit_value(e.a, lifted),
			emit_value(e.b, lifted)
		)
	end
	if k == "bin" then
		local l, r = emit_value(e.l, lifted), emit_value(e.r, lifted)
		local op = e.op
		if op == "+" or op == "-" or op == "*" then
			return "(" .. l .. " " .. op .. " " .. r .. ")"
		end
		if op == "/" then
			return ("rt.idiv(%s, %s%s)"):format(l, r, etxt_args(e))
		end -- fatal on /0
		if op == "%" then
			return ("rt.imod(%s, %s%s)"):format(l, r, etxt_args(e))
		end
		if CMP[op] then
			return "((" .. l .. " " .. CMP[op] .. " " .. r .. ") and 1LL or 0LL)"
		end
		if op == "&&" then
			return "(((" .. l .. ") ~= 0LL and (" .. r .. ") ~= 0LL) and 1LL or 0LL)"
		end
		if op == "||" then
			return "(((" .. l .. ") ~= 0LL or (" .. r .. ") ~= 0LL) and 1LL or 0LL)"
		end
		if op == "&" then
			return ("bit.band(%s, %s)"):format(l, r)
		end
		if op == "|" then
			return ("bit.bor(%s, %s)"):format(l, r)
		end
		if op == "^" then
			return ("bit.bxor(%s, %s)"):format(l, r)
		end
		if op == "<<" then
			return ("bit.lshift(%s, tonumber(%s) %% 64)"):format(l, r)
		end
		if op == ">>" then
			return ("bit.arshift(%s, tonumber(%s) %% 64)"):format(l, r)
		end
		if op == "**" then
			return ("rt.ipow(%s, %s%s)"):format(l, r, etxt_args(e))
		end
	end
	error("emit: value position not supported for node " .. tostring(k))
end

local function emit_bool(e, lifted)
	if e.k == "bin" and CMP[e.op] then
		return "(" .. emit_value(e.l, lifted) .. " " .. CMP[e.op] .. " " .. emit_value(e.r, lifted) .. ")"
	end
	return "((" .. emit_value(e, lifted) .. ") ~= 0LL)"
end

local function emit_set(name, valexpr, lifted)
	if lifted[name] then
		return lname(name) .. " = " .. valexpr
	end
	return ("sh:aset(%q, %s)"):format(name, valexpr)
end

local function emit_arith_stmt(e, lifted)
	if e.k == "comma" then -- `for (( i=0, j=5; …; i++, j-- ))`: run each operand for its effect
		return emit_arith_stmt(e.l, lifted) .. "; " .. emit_arith_stmt(e.r, lifted)
	end
	if e.k == "asgn" then
		local v = emit_value(e.e, lifted)
		if e.op == "=" then
			return emit_set(e.name, v, lifted)
		end
		local cur = lifted[e.name] and lname(e.name) or ("sh:aget(%q)"):format(e.name)
		-- (`x /= 0` must fault like bash, `<<=` is a shift: the shared op renderer)
		return emit_set(e.name, arith_binop(e.op:sub(1, -2), cur, "(" .. v .. ")", e), lifted)
	end
	if e.k == "post" or e.k == "pre" then
		local cur = lifted[e.name] and lname(e.name) or ("sh:aget(%q)"):format(e.name)
		return emit_set(e.name, ("(%s + %dLL)"):format(cur, e.d), lifted)
	end
	-- element write (`a[i]=…`) or a pure value in statement position (e.g. a comma operand):
	-- run it for its effect via emit_arith_into with a throwaway destination.
	return ("do local __d; %s end"):format(emit_arith_into("__d", e, lifted))
end

-- ---- recursive-value arith: native compile of a var's VALUE re-evaluated as arith ----
-- `x="1+2"; $((x))` reads x, then re-parses+evaluates its VALUE "1+2" as arithmetic
-- (interp: arith_read -> arith_resolve -> eval). That recursive evaluation was the
-- rt.arith_read -> interp.arith_read seam. Here we COMPILE the value's AST to native
-- Lua ops instead, for the WORD-ENGINE-FREE subset only: no $-expansion (xpand — its
-- textual substitution is dynamic) and no array subscript (arith_key can run cmdsub —
-- the bugs.test.sh `a[$(…)]=1` case). Anything outside the subset returns nil, so
-- rt.arith_read keeps the interp bootstrap for it (compile-eventually, never a NEW seam).
local function arith_native_ok(e)
	if type(e) ~= "table" then
		return false
	end
	local k = e.k
	if k == "num" or k == "param" then
		return true
	end
	if k == "var" then
		return not e.idx and not e.idxraw
	end -- scalar only (subscript -> arith_key)
	if k == "un" then
		return arith_native_ok(e.e)
	end
	if k == "bin" then
		return arith_native_ok(e.l) and arith_native_ok(e.r)
	end
	if k == "tern" then
		return arith_native_ok(e.c) and arith_native_ok(e.a) and arith_native_ok(e.b)
	end
	if k == "comma" then
		return arith_native_ok(e.l) and arith_native_ok(e.r)
	end
	return false -- asgn/post/pre (nounset + lifted-var write subtleties), xpand/xpandleaf/
	-- matherr/raw (dynamic or subscript): keep the interp bootstrap (identical to HEAD).
end
-- Render an arithmetic binary op (same op->expr mapping as emit_value's `bin`); shared
-- by emit_avalue's bin node and its compound-assignment (`x <<= y`).
arith_binop = function(op, l, r, node)
	if op == "+" or op == "-" or op == "*" then
		return "(" .. l .. " " .. op .. " " .. r .. ")"
	end
	if op == "/" then
		return ("rt.idiv(%s, %s%s)"):format(l, r, etxt_args(node))
	end
	if op == "%" then
		return ("rt.imod(%s, %s%s)"):format(l, r, etxt_args(node))
	end
	if op == "&" then
		return ("bit.band(%s, %s)"):format(l, r)
	end
	if op == "|" then
		return ("bit.bor(%s, %s)"):format(l, r)
	end
	if op == "^" then
		return ("bit.bxor(%s, %s)"):format(l, r)
	end
	if op == "<<" then
		return ("bit.lshift(%s, tonumber(%s) %% 64)"):format(l, r)
	end
	if op == ">>" then
		return ("bit.arshift(%s, tonumber(%s) %% 64)"):format(l, r)
	end
	if op == "**" then
		return ("rt.ipow(%s, %s%s)"):format(l, r, etxt_args(node))
	end
	error("arith_binop: unsupported " .. tostring(op))
end
-- Render one arith node to a value-returning Lua expression. Like emit_value but with
-- the side-effecting nodes (asgn/post/pre/comma) as value expressions/IIFEs, and every
-- var read recurses through rt.arith_read (a value may itself hold an expression). lifted
-- is always {} (a standalone value string), so no i64 locals — assign returns via sh:aset.
local emit_avalue
emit_avalue = function(e)
	local k = e.k
	if k == "num" then
		if e.v:match("^%d+$") and (e.v == "0" or e.v:sub(1, 1) ~= "0") then
			return e.v .. "LL"
		end
		return ("rt.arith_num(%q)"):format(e.v) -- 0x.. / 010 / N#.. bases
	end
	if k == "var" then
		return ("rt.arith_read(sh, %q)"):format(e.name)
	end -- recursive (reentrancy-guarded)
	if k == "param" then
		return ("rt.str_to_i64(sh:param(%d))"):format(e.n)
	end
	if k == "un" then
		local v = emit_avalue(e.e)
		if e.op == "-" then
			return "(-(" .. v .. "))"
		end
		if e.op == "!" then
			return "((" .. v .. ") == 0LL and 1LL or 0LL)"
		end
		if e.op == "~" then
			return "bit.bnot(" .. v .. ")"
		end
	end
	if k == "tern" then
		return ("((( %s ) ~= 0LL) and ( %s ) or ( %s ))"):format(emit_avalue(e.c), emit_avalue(e.a), emit_avalue(e.b))
	end
	if k == "comma" then
		return ("(function() local _ = %s; return %s end)()"):format(emit_avalue(e.l), emit_avalue(e.r))
	end
	if k == "bin" then
		local op = e.op
		if op == "&&" then
			return ("(((%s) ~= 0LL and (%s) ~= 0LL) and 1LL or 0LL)"):format(emit_avalue(e.l), emit_avalue(e.r))
		end
		if op == "||" then
			return ("(((%s) ~= 0LL or (%s) ~= 0LL) and 1LL or 0LL)"):format(emit_avalue(e.l), emit_avalue(e.r))
		end
		local l, r = emit_avalue(e.l), emit_avalue(e.r)
		if CMP[op] then
			return "((" .. l .. " " .. CMP[op] .. " " .. r .. ") and 1LL or 0LL)"
		end
		return arith_binop(op, l, r, e)
	end
	-- asgn/post/pre are gated out by arith_native_ok (their nounset + lifted-var write
	-- semantics stay on the interp bootstrap), so they never reach here.
	error("emit_avalue: unsupported arith node " .. tostring(k))
end
-- Compile a var's VALUE string to `function(sh) return <int64> end`, or nil if the value
-- isn't a parseable in-subset arith expression (caller keeps the interp bootstrap). The
-- returned fn reads only sh + rt + bit (same preamble as M.emit's module header).
function M.compile_arith_value(s)
	local ok, ast = pcall(require("parser").arith, s) -- deferred form, exactly as arith_resolve
	if not ok or not arith_native_ok(ast) then
		return nil
	end
	local ok2, expr = pcall(emit_avalue, ast)
	if not ok2 then
		return nil
	end
	local f = load(
		'local rt = require("runtime"); local bit = require("bit"); return function(sh) return ' .. expr .. " end",
		"=curse:arith"
	)
	return f and f() or nil
end

-- Compile a literal `$(cmd)` / backtick inner (KNOWN at this compile time) into an
-- inline fragment closure cs_N and return the Lua expr that runs it capturing
-- stdout. The fragment reads `sh` directly (lift set {}), so lifted operands are
-- flushed to sh first. It runs in a FORKED child (correct capture for builtins AND
-- externals). Falls back to sh:capture_src only for a genuine syntax error or the
-- `$(< file)` special-read (whose runtime semantics live there).
-- Compile `stmts` into an inline fragment closure cs_N (reads sh directly, lift set
-- {}) and return its id, or nil if the body hits a compiler gap. Shared by $(…),
-- background, and pipeline stages — the compiled tier's "run this subprogram" unit.
local collect_names, analyze_lift -- forward: defined with the lift analysis below
-- An INLINABLE function's vars don't count as function-touched (its calls are spliced
-- in), so they may be run()-locals; a call that ISN'T spliced (field-split arguments)
-- runs fn_x, which works on sh — so hand it those locals and take back what it changed.
local function inl_sync(cmd, call, cx)
	local body = EF.inlinefns and EF.inlinefns[cmd]
	if not body or not EF.runlocal_set or not (cx and cx.toplevel) then
		return call -- (only run() holds run-locals; a function body reads sh)
	end
	local names = {}
	collect_names(body, names)
	local pre, post = {}, {}
	for n in spairs(names) do
		if EF.runlocal_set[n] then
			pre[#pre + 1] = ("sh:aset(%q, %s); "):format(n, lname(n))
			post[#post + 1] = ("; %s = sh:aget(%q)"):format(lname(n), n)
		end
	end
	return table.concat(pre) .. call .. table.concat(post)
end
local function emit_fragment(stmts, neg, liftset, cfraise)
	local saved_tl, saved_neg, saved_line = emit_toplevel, emit_neg_ctx, EF.cur_line
	-- `cfraise` ({loop=, func=}): the fragment is the BODY of a compound run in the current
	-- shell (a redirected `{ …; } >f` / `for … done <f`), so a break/continue with no loop
	-- of its own, or a return, must reach the CALLER's loop/function: raise the signal for
	-- the caller's delegate cf-wrapper. Scoped to this fragment only (a fragment nested in
	-- it — a subshell, a pipeline stage — resets it).
	local saved_cf, saved_cff = EF.cf_raise, EF.cf_flush
	EF.cf_raise = cfraise
	-- `ownlocals`: run-local lifted vars the body uses, held as REGISTER locals of the
	-- fragment function (seeded from sh on entry, flushed on exit — like run()), so a hot
	-- loop inside it stays native instead of going through sh. A raised break/continue/
	-- return leaves the function early, so it flushes them first (EF.cf_flush).
	EF.cf_flush = nil
	-- every fragment: the run-local lifted vars its statements touch (callers flush those
	-- to sh before running any fragment, and reload after one that runs in the shell).
	local ownlocals = {}
	if EF.runlocal_set and next(EF.runlocal_set) then
		local seen = {} -- run-local lifted vars the body references
		collect_names(stmts, seen)
		for n in pairs(seen) do
			if EF.runlocal_set[n] and not (liftset and liftset[n]) then
				ownlocals[#ownlocals + 1] = n
			end
		end
	end
	-- vars assigned ONLY inside this fragment (not lifted program-wide) that are safe to hold
	-- natively here: numerically assigned within it, and cleared program-wide (frag_lift_ok)
	if EF.frag_lift_ok then
		local have = {}
		for _, n in ipairs(ownlocals) do
			have[n] = true
		end
		for n in pairs((analyze_lift({ stmts = stmts }))) do
			if not have[n] and not (liftset and liftset[n]) and not (EF.runlocal_set and EF.runlocal_set[n])
				and not (EF.lifted_set and EF.lifted_set[n]) and EF.frag_lift_ok(n)
			then
				ownlocals[#ownlocals + 1] = n
			end
		end
	end
	table.sort(ownlocals)
	if #ownlocals > 0 then
		local ls, fl = {}, {}
		for k in pairs(liftset or {}) do
			ls[k] = true
		end
		for _, n in ipairs(ownlocals) do
			ls[n] = true
			fl[#fl + 1] = ("sh:aset(%q, %s); "):format(n, lname(n))
		end
		liftset = ls
		EF.cf_flush = table.concat(fl)
	end
	if neg then
		emit_neg_ctx = true
	end -- `! cmd`: exempt its own errexit (see errchk)
	-- a `!`-inverted command must NOT inline a called function (its body keeps its own
	-- errexit, checked in fn_x — which is built separately, unaffected by emit_neg_ctx).
	local inlfns = neg and {} or emit_frag_ctx.inlinefns
	-- `liftset` (in-process subshell only): compile the fragment WITH the program's lift
	-- set so it reads/writes the SAME native-int64 upvalues as the module's functions —
	-- otherwise the fragment (sh.vars) and a called function (v_x upvalue) desync. The
	-- caller does the swap-save/restore of those upvalues for isolation. Other fragments
	-- ($(…)/pipeline/background) pass nil: they keep every var in sh (forked children own
	-- their copy; a lifted local would neither see nor sync the caller's real sh var).
	local bok, cfg = pcall(build_cfg, stmts, liftset or {}, emit_frag_ctx.funcflags, inlfns, false)
	emit_toplevel, emit_neg_ctx, EF.cur_line = saved_tl, saved_neg, saved_line
	EF.cf_raise, EF.cf_flush = saved_cf, saved_cff
	if not bok then
		return nil
	end
	emit_frag_n = emit_frag_n + 1
	emit_frags[#emit_frags + 1] = assemble(cfg, ("cs_%d = function(sh)"):format(emit_frag_n), { runlocals = ownlocals })
	return emit_frag_n
end

-- "flush lifted operands to sh; " prefix so a fragment (which reads sh) sees current
-- values of the enclosing scope's native-int64 locals. "" when nothing is lifted.
local function lifted_flush(lifted)
	local f = {}
	for n in spairs(lifted) do
		f[#f + 1] = ("sh:aset(%q, %s)"):format(n, lname(n))
	end
	return #f > 0 and (table.concat(f, "; ") .. "; ") or ""
end

-- Command substitutions that never mutate escaping shell state (no var assignment,
-- cd, set/shopt, unset, trap, read, exec, function def, …) can run IN-PROCESS
-- (capture_inproc) instead of forking a whole warm-worker child — forking the fat
-- LuaJIT heap is the dominant cost of $(…)-heavy scripts. Safe iff the program has
-- no eval/source (else a literal name could be a runtime mutating function) AND every
-- body statement is a simple command whose literal name is a KNOWN-PURE builtin or a
-- plain EXTERNAL (a separate process — cannot touch the parent shell). Anything else
-- (a non-pure builtin, a function, a dynamic/compound/assigning body) keeps forking.
-- Missing a builtin from the pure set only costs a fork (never correctness).
-- The rt.names_static guard expression for a set of command names: this module's
-- compiled functions must still be registered as themselves; any other name must not
-- have become a function.
local function names_guard(list)
	local ff = (emit_frag_ctx and emit_frag_ctx.funcflags) or {}
	local plain, fn, fv = {}, {}, {}
	for _, c in ipairs(list) do
		if ff[c] then
			fn[#fn + 1] = ("%q"):format(c)
			fv[#fv + 1] = fnlname(c)
		else
			plain[#plain + 1] = ("%q"):format(c)
		end
	end
	if #fn == 0 then
		return ("rt.names_static(sh, {%s})"):format(table.concat(plain, ", "))
	end
	return ("rt.names_static(sh, {%s}, {%s}, {%s})"):format(
		table.concat(plain, ", "),
		table.concat(fn, ", "),
		table.concat(fv, ", ")
	)
end
-- The literal command names a body runs (every simple command, at any depth) — what
-- rt.names_static re-checks at runtime in an eval/source program. nil if none needed.
local function dyn_guard(stmts)
	if not EF.has_dyncode then
		return nil
	end
	local names, seen = {}, {}
	local function walk(node)
		if type(node) ~= "table" then
			return
		end
		if node.t == "simple" and node.words and node.words[1] then
			local w1 = node.words[1]
			local c = w1.parts and #w1.parts == 1 and w1.parts[1].lit
			if c and not seen[c] then
				seen[c] = true
				names[#names + 1] = c
			end
		end
		for _, v in pairs(node) do
			if type(v) == "table" then
				walk(v)
			end
		end
	end
	walk(stmts)
	table.sort(names)
	return names_guard(names)
end
local PURE_BUILTIN_CMDSUB = { echo = 1, printf = 1, ["true"] = 1, ["false"] = 1,
	[":"] = 1, pwd = 1, test = 1, ["["] = 1, exit = 1 }
local function cmdsub_nofork_ok(stmts)
	if #stmts == 0 then return false end
	local BUILTINS = require("interp").BUILTINS
	local ff = (emit_frag_ctx and emit_frag_ctx.funcflags) or {}
	for _, st in ipairs(stmts) do
		if st.t ~= "simple" then return false end
		if st.assigns then return false end -- prefix env / assignment prefix mutates
		-- a redirect (`echo x 1>&2`) must reach the real fds: only the isolated fd-level capture
		-- path sends a builtin's redirected output where it belongs
		if st.redirs then return false end
		local w1 = st.words and st.words[1]
		local c = w1 and w1.parts[1] and #w1.parts == 1 and w1.parts[1].lit
		if not c then return false end -- no/dynamic command word (or assignment-only line)
		if ff[c] then return false end -- a shell function may mutate the parent shell
		if not (PURE_BUILTIN_CMDSUB[c] or not BUILTINS[c]) then return false end -- a non-pure builtin
		if c == "printf" then
			for j = 2, #st.words do
				local p1 = st.words[j].parts[1]
				if p1 and p1.lit == "-v" then return false end -- printf -v NAME writes a variable
			end
		end
	end
	return true
end

-- Fork-forcing per-subshell specials: their value/identity differs in a real child,
-- so a subshell that READS one must genuinely fork (see runtime subshell_run).
local SUBSHELL_FORK_VARS = { BASHPID = 1, BASH_SUBSHELL = 1, RANDOM = 1, SRANDOM = 1 }
-- Builtins that force a real fork — a subshell/`$()` that runs one, directly or in a callee
-- (via the unsafe-fn fixpoint), can't run in-process. Two reasons: (1) they mutate
-- PROCESS-GLOBAL state a fork isolates for free but subshell_run does NOT checkpoint — `exec`
-- (fds/process image), `ulimit` (rlimits), `enable`/`disable` (the builtin table), `set` (the
-- shell -o options; `body_runs_set` only catches a DIRECT `set`, so this also covers one
-- reached through a function). (2) `eval`/`source`/`.` run UNPROVABLE dynamic code — the
-- reachable set is unknowable, and the in-process capture can't reproduce a forked child's fd
-- view (e.g. a builtin's `2>&1` error output), so fork them (per-command, so it's caught even
-- inside a function body, unlike the program-wide has_dyncode gate).
-- (3) `wait`: a subshell/stage can't wait for the PARENT's jobs (not its children), but
-- in-process they ARE this process's children — it would block on them. (Its own `&` jobs
-- already force a fork.)
local SUBSHELL_FORK_BUILTINS = {
	exec = 1, ulimit = 1, enable = 1, disable = 1, eval = 1, source = 1, ["."] = 1,
	wait = 1,
	trap = 1, -- trap tables (and a real signal's disposition) aren't checkpointed
}
local function word_forces_fork(w)
	if not w or not w.parts then return false end
	for _, p in ipairs(w.parts) do
		if p.var and SUBSHELL_FORK_VARS[p.var] then return true end
		if p.name and SUBSHELL_FORK_VARS[p.name] then return true end
		if p.arith and (p.arith:find("BASHPID", 1, true) or p.arith:find("BASH_SUBSHELL", 1, true)
			or p.arith:find("RANDOM", 1, true)) then return true end
	end
	return false
end
local function words_force_fork(ws)
	if not ws then return false end
	for _, w in ipairs(ws) do if w and word_forces_fork(w) then return true end end
	return false
end
-- Can a subshell body run IN-PROCESS (checkpoint/restore) rather than fork? Only when
-- nothing in it needs a REAL child process: no `exec`, no background `&`, no funcdef,
-- no dynamic command word (could resolve to exec/an unsafe function), no read of a
-- per-subshell special, and no call to a SUBSHELL-UNSAFE function (`unsafe` — those that
-- transitively exec/&/read-a-special; M.emit's call-graph fixpoint computes it). A SAFE
-- function call runs in-process: its shell-var mutations land in subshell_run's var-copy
-- and its native-int64 (lifted) mutations are swap-saved/restored by the caller, so state
-- has full parity. `set` is gated by the caller (body_runs_set); traps by program-wide EF.
-- Nested subshells and $(…) are their OWN scope — opaque here (each self-gates).
local subshell_stmt_inproc_ok
local function subshell_list_inproc_ok(list, unsafe)
	unsafe = unsafe or EF.sub_unsafe_fn or {}
	for _, st in ipairs(list or {}) do -- (nil: an if's final `else` clause has no cond)
		if not subshell_stmt_inproc_ok(st, unsafe) then return false end
	end
	return true
end
function subshell_stmt_inproc_ok(st, unsafe)
	local t = st.t
	-- EF.late_gate: the LATE-FORK gate (in-process subshell / $(…), not a pipeline stage) —
	-- anything that needs a real process forks at runtime right there (rt.need_process),
	-- so eval/source, exec/ulimit/trap/wait, `&`, dynamic words and any function are fine.
	if t == "funcdef" then return false end
	if t == "background" then return EF.late_gate and subshell_stmt_inproc_ok(st.cmd, unsafe) or false end
	if t == "subshell" then return true end -- its own scope; self-gates
	if t == "simple" then
		local w1 = st.words and st.words[1]
		local c = w1 and w1.parts[1] and #w1.parts == 1 and w1.parts[1].lit
		if not c and not EF.late_gate then return false end -- dynamic word: could be exec / an unsafe fn
		if c and not EF.late_gate then
			if SUBSHELL_FORK_BUILTINS[c] then return false end -- process-global mutator (exec/ulimit/…)
			if unsafe[c] then return false end -- call to a subshell-unsafe user function
		end
		if words_force_fork(st.words) then return false end
		if st.assigns then
			for _, a in ipairs(st.assigns) do if a.rhs and word_forces_fork(a.rhs) then return false end end
		end
		return true
	elseif t == "assign" then
		return not (st.rhs and word_forces_fork(st.rhs))
	elseif t == "assignlist" or t == "arrayassign" then
		return not words_force_fork(st.words)
	elseif t == "pipeline" then
		return subshell_list_inproc_ok(st.cmds, unsafe)
	elseif t == "andor" then
		for _, it in ipairs(st.items) do if not subshell_stmt_inproc_ok(it.cmd, unsafe) then return false end end
		return true
	elseif t == "if" then
		for _, cl in ipairs(st.clauses) do
			if not subshell_list_inproc_ok(cl.cond, unsafe) then return false end
			if not subshell_list_inproc_ok(cl.body, unsafe) then return false end
		end
		return true
	elseif t == "case" then
		if word_forces_fork(st.subject) then return false end
		for _, cl in ipairs(st.clauses) do
			if not subshell_list_inproc_ok(cl.body, unsafe) then return false end
		end
		return true
	elseif t == "whilec" then
		return subshell_list_inproc_ok(st.cond, unsafe) and subshell_list_inproc_ok(st.body, unsafe)
	elseif t == "forin" then
		return not words_force_fork(st.words) and subshell_list_inproc_ok(st.body, unsafe)
	elseif t == "forc" then
		return subshell_list_inproc_ok(st.body, unsafe)
	elseif t == "group" then
		return subshell_list_inproc_ok(st.body, unsafe)
	elseif t == "arithcmd" or t == "dbracket" then
		return true -- test/arith: no exec/funccall (a special there only affects isolated state)
	end
	return false -- unknown type: fork to be safe
end
EF.subshell_inproc_ok = function() return true end -- XXX in-process always: gate retired
EF.subshell_late_ok = function() return true end
-- How the interpreter should reach a compiled function: through __upv_wrap when the
-- module has lifted upvalues (see M.emit), else the closure itself.
EF.upv_wrapped = function(fname)
	return (EF.lifted_names and #EF.lifted_names > 0) and ("__upv_wrap(" .. fname .. ")") or fname
end
local compile_cmdsub_inner
local func_locals
-- (compiling the body moves the compile-time line: put it back for the enclosing command)
local function compile_cmdsub(...)
	local l, cl, ln, cil = EF.cur_line, EF.cur_cline, EF.cur_loopn, EF.cs_in_loop
	local cif, cia, inf = EF.cs_in_func, EF.cs_active, EF.cur_infunc
	-- (a `$( … )` inside a loop knows it: a break/continue in its body ends the substitution;
	-- inside a function, a `return` there ends it — at the top level that's an error)
	EF.cs_in_loop = (EF.cur_loopn or 0) > 0 or cil
	EF.cs_in_func = EF.cur_infunc or cif
	EF.cs_active = true
	local r = { compile_cmdsub_inner(...) }
	EF.cur_line, EF.cur_cline, EF.cur_loopn, EF.cs_in_loop = l, cl, ln, cil
	EF.cs_in_func, EF.cs_active, EF.cur_infunc = cif, cia, inf
	return unpack(r)
end
function compile_cmdsub_inner(src, backtick, lifted, aenv, noalias, posix)
	local fallback = ("sh:capture_src(%q%s)"):format(src, noalias and ", " .. tostring(backtick or false) .. ", true"
		or (backtick and ", true" or ""))
	local pok, ast = pcall(require("parser").parse, src, nil, aenv, noalias, posix, EF.cur_cline or EF.cur_line)
	if not pok or type(ast) ~= "table" or ast.stmts == nil then
		return fallback
	end -- syntax error
	-- A syntax error inside $(…) is fatal to the containing command (bash, status 2);
	-- capture_src reproduces that exactly, so route any parse_error body there.
	for _, st in ipairs(ast.stmts) do
		if st.t == "parse_error" then
			return fallback
		end
	end
	if #ast.stmts == 1 then -- $(< file): read the file's contents (a special, not a command)
		local st = ast.stmts[1]
		if
			st.t == "simple"
			and (not st.words or #st.words == 0)
			and st.redirs
			and #st.redirs == 1
			and st.redirs[1].op == "in"
		then
			-- compile the path word and read the file directly — no interp
			local wok, pw = pcall(require("parser").parse_word, st.redirs[1].src or st.redirs[1].target or "")
			for _, p in ipairs(wok and pw.parts or {}) do -- (a glob in the file word: interp)
				if p.lit and not p.q and p.lit:find("[*?[]") then
					wok = false
				end
			end
			if wok then
				local eok, pathexpr = pcall(emit_word, pw, lifted)
				if eok then
					return ("sh:capture_file(%s)"):format(pathexpr)
				end
			end
			return fallback
		end
	end
	-- Three tiers: a PURE body runs in-process with no checkpoint (cheapest); a MUTATING but
	-- fork-free-safe body (same gate as an in-process subshell) runs isolated in-process
	-- (checkpoint/restore + the __iso_cmdsub upvalue swap, no fork); anything else forks a
	-- real child. The isolated fragment lifts the same upvalues as functions (EF.lifted_set)
	-- so a called function and the body share `v_x`; __iso_cmdsub swap-saves them.
	local bt = backtick and "true" or "false"
	local strict = EF.subshell_inproc_ok(ast.stmts)
	local isolated = not cmdsub_nofork_ok(ast.stmts)
		and not EF.inproc_trap_block
		and #ast.stmts > 0
		and (strict or EF.subshell_late_ok(ast.stmts))
	local id = emit_fragment(ast.stmts, nil, isolated and EF.lifted_set or nil)
	if not id then
		return fallback
	end -- compiler gap (curse-nocompile): to be closed upstream
	local call
	local forked = ("sh:capture_compiled(cs_%d, true, %s)"):format(id, bt)
	if isolated then
		call = (EF.lifted_names and #EF.lifted_names > 0)
				and ("__iso_cmdsub(sh, cs_%d, %s)"):format(id, bt)
			or ("sh:capture_compiled_iso(cs_%d, %s)"):format(id, bt)
	elseif cmdsub_nofork_ok(ast.stmts) then
		call = ("sh:capture_compiled(cs_%d, false, %s)"):format(id, bt)
	else
		call = forked
	end
	-- eval/source program: in-process only while the body's names are still the static ones;
	-- a body relying on late fork can't take it inside a pipeline stage
	local guard = call ~= forked and dyn_guard(ast.stmts)
	if isolated and not strict then
		guard = "not rt.in_stage()"
	elseif guard then
		guard = "(not rt.in_stage() or " .. guard .. ")"
	end
	if guard then
		call = ("(%s and %s or %s)"):format(guard, call, forked)
	end
	local flush = lifted_flush(lifted)
	if flush ~= "" then
		return ("(function() %s return %s end)()"):format(flush, call)
	end
	return call
end

-- Render an arith node `a` (from a `$((…))`/inlined word) to a Lua string EXPRESSION.
-- A pure value is emit_value inline; a side-effecting one (vetted by arith_word_ok) runs
-- emit_arith_into in an IIFE so the ++/--/assignment fires exactly once, then stringifies
-- the result. Assumes arith_varread is already set to the recursive $(()) reader by the caller.
local function emit_arith_word(a, lifted)
	if arith_side_effect(a) then
		return "(function() local __v; " .. emit_arith_into("__v", a, lifted) .. "; return rt.i64_to_str(__v) end)()"
	end
	return "rt.i64_to_str(" .. emit_value(a, lifted) .. ")"
end

emit_word = function(w, lifted)
	local parts = {}
	for i, p in ipairs(w.parts) do
		if
			i == 1
			and p.lit
			and not p.q
			and (p.lit:sub(1, 1) == "~" or (p.lit:find("~", 1, true) and p.lit:match("^[%a_][%w_]*%+?=") ~= nil))
		then
			-- word-initial unquoted literal tilde (~, ~/…, ~user, ~+/~-) OR a NAME=…~ word
			-- (`echo x=~`, which bash tilde-expands like an assignment): expanded at runtime
			-- ($HOME/getpwnam/$PWD, each `:`-segment after NAME=). Only a genuine LITERAL ~
			-- triggers — a tilde from a variable's value never expands (bash), and this part
			-- is a literal, so no over-expansion. ~ mid-word (not after NAME=) stays literal.
			parts[#parts + 1] = ("rt.tilde_word_initial(sh, %q, %s, %s)"):format(
				p.lit, tostring(#w.parts > 1), w.plainarg and "sh.opt_posix" or "false")
		elseif p.lit then
			parts[#parts + 1] = ("%q"):format(p.lit)
		elseif p.raw then
			parts[#parts + 1] = p.raw -- pre-computed Lua string expr (inlined param)
		elseif p.var == "LINENO" then -- $LINENO: the current source line, a compile-time constant
			parts[#parts + 1] = ("%q"):format(tostring(EF.cur_line or 0))
		elseif p.var then
			parts[#parts + 1] = EF.has_nameref and ("rt.nameref_read(sh, %q)"):format(p.var)
				or lifted[p.var] and ("rt.i64_to_str(%s)"):format(lname(p.var))
				or ("sh:get_u(%q)"):format(p.var)
		elseif p.param then
			parts[#parts + 1] = ("sh:param_u(%d, %s)"):format(p.param, tostring(p.braced or false))
		elseif p.special then
			if p.special == "#" then
				parts[#parts + 1] = "tostring(sh.nparams)"
			elseif p.special == "@" then
				parts[#parts + 1] = 'sh:paramsJoin(" ")'
			elseif p.special == "*" then
				parts[#parts + 1] = "sh:paramsStar()" -- "$*": IFS[0]-joined
			elseif p.special == "?" then
				parts[#parts + 1] = "tostring(sh.status)"
			elseif p.special == "$" then
				parts[#parts + 1] = "tostring(sh:pid())"
			elseif p.special == "!" then
				parts[#parts + 1] = ("rt.last_bg_u(sh, %s)"):format(tostring(p.braced or false))
			elseif p.special == "-" then
				parts[#parts + 1] = "sh:dash_flags()" -- $-: the current single-char option flags
			end
		elseif p.arithast then -- a pre-parsed+substituted arith AST (inlined word)
			local saved = arith_varread
			arith_varread = "rt.arith_read(sh, %q)" -- $(()) reads recursively (bar=foo;$((bar)))
			parts[#parts + 1] = emit_arith_word(p.arithast, lifted)
			arith_varread = saved
		elseif p.arith then
			local saved = arith_varread
			arith_varread = "rt.arith_read(sh, %q)" -- name/expr values re-parse as arith
			parts[#parts + 1] = emit_arith_word(safe_arith(p.arith), lifted)
			arith_varread = saved
		elseif p.cmdsub then -- $( … ): COMPILE the inner (known at compile time) and run it captured
			parts[#parts + 1] = compile_cmdsub(p.cmdsub, p.backtick, lifted, p.aenv, p.noalias, p.posix)
		elseif p.pexp then
			if not pexp_compilable(p.pexp, p.q) then
				error("curse-nocompile: ${..} operator")
			end -- interp handles it
			parts[#parts + 1] = pexp_scalar(p.pexp, lifted)
		end
	end
	if #parts == 0 then
		return '""'
	end
	return "(" .. table.concat(parts, " .. ") .. ")"
end

-- $_ suffix: after a simple command, $_ = its LAST argument (bash). Only when the
-- program reads $_ and the last word is a single field (word_safe — re-evaluating it
-- is side-effect-free; a split/cmdsub last arg is left alone). Empty string for no words.
local function und(st, lifted)
	if not st.words then
		return ""
	end -- $_ is maintained after every command (bash), like exec_simple's path
	local last = st.words[#st.words]
	if last and not word_safe(last) then
		return ""
	end -- split/cmdsub last arg: skip (rare)
	-- A word_safe last arg can still hold a SIDE-EFFECTING expansion (a quoted `"$(cmd)"`, a
	-- $((n++)), a procsub): re-emitting it here to set $_ would run it a SECOND time. Skip $_
	-- for those (rare) rather than double the side effect — the command already ran it once.
	if last then
		for _, p in ipairs(last.parts) do
			if p.cmdsub or p.procsub or p.arith or p.arithast then
				return ""
			end
			-- (likewise a subscript with a side effect: ${d[c++]}, ${d[$((c++))]})
			local ix = p.pexp and p.pexp.index
			if ix and (ix:find("[$`]") or ix:find("++", 1, true) or ix:find("--", 1, true) or ix:find("=", 1, true)) then
				return ""
			end
		end
	end
	local v = last and emit_word(last, lifted) or '""'
	return ("; sh:set_str(%q, %s)"):format("_", v)
end

-- The field engine (genuine compilation). A word that isn't word_safe still
-- compiles when it is a SINGLE unquoted source that split+glob can process at
-- runtime on a natively-computed value: either EVERY part is an unquoted expansion
-- (the whole concatenation word-splits then globs — `$x`, `$x$y`, `$(cmd)`), or the
-- word is an all-literal unquoted glob (no split — a literal is never word-split —
-- just glob: `*.txt`). Returns {expr, split} for rt.field_split, else nil. Mixed
-- literal+expansion (`dir/$x*`) needs the per-char quote mask → interp (delegate).
-- (COMPILE_UNSAFE_VAR is defined earlier, near xpand_fast, so it can gate xpand too.)
-- Same, but for a value read as an ARITH var node (`for (( i < LINENO ))`, `(( RANDOM ))`):
-- the CFG can't reproduce it, so a forc/whilec arith touching one must delegate to interp.
local function arith_reads_unsafe(e)
	if type(e) ~= "table" then
		return false
	end
	if e.k == "var" and COMPILE_UNSAFE_VAR[e.name] then
		return true
	end
	return arith_reads_unsafe(e.e)
		or arith_reads_unsafe(e.l)
		or arith_reads_unsafe(e.r)
		or arith_reads_unsafe(e.c)
		or arith_reads_unsafe(e.a)
		or arith_reads_unsafe(e.b)
end

-- A [[ ]] operand word the compiled tier can render to its exact value: emit_word-able
-- and free of a dynamic special var whose value the CFG doesn't reproduce ($LINENO/$_…).
local function db_word_ok(w)
	if not emitable_word(w) then
		return false
	end
	for _, p in ipairs(w.parts) do
		if p.var and (COMPILE_UNSAFE_VAR[p.var] and p.var ~= "LINENO") then
			return false
		end
	end
	return true
end
-- Compile a [[ ]] expression tree to a native Lua boolean expression (and/or/not
-- short-circuit natively; leaves computed via emit_word + a runtime/interp PRIMITIVE
-- on the values). Returns the expr, or nil when any leaf can't compile (the caller
-- delegates the whole [[ ]]). No word splitting happens in [[ ]], so emit_word (a
-- scalar concat) is exactly the operand value.
local ARITH_CMP = { ["-eq"] = "==", ["-ne"] = "~=", ["-lt"] = "<", ["-le"] = "<=", ["-gt"] = ">", ["-ge"] = ">=" }
local emit_dbracket_node
-- A [[ ]] with an arithmetic comparison: an operand's arith error makes the whole test
-- false (status 1, bash) — rt.db_arith flags it, rt.db_ok reads the flag (no pcall).
local function emit_dbracket(node, lifted)
	local code = emit_dbracket_node(node, lifted)
	if code and code:find("rt.db_arith(", 1, true) then
		return "rt.db_ok(sh, " .. code .. ")"
	end
	return code
end
emit_dbracket_node = function(node, lifted)
	local k = node.kind
	if k == "and" or k == "or" then
		local a = emit_dbracket_node(node.l, lifted)
		if not a then
			return nil
		end
		local b = emit_dbracket_node(node.r, lifted)
		if not b then
			return nil
		end
		return "(" .. a .. (k == "and" and " and " or " or ") .. b .. ")"
	elseif k == "not" then
		local e = emit_dbracket_node(node.e, lifted)
		if not e then
			return nil
		end
		return "(not " .. e .. ")"
	elseif k == "str" then -- [[ $x ]] : true when non-empty
		if not db_word_ok(node.word) then
			return nil
		end
		return "(" .. emit_word(node.word, lifted) .. ' ~= "")'
	elseif k == "unary" then
		if not db_word_ok(node.word) then
			return nil
		end
		local op, val = node.op, emit_word(node.word, lifted)
		if op == "-z" then
			return "(" .. val .. ' == "")'
		end
		if op == "-n" then
			return "(" .. val .. ' ~= "")'
		end
		-- -v (variable/element set): the operand is already word-expanded, so its subscript is
		-- a literal -> rt.var_is_set is native. -o (shell option) still needs SETOPT/opt_on ->
		-- interp seam. Every other unary is a file predicate -> the pure-FFI runtime primitive.
		if op == "-v" then
			return ("rt.var_is_set(sh, %s, true)"):format(val)
		end
		if op == "-o" then
			return ("I.dbracket_unary(sh, %q, %s)"):format(op, val)
		end
		return ("rt.file_test(%q, %s)"):format(op, val)
	elseif k == "binary" then
		if not db_word_ok(node.l) or not db_word_ok(node.r) then
			return nil
		end
		local op, l = node.op, emit_word(node.l, lifted)
		if op == "=~" then
			return nil
		end -- BASH_REMATCH side effect + status-2 -> interp
		if op == "==" or op == "=" or op == "!=" then
			if not node.rq then
				-- an unquoted RHS is a glob; a MIXED-quoted RHS (`a\?b`, `a"*"b`) needs a mask-aware
				-- render — plain emit_word loses which metachars are quoted (literal) vs active. Render
				-- it with emit_pattern_glob_word (quoted metachar -> escaped) and glob-match.
				local mixed = false
				for _, p in ipairs(node.r.parts) do
					if p.q then
						mixed = true
						break
					end
				end
				if mixed then
					local g = EF.emit_pattern_glob_word(node.r, lifted)
					if not g then
						return nil
					end
					local m = ("rt.glob_match(%s, %s, (sh.shopt.nocasematch and true or nil))"):format(l, g)
					return op == "!=" and ("(not " .. m .. ")") or m
				end
			end
			local eq = ("rt.dbracket_eq(sh, %s, %s, %s)"):format(
				l,
				emit_word(node.r, lifted),
				node.rq and "true" or "false"
			)
			return op == "!=" and ("(not " .. eq .. ")") or eq
		elseif ARITH_CMP[op] then
			return ("(rt.db_arith(sh, %s) %s rt.db_arith(sh, %s))"):format(
				l,
				ARITH_CMP[op],
				emit_word(node.r, lifted)
			)
		elseif op == "<" then
			return ("rt.coll_lt(%s, %s)"):format(l, emit_word(node.r, lifted))
		elseif op == ">" then
			return ("rt.coll_lt(%s, %s)"):format(emit_word(node.r, lifted), l)
		elseif op == "-nt" or op == "-ot" or op == "-ef" then
			return ("rt.file_bincmp(%q, %s, %s)"):format(op, l, emit_word(node.r, lifted))
		end
	end
	return nil
end

-- Parameter-expansion OPERATORS whose per-value transform is a runtime PRIMITIVE
-- (Shell:apply_str_op) applied to natively-computed operands: pattern strip
-- (#/##/%/%%), glob substitute (/,//), and case-fold (^/^^/,/,,). The op is known
-- at compile time; the value and (literal) pattern are the operands.
local PEXP_STROP = {
	["#"] = 1,
	["##"] = 1,
	["%"] = 1,
	["%%"] = 1,
	["/"] = 1,
	["//"] = 1,
	["^"] = 1,
	["^^"] = 1,
	[","] = 1,
	[",,"] = 1,
}
-- ${x@OP} transforms compiled natively (bash 5.x): Q/K/k shell-quote, U/u/L case-fold,
-- E ANSI-unescape (via apply_str_op on the scalar value), and `a` the attribute letters
-- (via sh:attr_string, special-cased in pexp_scalar). @P (prompt) and @A (declare repr)
-- still need interp's expand_param, so they delegate.
local PEXP_AT = { Q = 1, K = 1, k = 1, U = 1, u = 1, L = 1, E = 1, a = 1 }
-- Default/alternate ops. Quoted -> pexp_scalar; unquoted scalar -> field_word renders the
-- pexp value and the outer field_split splits it (the default word's own quoting is gated
-- out of the compilable set, so scalar-value + split == bash's field-wise default).
local PEXP_DEFAULT = { [":-"] = 1, ["-"] = 1, [":+"] = 1, ["+"] = 1, [":="] = 1, ["="] = 1, [":?"] = 1, ["?"] = 1 }
-- The default/alternate ops valid on an ARRAY/positional [@]/[*] (bash: := / = / :? / ? are
-- not — `${a[@]:=x}` errors). These yield the value list or the default field-list.
local ARRAY_DEFAULT = { [":-"] = 1, ["-"] = 1, [":+"] = 1, ["+"] = 1 }
-- A pexp ARG is compile-time constant when it is plain literal glob text: no
-- expansion ($ ` ~), no quote char (a quoted metachar is literal — different glob
-- semantics), and no backslash (escapes a glob char, or is a literal in a
-- replacement). Anything with those needs interp's word expansion, so it delegates.
local function pexp_literal_arg(a)
	return a == nil or not a:find("[%$`~\\\"']")
end
-- A strip/subst/case PATTERN safe to pass VERBATIM to apply_str_op, whose glob_to_ere treats a
-- backslash escape \c as a literal c — exactly like interp. Allows a backslash (the escape), but
-- excludes $ ` (expansion), ~ (bash tilde-expands a pattern), and ' " (a quoted metachar must
-- match literally — that needs the mask-aware emit_pattern_glob, not a verbatim pass).
local function pat_verbatim_ok(a)
	return a == nil or not a:find("[%$`~\"']")
end
-- The op's word arg(s) (a slice off/len, or a default word) are compilable when each is an
-- emit_word-able word free of ~ \ ' " (so emit_word == interp's expand_word and the arith
-- eval / field-split runs on the identical expanded string). Shared by the scalar
-- (pexp_compilable) and array (array_multi_op) slice + default gates.
local function pexp_word_args_ok(pe)
	local function wok(a)
		if a == nil then
			return true
		end
		if a:find("[~\\'\"]") then
			return false
		end
		if a:find("%$[@*]") or a:find("%${[@*]") or a:find("%[[@*]%]") then
			return false -- a multi-word operand ($@, $*, ${a[@]}): interp keeps its fields
		end
		if a:find("%[[^%]]*[$`]") then
			return false -- an expansion INSIDE a subscript (`A[$k]`): its value is quoted the
			-- arithmetic way (interp's arith_expand_text), not re-expanded after emit_word
		end
		local ok, w = pcall(require("parser").parse_word, a)
		return ok and emitable_word(w) or false
	end
	return wok(pe.arg) and wok(pe.arg2)
end
-- A strip/subst/case op's PATTERN compiles: a plain literal (fast), or a dynamic/quoted
-- pattern emit_pattern_glob renders mask-aware — but not a ~ (bash tilde-expands the pattern)
-- or a backslash (escape subtleties). The subst REPLACEMENT (arg2) stays literal: a dynamic
-- replacement's `&`/`\&` matched-text semantics differ from a plain value's. Shared by the
-- scalar and array-element strop gates.
local function strop_pat_ok(pe)
	if pat_verbatim_ok(pe.arg) and pexp_literal_arg(pe.arg2) then
		return true -- literal pattern (incl. \* \? \/ glob-escapes) passed verbatim to apply_str_op
	end
	if pe.arg and pe.arg:find("[~\\]") then
		return false
	end
	return emit_pattern_glob(pe.arg or "", {}) ~= nil and pexp_literal_arg(pe.arg2)
end
function pexp_compilable(pe, quoted)
	if pe.via_indirect then
		return false
	end -- ${!ref} indirection (its own path)
	if pe.index then
		if type(pe.name) ~= "string" or not pe.name:match("^[%a_][%w_]*$") or COMPILE_UNSAFE_VAR[pe.name] then
			return false
		end
		local op = pe.op
		-- ${#a[@]} / ${#a[*]}: the array element COUNT (a scalar number via sh:array_count).
		if pe.index == "@" or pe.index == "*" then
			return op == "len"
		end
		-- ${a[sub]…}: a scalar element (rt.array_elem). The subscript must render with no cmdsub/
		-- procsub — its indexed-arith vs assoc-word double path would run a subscript side effect twice.
		local ok, sw = pcall(require("parser").parse_word, pe.index)
		if not (ok and emitable_word(sw)) then
			return false
		end
		for _, p in ipairs(sw.parts) do
			if p.cmdsub or p.procsub then
				return false
			end
		end
		-- READ-ONLY ops on the element VALUE compile: bare read, length, slice, and the
		-- strip/subst/case pattern ops. @-transform/indices/prefix/indirect keep their own paths.
		if op == nil or op == "len" then
			return true
		end
		if op == "@" then
			return PEXP_AT[pe.arg] and true or false
		end -- ${a[i]@Q}/@U/… (not @a/@A/@P)
		if op == "sub" then
			return pexp_word_args_ok(pe)
		end
		if PEXP_STROP[op] then
			return strop_pat_ok(pe)
		end
		-- default/alternate/assign/error (${a[i]:-d} / := / ? …): Shell:expand_param does the
		-- element set-ness test and := write-back, so reuse it — same default-word gate as scalars.
		if PEXP_DEFAULT[op] then
			if pe.arg and pe.arg:find("[~\\'\"]") then
				return false
			end
			local wok, w = pcall(require("parser").parse_word, pe.arg or "")
			return wok and emitable_word(w) or false
		end
		return false
	end
	local name = pe.name
	if type(name) ~= "string" or not name:match("^[%a_][%w_]*$") or COMPILE_UNSAFE_VAR[name] then
		return false
	end
	if pe.op == "len" then
		return true
	end -- ${#x}: scalar codepoint length via apply_str_op("len")
	if pe.op == "@" then
		return PEXP_AT[pe.arg] and true or false
	end -- ${x@Q}/@U/@L/@E … (not @P/@a)
	if PEXP_DEFAULT[pe.op] then
		-- default/alternate/assign/error: compile when the default word is emit_word-able. The
		-- default is lazy (Lua short-circuit). A QUOTED ${x:-word} default follows double-quoted
		-- rules — parse_default_quoted renders its ~ \ ' " exactly as interp's pw does — so admit
		-- those chars there. An UNQUOTED default with ~ \ ' " would field-split differently, so
		-- keep delegating it (quoted false, or a conservative caller that passes no context).
		local P = require("parser")
		if not quoted and pe.arg and pe.arg:find("[~\\'\"]") then
			return false
		end
		-- an unquoted multi-word default ($@, $*, ${a[@]}) keeps its own fields (interp)
		if not quoted and pe.arg and (pe.arg:find("%$[@*]") or pe.arg:find("%${[@*]") or pe.arg:find("%[[@*]%]")) then
			return false
		end
		local ok, w = pcall(quoted and P.parse_default_quoted or P.parse_word, pe.arg or "", pe.hd)
		return ok and emitable_word(w) or false
	end
	if pe.op == "sub" then
		return pexp_word_args_ok(pe)
	end -- ${v:off:len} scalar substring
	if PEXP_STROP[pe.op] then
		return strop_pat_ok(pe)
	end -- strip #/##/%/%% , subst /,// , case-fold ^/^^/,/,,
	return false
end
-- A SCALAR ${..}-OP whose ONLY variable read is the value — length (${#x}), substring
-- (${x:o:l}), and the strip/subst/case pattern ops — is safe inside a nameref program:
-- pexp_scalar reads that value nameref-aware (rt.nameref_read = interp's expand_part_str,
-- the FULL nameref deref incl. an element/assoc target, matching bash's ${x#op}/${#x} on a
-- scalar/whole-array/assoc nameref). Excludes ${x@..} (reads the var's attrs/set-ness BY
-- NAME), default/alternate (a set-ness test on the name), an element ${a[i]..}, and array
-- count — those need name/isset resolution the value read doesn't give, so they delegate.
local function pexp_nameref_valop(pe)
	-- ${#a[@]} count and a bare element read ${a[i]}/${m[k]} resolve the (possibly-nameref) NAME
	-- via sh:deref at runtime — a no-op for a plain var, the target for a whole-array/assoc
	-- nameref — then read; pexp_scalar renders them deref-aware. (Bare ${a[@]}/${a[*]} multi is
	-- array_multi_op, handled by emit_seg.)
	if pe.index == "@" or pe.index == "*" then
		return pe.op == "len" and pexp_compilable(pe)
	end
	if pe.index then
		return pe.op == nil and pexp_compilable(pe)
	end
	-- scalar default/alternate/assign/error (${x-d}/:-/+/:+/=/:=/?/:?): getv=sh:get and
	-- rt.var_has_value/assign_default ALL deref (sh:deref), so the compiled render matches interp
	-- exactly for a plain/scalar/whole-array nameref (an element-target nameref matches interp's
	-- own sh:deref behavior — both strip the subscript; a pre-existing interp quirk, left as parity).
	return (pe.op == "len" or pe.op == "sub" or PEXP_STROP[pe.op] or PEXP_DEFAULT[pe.op]) and pexp_compilable(pe)
end
-- ${a[@]OP} / ${a[*]OP}: a per-element string-op over the whole array, compiled by
-- mapping apply_str_op via rt.array_op_values — exactly interp's generic per-element
-- path (interp.lua multi_elems). Admits the bare expansion (no op) and the string
-- ops whose per-element transform is a scalar apply_str_op: strip (#/##/%/%%), subst
-- (/,//), case-fold (^/^^/,/,,), and the @Q/@U… transforms — all with compile-time
-- literal args. Excludes slice (:off:len — index/assoc position semantics), default/
-- alternate (:-/-/:+/+/…: field-wise default word), @a/@P, and ${!ref} indirection.
-- ${!ref} indirect: a runtime-resolved multi-segment (rt.indirect_elems bootstraps interp's
-- resolution — the target name and its scalar/array shape are late-bound). The ${!ref}'s own
-- line is passed so a $LINENO target resolves correctly. Only the plain op=="indirect" form
-- (a scalar/subscript ref); the ${!a[@]}-keys op=="indices" form stays with array_index_strs.
local function indirect_ok(pe)
	-- Exclude the array-multi indirect forms (${!a[@]-op}, ${!a[*]…}): the name resolves to a
	-- space-joined list -> "invalid variable name", which raises; inside a compiled subshell the
	-- fork doesn't contain that lineabort. Rare — delegate them. Scalar / [i] / $N / @ refs compile.
	return pe.op == "indirect" and pe.index ~= "@" and pe.index ~= "*" and type(pe.name) == "string" and pe.name ~= ""
end
local function array_multi_op(pe)
	local is_arr = (pe.index == "@" or pe.index == "*") -- ${a[@]OP}: array subscript
	local is_pos = (pe.index == nil and (pe.name == "@" or pe.name == "*")) -- ${@OP}/${*OP}: positional
	if not (is_arr or is_pos) then
		return false
	end
	if pe.via_indirect then
		return false
	end
	if is_arr and (type(pe.name) ~= "string" or not pe.name:match("^[%a_][%w_]*$")) then
		return false
	end
	if not pe.op then
		return true
	end -- bare ${a[@]} / ${a[*]} (bare $@/$* is p.special, not here)
	if pe.op == "@" then
		return PEXP_AT[pe.arg] and pe.arg ~= "a" and not (is_arr and (pe.arg == "A" or pe.arg == "K" or pe.arg == "k"))
			and true
			or false
	end -- ${a[@]@Q} … (@a — a per-element attr string — and ${a[@]@A/@K/@k} — whole-array
	-- declaration / key-value forms — stay with interp: none is a per-element apply_str_op)
	if pe.op == "sub" then
		return pexp_word_args_ok(pe)
	end -- ${a[@]:off:len} slice
	if ARRAY_DEFAULT[pe.op] then
		return pexp_word_args_ok(pe)
	end -- ${a[@]:-def}/-/:+/+
	-- ${!a[@]} keys. The `*` (star) form has bash bug #627 (an empty-IFS join quirk that
	-- rt.expand_fields does not replicate — the interp field engine does), so ${!a[*]} delegates.
	if pe.op == "indices" then
		return pe.index == "@" and not pe.drop
	end
	return PEXP_STROP[pe.op] and strop_pat_ok(pe) or false -- quoted/backslash pattern renders via emit_pattern_glob
end
-- A subscript's word-expanded form, which rt.array_key uses only as an ASSOC key (an indexed
-- array re-reads the raw text arithmetically). One with a $(…)/$((…))/`…` side effect is passed
-- as a thunk, so `${d[$((c++))]}` on an indexed array increments once, not twice.
function subscript_word(raw, lifted)
	local w = emit_word(require("parser").parse_word(raw), lifted)
	if raw:find("$(", 1, true) or raw:find("`", 1, true) then
		return "function() return " .. w .. " end"
	end
	return w
end

-- Lua expr for a compilable pexp's scalar string value (assumes pexp_compilable).
-- A ${v:off:len} operand that is plain literal arithmetic (`i%20`, ` -3`, `n+1`) that
-- can't fail — no side effect, no division but by a non-zero literal — compiles to a
-- native value; anything else takes rt.substr_arith (expansion, bash's error labels).
local function substr_safe(e)
	if type(e) ~= "table" then
		return true
	end
	if e.k == "bin" and (e.op == "/" or e.op == "%") and not (e.r and e.r.k == "num" and tonumber(e.r.v) ~= 0) then
		return false
	end
	for _, f in ipairs({ "e", "l", "r", "c", "a", "b" }) do
		if not substr_safe(e[f]) then
			return false
		end
	end
	return true
end
local function substr_native(txt, lifted)
	if not txt or txt == "" or txt:find("[^%w_ %%%*%+%-%(%)<>=!&|%^~?:]") then
		return nil
	end
	local ok, ast = pcall(require("parser").arith, txt, true)
	if not ok or type(ast) ~= "table" or not_compilable(ast) or arith_side_effect(ast) or not substr_safe(ast) then
		return nil
	end
	return ("tonumber(%s)"):format(emit_value(ast, lifted))
end
function pexp_scalar(pe, lifted)
	-- ${x@a} / ${x[i]@a}: the variable's attribute letters, read straight from its binding
	-- (attr_string). Independent of value set-ness — a declared valueless assoc still reports
	-- `A` — and never get_u, which would trip set -u on an unset element. The element and
	-- scalar forms alike report the whole variable's attributes (bash).
	if pe.op == "@" and pe.arg == "a" then
		return ("sh:attr_string_u(%q)"):format(pe.name)
	end
	local val
	local ename = EF.has_nameref and ("sh:deref(%q)"):format(pe.name) or ("%q"):format(pe.name) -- a nameref array read resolves to its target
	if pe.index == "@" or pe.index == "*" then -- ${#a[@]}: array element COUNT (op is len, gated)
		return ("tostring(sh:array_count(%s))"):format(ename)
	elseif pe.index then -- ${name[sub]…}: read the element; a read-only op (below) then applies to it.
		-- Pass BOTH the raw subscript (arith-evaluated for an indexed array) and its word-expanded
		-- form (the assoc key); rt.array_elem picks per the array's type, matching interp's array_key.
		local expanded = subscript_word(pe.index, lifted)
		val = ("rt.array_elem(sh, %s, %q, %s)"):format(ename, pe.index, expanded)
		if pe.op == nil then
			return val
		end
		if PEXP_DEFAULT[pe.op] then
			-- ${a[i]:-d} / := / ? …: defer to Shell:expand_param with the resolved key and a LAZY
			-- default-word thunk (a side-effecting default runs only when its branch is taken, and
			-- := writes back to a[key]) — interp's exact element default/assign/error path.
			local defthunk = ("function() return %s end"):format(
				emit_word(require("parser").parse_word(pe.arg or ""), lifted)
			)
			return ('sh:expand_param({["name"]=%q,["index"]=%q,["op"]=%q}, %s, nil, rt.array_key(sh, %q, %q, %s))'):format(
				pe.name,
				pe.index,
				pe.op,
				defthunk,
				pe.name,
				pe.index,
				expanded
			)
		end
		if pe.op == "@" then
			-- ${a[i]@Q}/@U/@L/…: route via expand_param so ELEMENT set-ness (is_elem_set) decides —
			-- an unset element yields "" (rt.at_transform would test the BASE var's set-ness instead).
			-- The transform letter is the 3rd (arg) PARAMETER, exactly as interp calls expand_param.
			return ('sh:expand_param({["name"]=%q,["index"]=%q,["op"]="@"}, %q, nil, rt.array_key(sh, %q, %q, %s))'):format(
				pe.name,
				pe.index,
				pe.arg,
				pe.name,
				pe.index,
				expanded
			)
		end
	elseif EF.has_nameref then
		-- nameref program: read the value through the nameref (rt.nameref_read = interp's
		-- expand_part_str, following the ref incl. an element/assoc target). Only value-ops
		-- (len/sub/strip/subst/case) reach here in a nameref program (pexp_nameref_valop).
		val = ("rt.nameref_read(sh, %q)"):format(pe.name)
	else
		val = lifted[pe.name] and ("rt.i64_to_str(%s)"):format(lname(pe.name)) or ("sh:get_u(%q)"):format(pe.name) -- get_u: an unset var trips set -u, like bash
	end
	if pe.op == "len" then
		-- ${#name}: in a nameref program, bash's length shortcut treats an element-target
		-- nameref as length 0 (rt.nameref_len) — distinct from the value read above.
		if EF.has_nameref and not pe.index then
			return ("tostring(rt.nameref_len(sh, %q))"):format(pe.name)
		end
		return ("tostring(rt.mb_strlen(%s))"):format(val)
	end -- ${#x}: codepoint length
	if pe.op == "@" then
		return ("rt.at_transform(sh, %q, %s, %q)"):format(pe.name, val, pe.arg)
	end -- unset-aware transform
	if PEXP_DEFAULT[pe.op] then
		-- default/alternate/assign/error (SCALAR/quoted context). `getv` uses sh:get (set -u
		-- exempt); the default word is expanded lazily via Lua short-circuit (a side-effecting
		-- $(…) default runs only when its branch is taken). - / + test set-ness, :- / :+ test
		-- non-emptiness.
		-- A default with ~ \ ' " only reaches here in a QUOTED context (pexp_compilable gates
		-- the unquoted one out), where it follows double-quoted rules — parse it as interp's pw
		-- does. A plain / $var / $(…) default is identical either way, so keep parse_word for it.
		local P = require("parser")
		local dparse = (pe.arg and pe.arg:find("[~\\'\"]")) and P.parse_default_quoted or P.parse_word
		local def = emit_word(dparse(pe.arg or "", pe.hd), lifted)
		local getv = lifted[pe.name] and ("rt.i64_to_str(%s)"):format(lname(pe.name)) or ("sh:get(%q)"):format(pe.name)
		if pe.op == ":-" then
			return ('(function() local __d = %s; return __d ~= "" and __d or %s end)()'):format(getv, def)
		end
		if pe.op == ":+" then
			return ('(function() local __d = %s; return __d ~= "" and %s or "" end)()'):format(getv, def)
		end
		if pe.op == "-" then
			return ("(rt.var_has_value(sh, %q) and %s or %s)"):format(pe.name, getv, def)
		end
		if pe.op == "+" then
			return ('(rt.var_has_value(sh, %q) and %s or "")'):format(pe.name, def)
		end
		-- :=/= assign the default to the var (side effect) and return it; :?/? error out.
		if pe.op == ":=" then
			return ('(function() local __d = %s; return __d ~= "" and __d or rt.assign_default(sh, %q, %s) end)()'):format(
				getv,
				pe.name,
				def
			)
		end
		if pe.op == "=" then
			return ("(rt.var_has_value(sh, %q) and %s or rt.assign_default(sh, %q, %s))"):format(
				pe.name,
				getv,
				pe.name,
				def
			)
		end
		local noword = pe.arg == nil or pe.arg == "" -- (bash's own words then)
		if pe.op == ":?" then
			return ('(function() local __d = %s; return __d ~= "" and __d or rt.param_error(sh, %q, %s) end)()'):format(
				getv,
				pe.name,
				noword and '"parameter null or not set"' or def
			)
		end
		return ("(rt.var_has_value(sh, %q) and %s or rt.param_error(sh, %q, %s))"):format(pe.name, getv, pe.name,
			noword and '"parameter not set"' or def) -- ?
	end
	if pe.op == "sub" then -- ${v:off:len}: arith-eval off/len (nil-coerced to 0 for a present
		-- operand, like interp), then substr by codepoint via apply_str_op("sub").
		local P = require("parser")
		local off = substr_native(pe.arg, lifted)
			or ("(rt.substr_arith(sh, %q, %s) or 0)"):format(require("runtime").pe_label(pe), emit_word(P.parse_word(pe.arg or ""), lifted))
		if pe.arg2 == nil then
			return ('sh:apply_str_op("sub", %s, %s)'):format(val, off)
		end
		local len = substr_native(pe.arg2, lifted)
			or ("(rt.substr_arith(sh, %q, %s) or 0)"):format(require("runtime").pe_label(pe), emit_word(P.parse_word(pe.arg2), lifted))
		return ('sh:apply_str_op("sub", %s, %s, %s, %q)'):format(val, off, len, pe.arg2)
	end
	-- strip/subst/case (PEXP_STROP): a plain literal pattern is passed verbatim (apply_str_op
	-- globs it); a dynamic/quoted pattern is rendered mask-aware via emit_pattern_glob to the
	-- expanded glob string. Replacement (arg2) is literal (pexp_compilable gated it).
	if not pat_verbatim_ok(pe.arg) then
		return ("sh:apply_str_op(%q, %s, %s, %q)"):format(
			pe.op,
			val,
			emit_pattern_glob(pe.arg or "", lifted),
			pe.arg2 or ""
		)
	end
	return ("sh:apply_str_op(%q, %s, %q, %q)"):format(pe.op, val, pe.arg or "", pe.arg2 or "")
end

local function field_word(w, lifted)
	if not emitable_word(w) then
		return nil
	end
	if #w.parts == 0 then
		return nil
	end
	-- Scalar fast path (compile-time decision): a lone arith result or lifted-int64
	-- var always renders to a numeric string — no IFS/glob chars — so it is provably
	-- a SINGLE field. Skip the runtime split+glob entirely (one table entry, no alloc).
	if #w.parts == 1 then
		local p = w.parts[1]
		if not p.q and (p.arith or p.arithast or (p.var and lifted[p.var])) then
			return { expr = emit_word(w, lifted), scalar = true }
		end
	end
	local allexp, alllit, hasglob = true, true, false
	for _, p in ipairs(w.parts) do
		if p.q then
			return nil
		end -- a quoted part needs the mask
		if p.special then
			return nil
		end -- @/*/$?/... handled elsewhere
		if p.var and (COMPILE_UNSAFE_VAR[p.var] and p.var ~= "LINENO") then
			return nil
		end -- $LINENO/$_/… → interp
		-- unquoted ${x:-word}: the taken branch (value or default) becomes the scalar value,
		-- then the outer field_split splits+globs it — pexp_compilable already gates the default
		-- to an emit_word-able word free of ~ \ ' " (quoted/multi/$* defaults, where field-wise
		-- expansion would differ, delegate), so scalar-value + split matches interp's field-wise.
		if p.var or p.param or p.cmdsub or p.arith or p.arithast or p.pexp then
			alllit = false
		elseif p.lit then
			allexp = false
			if p.lit:find("[*?%[]") or p.lit:find("[@!+?*]%(") then
				hasglob = true
			end -- glob / extglob
		else
			return nil
		end
	end
	if allexp then
		return { expr = emit_word(w, lifted), split = true }
	end -- $x / $x$y
	if alllit and hasglob then
		return { expr = emit_word(w, lifted), split = false } -- *.txt (emit_word tilde-expands a leading ~)
	end
	return nil
end

-- Forward: mixed_expandable and seg_native are defined just below, but the mixed
-- branch of emit_fields_into (above them) needs to see them.
local mixed_expandable, seg_native

-- Render ONE part of a mixed word to its scalar value expression — the same per-part
-- computation as emit_word, restricted to the scalar subset seg_native admits.
-- `tilde` enables word-initial ~ expansion for an unquoted literal at part index 1.
local function emit_scalar_val(p, i, lifted, tilde, w)
	if p.lit ~= nil then
		if
			tilde
			and i == 1
			and (p.lit:sub(1, 1) == "~" or (p.lit:find("~", 1, true) and p.lit:match("^[%a_][%w_]*%+?=") ~= nil))
		then
			return ("rt.tilde_word_initial(sh, %q, %s, %s)"):format(p.lit, tostring(w ~= nil and #w.parts > 1),
				(w and w.plainarg) and "sh.opt_posix" or "false")
		end
		return ("%q"):format(p.lit)
	elseif p.raw then
		return p.raw
	elseif p.var == "LINENO" then -- $LINENO: its value is the current source line, known at compile time
		return ("%q"):format(tostring(EF.cur_line or 0))
	elseif p.var then
		return EF.has_nameref and ("rt.nameref_read(sh, %q)"):format(p.var)
			or lifted[p.var] and ("rt.i64_to_str(%s)"):format(lname(p.var))
			or ("sh:get_u(%q)"):format(p.var)
	elseif p.param then
		return ("sh:param_u(%d, %s)"):format(p.param, tostring(p.braced or false))
	elseif p.special == "#" then
		return "tostring(sh.nparams)"
	elseif p.special == "?" then
		return "tostring(sh.status)"
	elseif p.special == "$" then
		return "tostring(sh:pid())"
	elseif p.special == "!" then
		return ("rt.last_bg_u(sh, %s)"):format(tostring(p.braced or false))
	elseif p.special == "-" then
		return "sh:dash_flags()" -- $-: current single-char option flags
	end
	error("curse-nocompile: mixed-word segment") -- unreachable given seg_native
end

-- Render one part to a segment literal {s=<value>, split=<bool>, unq=<bool>} for
-- rt.expand_fields, classifying it exactly as expand_to_fields' per-part add/feed_split:
--   quoted            -> add(s, false): literal, no split, no glob
--   unquoted literal  -> add(s, true):  glob-active, no split (word-initial ~)
--   unquoted $expand  -> feed_split(s): word-split on $IFS, then glob each field
local function emit_seg(p, i, lifted, w)
	if p.special == "@" or p.special == "*" then -- $@ / $*: a multi-element segment
		return ("{multi=true,star=%s,q=%s,elems=sh:paramList()}"):format(
			tostring(p.special == "*"),
			tostring(p.q or false)
		)
	end
	if p.pexp and p.pexp.op == "indirect" then -- ${!ref}: runtime-resolved (bootstrap) multi-segment
		local pe = p.pexp -- q = the outer quoting OR a quoted multi alternate's forced quoting (__qf)
		return ("(function() local __e, __s, __qf = rt.indirect_elems(sh, %q, %s, %s, %s, %d); return {multi=true,star=__s,q=(%s or __qf),elems=__e} end)()"):format(
			pe.name,
			pe.index and ("%q"):format(pe.index) or "nil",
			pe.iop and ("%q"):format(pe.iop) or "nil",
			tostring(p.q or false),
			EF.cur_line or 0,
			tostring(p.q or false)
		)
	end
	if p.pexp and p.pexp.op == "prefix" then -- ${!pre@}/${!pre*}: the set of variable NAMES with the
		-- prefix, as a multi-element segment (each name its own field) — interp's var_prefix_names.
		-- The `*` form joins with IFS[0] in a quoted context (rt.expand_fields, like ${a[*]}).
		return ("{multi=true,star=%s,q=%s,elems=sh:var_prefix_names(%q)}"):format(
			tostring(p.pexp.star and true or false),
			tostring(p.q or false),
			p.pexp.name
		)
	end
	if p.pexp and pexp_compilable(p.pexp) then -- scalar ${..} op: len/subst/strip/default/@Q/substring
		-- A SCALAR string operation renders to one value via pexp_scalar (the same expr emit_word
		-- uses). Quoted -> a literal segment (no split/glob); unquoted -> its value word-splits on
		-- $IFS then globs, exactly like a bare $x (the default word is gated simple by pexp_compilable).
		local s = pexp_scalar(p.pexp, lifted)
		if p.q then
			return ("{s=%s,split=false,unq=false}"):format(s)
		end
		return ("{s=%s,split=true,unq=true}"):format(s)
	end
	if p.pexp then -- ${a[@]} / ${a[*]}: array elements as a multi-element segment (gated)
		local pe = p.pexp
		local positional = (pe.name == "@" or pe.name == "*") -- ${@OP}/${*OP} vs ${a[@]OP}
		-- A nameref array read resolves to its target (sh:deref: no-op for a plain var, the target
		-- for a whole-array nameref); positional $@/$* is not a var name, so never deref it.
		local aname = (EF.has_nameref and not positional) and ("sh:deref(%q)"):format(pe.name)
			or ("%q"):format(pe.name)
		-- Element source: positional params ($1.. — plus $0 for a slice, whose offset is
		-- indexed) or the array's values.
		local elems = positional and (pe.op == "sub" and "sh:paramListSub()" or "sh:paramList()")
			or ("sh:array_values(%s)"):format(aname)
		if pe.op == "indices" then -- ${!a[@]}: the keys/indices, not the values
			elems = ("rt.array_index_strs(sh, %s)"):format(aname)
		elseif pe.op == "sub" then -- ${a[@]:off:len} / ${@:off:len} slice: arith off/len, then select
			local P = require("parser")
			local off = ("(rt.substr_arith(sh, %q, %s) or 0)"):format(require("runtime").pe_label(pe), emit_word(P.parse_word(pe.arg or ""), lifted))
			local len = pe.arg2 and ("(rt.substr_arith(sh, %q, %s) or 0)"):format(require("runtime").pe_label(pe), emit_word(P.parse_word(pe.arg2), lifted))
				or "nil"
			elems = ("rt.array_slice_values(sh, %s, %s, %s, %s, %q)"):format(aname, elems, off, len, pe.arg2 or "")
		elseif ARRAY_DEFAULT[pe.op] then -- ${a[@]:-def}/-/:+/+ : the value list, or the default
			-- as a SINGLE field (rt.expand_fields then splits/keeps it per the outer q, exactly
			-- bash's field-wise default). null test grounded in bash string_list_dollar_at/_star:
			-- [@]/unquoted-[*] join with a non-empty sep (== #els>1 or els[1] non-empty); quoted
			-- [*] joins with IFS[0] (can be empty) -> rt.ifs_join_ne. -/+ test element count.
			local P = require("parser")
			local def = emit_word(P.parse_word(pe.arg or ""), lifted)
			local ne = ((pe.index == "*" or pe.name == "*") and p.q) and "rt.ifs_join_ne(sh, __e)"
				or '(#__e > 1 or (__e[1] ~= nil and __e[1] ~= ""))'
			local body
			if pe.op == "-" then
				body = ("if #__e > 0 then return __e else return {%s} end"):format(def)
			elseif pe.op == ":-" then
				body = ("if %s then return __e else return {%s} end"):format(ne, def)
			elseif pe.op == "+" then
				body = ("if #__e > 0 then return {%s} else return {} end"):format(def)
			else
				body = ("if %s then return {%s} else return {} end"):format(ne, def)
			end -- :+
			elems = ("(function() local __e = %s; %s end)()"):format(elems, body)
		elseif pe.op then -- per-element string-op (strip/subst/case/@Q…): map apply_str_op
			-- a STROP pattern with a quoted/backslash metachar renders mask-aware (emit_pattern_glob),
			-- exactly like the scalar strop; a verbatim-safe pattern (and every @-transform letter)
			-- passes through literally.
			local pg = (PEXP_STROP[pe.op] and not pat_verbatim_ok(pe.arg))
					and emit_pattern_glob(pe.arg or "", lifted)
				or ("%q"):format(pe.arg or "")
			elems = ("rt.array_op_values(sh, %s, %q, %s, %q)"):format(elems, pe.op, pg, pe.arg2 or "")
		end
		return ("{multi=true,star=%s,q=%s,elems=%s}"):format(
			tostring(pe.index == "*" or pe.name == "*"),
			tostring(p.q or false),
			elems
		)
	end
	if p.q then
		return ("{s=%s,split=false,unq=false}"):format(emit_scalar_val(p, i, lifted, false))
	elseif p.lit ~= nil then
		return ("{s=%s,split=false,unq=true}"):format(emit_scalar_val(p, i, lifted, true, w))
	end
	return ("{s=%s,split=true,unq=true}"):format(emit_scalar_val(p, i, lifted, false))
end

-- Emit statement(s) appending word `w`'s final field(s) to Lua table `tbl`. A
-- word_safe word contributes one field (emit_word); a field_word splits+globs at
-- runtime via rt.field_split. `wrap` (e.g. "rt.cstr(%s)") wraps each final field.
local function emit_fields_into(tbl, w, lifted, wrap)
	local function W(x)
		return wrap and wrap:format(x) or x
	end
	local fw = not word_safe(w) and field_word(w, lifted)
	if word_safe(w) or (fw and fw.scalar) then -- one field, no runtime split/glob
		return ("%s[#%s+1] = %s"):format(tbl, tbl, W(word_safe(w) and emit_word(w, lifted) or fw.expr))
	end
	if fw then
		return ("do local __f = rt.field_split(sh, %s, %s); for __i=1,#__f do %s[#%s+1]=%s end end"):format(
			fw.expr,
			tostring(fw.split),
			tbl,
			tbl,
			W("__f[__i]")
		)
	end
	-- A mixed word whose every part emit_seg can render (literal/quoted, `$x`/`$?`/param,
	-- and $@/$* as a multi-element segment — none of the raise-y expansions
	-- mixed_expandable excludes): compile each part's VALUE and hand the segments to
	-- rt.expand_fields, which does the mask-aware split+glob at runtime. Genuine
	-- compilation — no interp field engine. Lifted operands are read straight from the
	-- native i64 local (no sh flush needed).
	if seg_native(w, lifted) then
		local segs = {}
		for i, p in ipairs(w.parts) do
			segs[#segs + 1] = emit_seg(p, i, lifted, w)
		end
		return ("do local __f = rt.expand_fields(sh, {%s}); for __i=1,#__f do %s[#%s+1]=%s end end"):format(
			table.concat(segs, ", "),
			tbl,
			tbl,
			W("__f[__i]")
		)
	end
	-- Anything left (e.g. a word with a `${##}` length-op part): expand with the SHARED
	-- field engine. Flush any LIFTED operand to sh first (a native i64 local isn't visible
	-- there — command args only READ vars, so no reload). A runtime call like rt.field_split.
	local flush, seen = {}, {}
	for _, p in ipairs(w.parts) do
		if p.var and lifted[p.var] and not seen[p.var] then
			seen[p.var] = true
			flush[#flush + 1] = ("sh:aset(%q, %s)"):format(p.var, lname(p.var))
		end
	end
	local pre = #flush > 0 and (table.concat(flush, "; ") .. "; ") or ""
	return ("do %slocal __f = I.expand_to_fields(sh, %s); for __i=1,#__f do %s[#%s+1]=%s end end"):format(
		pre,
		ser(w),
		tbl,
		tbl,
		W("__f[__i]")
	)
end

-- A word the shared field engine (I.expand_to_fields) can expand safely from the
-- compiled path: no expansion that can RAISE a containable error (arith / command sub /
-- ${…} operator like :? — those must delegate so exec_stmt contains the error and
-- keeps $?=1 without aborting the line), no nameref (element-deref subtlety), and no
-- CFG-unreproducible special ($LINENO/$_). Plain literal+var+param+$@/$* words qualify —
-- exactly the mixed shapes (`foo$x`, `$x.txt`, `x$@y`) that field_word can't render.
function mixed_expandable(w, lifted)
	for _, p in ipairs(w.parts) do
		if p.arith or p.arithast or p.cmdsub or p.procsub then
			return false
		end
		-- a bare ${a[@]}/${a[*]} array expansion is a multi-element segment seg_native renders;
		-- a scalar ${..} op (len/subst/strip/default/substring/@Q) renders via pexp_scalar; the
		-- ${!ref} indirect / ${!pre@} prefix via the bootstrap. indirect+prefix resolve NAMES so
		-- they are nameref-safe; a whole-array ${a[@]} or a scalar ${..}-OP reads the var DIRECTLY
		-- (would miss an element-nameref deref) so those stay non-nameref-only; anything else delegates.
		if
			p.pexp
			and not (
				indirect_ok(p.pexp)
				or p.pexp.op == "prefix"
				or pexp_nameref_valop(p.pexp)
				or array_multi_op(p.pexp)
				or (not EF.has_nameref and pexp_compilable(p.pexp))
			)
		then
			return false
		end
		if p.var and (COMPILE_UNSAFE_VAR[p.var] and p.var ~= "LINENO") then
			return false
		end
	end
	return true
end
-- A mixed word whose EVERY part emit_seg can render: these compile to rt.expand_fields
-- (native split+glob) rather than delegating to the interp field engine. This is an
-- explicit ALLOWLIST — scalar parts (literal/quoted, $x, $1..$9, the scalar specials
-- #/?/$/!) plus $@/$* as a multi-element segment. It excludes a length op (`${##}`:
-- `lenof` computes the VALUE's length, which emit_seg does not apply),
-- pexp/cmdsub/arith/arithast/procsub (raise-y or non-scalar), namerefs, and any
-- CFG-unreproducible special ($LINENO/$_/…).
function seg_native(w, lifted)
	for _, p in ipairs(w.parts) do
		if p.lenof then
			return false
		end -- ${#x}/${##}: length, not the plain value
		if p.lit ~= nil or p.raw then -- literal text / inlined-param string: ok
		elseif p.var then
			if COMPILE_UNSAFE_VAR[p.var] and p.var ~= "LINENO" then
				return false
			end -- a nameref-program var reads via rt.nameref_read (emit_scalar_val)
		elseif p.param then -- $1..$9 positional: ok
		elseif p.special == "#" or p.special == "?" or p.special == "$" or p.special == "!" or p.special == "-" then -- scalar specials
		elseif p.special == "@" or p.special == "*" then -- $@/$*: multi-element (emit_seg renders it)
		elseif
			p.pexp
			and (
				indirect_ok(p.pexp) -- ${!ref}: rt.indirect_elems bootstraps interp's nameref-aware indirect resolution
				or p.pexp.op == "prefix" -- ${!pre@}: name-matching, reads no potential-nameref value
				or pexp_nameref_valop(p.pexp) -- ${#ref}/${ref:o:l}/${ref#p}…: value read is nameref-aware
				or array_multi_op(p.pexp) -- ${a[@]}/${a[*]}…: array read resolves the name via sh:deref
				or (not EF.has_nameref and pexp_compilable(p.pexp))
			)
		then -- indirect/prefix resolve NAMES (nameref-safe); a whole-array ${a[@]} or a scalar ${..}-OP
			-- reads the var DIRECTLY (would miss an element-nameref deref), so those stay non-nameref-only
		else
			return false
		end -- other pexp, cmdsub, arith, procsub, or anything unknown
	end
	return true
end
-- Also reachable via the shared EF table so flatten_stmt (the for-in list gate) can call it
-- without taking a fresh upvalue — flatten_stmt is at the 60-upvalue cap (as with cur_line /
-- emit_regex_glob). Ordinary callers keep using the local seg_native directly.
EF.seg_native = seg_native
-- Render a case-clause pattern to a Lua EXPRESSION for its glob-form, quote-aware exactly
-- like interp's expand_pattern/expand_escaped: a QUOTED part's glob metachars are
-- backslash-escaped (literal match), an UNQUOTED expansion's metachars stay active. A
-- literal part folds to a compile-time constant; a scalar expansion ($x/$1/$?…) reads at
-- runtime, quoted ones wrapped in rt.glob_quote. Returns nil (→ keep I.case_match) for a
-- part emit can't render here: cmdsub/arith/${…}-op/$@/$*/length/CFG-unsafe special.
local CASE_GLOBSPECIAL = "[%*%?%[%]\\%(%)%|%+%@%!]"
-- Word-based core (shared by the string API below and the [[ == ]] RHS): render an
-- already-parsed word to its quote-aware glob expression, or nil if a part can't render here.
local function emit_pattern_glob_word(w, lifted)
	local p1 = w.parts[1]
	if p1 and p1.lit and not p1.q and p1.lit:sub(1, 1) == "~" then
		return nil -- a word-initial tilde: interp's expand_pattern expands it (runtime HOME)
	end
	local out = {}
	for i, p in ipairs(w.parts) do
		if p.lenof or p.cmdsub or p.arith or p.arithast or p.pexp or p.procsub then
			return nil
		end
		if p.special == "@" or p.special == "*" then
			return nil
		end -- multi-element in a pattern
		if p.var and (COMPILE_UNSAFE_VAR[p.var] and p.var ~= "LINENO") then
			return nil
		end
		if p.lit ~= nil then
			local s = p.lit
			if p.q then
				s = s:gsub(CASE_GLOBSPECIAL, "\\%0")
			end -- quoted metachars -> literal
			out[#out + 1] = ("%q"):format(s)
		else -- var / param / raw / scalar special ($#/$?/$$/$!): value; escape if quoted
			local v = emit_scalar_val(p, i, lifted, false)
			out[#out + 1] = p.q and ("rt.glob_quote(%s)"):format(v) or v
		end
	end
	if #out == 0 then
		return '""'
	end
	return table.concat(out, " .. ")
end
emit_pattern_glob = function(pat, lifted)
	local ok, w = pcall(require("parser").parse_word, pat)
	if not ok then
		return nil
	end
	return emit_pattern_glob_word(w, lifted)
end
EF.emit_pattern_glob_word = emit_pattern_glob_word -- for the dbracket == RHS (flatten_stmt is at the upvalue cap)
-- Render a `[[ L =~ R ]]` RHS word to its ERE string (interp's expand_regex): an unquoted
-- literal or expansion keeps ERE metachars ACTIVE; a quoted part is ERE-escaped (matched
-- literally). Returns nil (delegate) for a part emit can't render (cmdsub/arith/${..}-op/
-- $@/$*/length/CFG-unsafe special) or a word-initial ~ (bash tilde-expands the RHS then
-- matches THAT literally — a rarer path interp handles).
-- Assigned onto the shared EF table (not a new module local) so build_cfg — which calls it
-- from the =~ block — reuses its existing EF upvalue instead of adding one (the 60-upvalue cap).
local REGEX_SPECIAL = "[%.%^%$%*%+%?%(%)%[%]%{%}%|\\]"
EF.emit_regex_glob = function(w, lifted)
	-- quoted text inside a bracket expression is inserted raw (interp's expand_regex tracks
	-- the bracket state): a word mixing an unquoted `[` with quoting takes that path
	local hasq, hasbr = false, false
	for _, p in ipairs(w.parts) do
		if p.q then
			hasq = true
		elseif p.lit and p.lit:find("[", 1, true) then
			hasbr = true
		end
	end
	if hasq and hasbr then
		return nil
	end
	for i, p in ipairs(w.parts) do
		if p.lenof or p.cmdsub or p.arith or p.arithast or p.pexp or p.procsub then
			return nil
		end
		if p.special == "@" or p.special == "*" then
			return nil
		end -- multi-element in a regex
		if p.var and (COMPILE_UNSAFE_VAR[p.var] and p.var ~= "LINENO") then
			return nil
		end
		if i == 1 and p.lit ~= nil and not p.q and p.lit:sub(1, 1) == "~" then
			return nil
		end -- word-initial ~
	end
	local out = {}
	for i, p in ipairs(w.parts) do
		if p.lit ~= nil then
			local s = p.lit
			if p.q then
				s = s:gsub(REGEX_SPECIAL, "\\%0")
			end -- quoted ERE metachars -> literal
			out[#out + 1] = ("%q"):format(s)
		else -- var / param / raw / scalar special: value; ERE-escape it when quoted
			local v = emit_scalar_val(p, i, lifted, false)
			out[#out + 1] = p.q and ("rt.regex_quote(%s)"):format(v) or v
		end
	end
	if #out == 0 then
		return '""'
	end
	return table.concat(out, " .. ")
end
-- An `a=(…)` array literal the compiled tier can build: each BARE element's word is
-- field-engine-able (word_safe/field_word/seg_native), and each KEYED element `[k]=v` has
-- a LITERAL subscript (no $/`/quote — so rt.arrayassign resolves it with no word engine:
-- assoc verbatim, indexed via arith_str) and an emit_word-able value. An `a[i]=(…)`
-- list-to-member error, a brace-de-keyed element, or a nameref program keep I.run_arrayassign.
-- A keyed array subscript that resolves to a STATIC literal at compile time: a plain literal,
-- or a fully-quoted key (`['a+1']`, `["k k"]`) whose quotes we strip now. Returns the unquoted
-- literal, or nil for a dynamic subscript ($/`/mixed expansion) that must delegate. For an assoc
-- array the result IS the key; for an indexed array rt.arrayassign arith-evaluates it (so a
-- quoted `['3']` becomes 3, exactly like the unquoted form) — matching interp's array_key.
local function static_key(key)
	if not key:find("[%$`'\"\\]") then
		return key -- already a plain literal (may be an arith expr for an indexed array)
	end
	local ok, w = pcall(require("parser").parse_word, key)
	if not ok then
		return nil
	end
	local o = {} -- concatenate every part's (quote-removed) literal; nil if any part expands
	for _, p in ipairs(w.parts) do
		if p.lit == nil then
			return nil -- a var/cmdsub/arith/pexp part: dynamic subscript, delegate
		end
		o[#o + 1] = p.lit
	end
	return table.concat(o)
end
EF.static_key = static_key -- flatten_stmt references it at the array-literal emit sites (upvalue cap)
local function arrayassign_ok(st, lifted, allow_nameref)
	-- allow_nameref: an explicit `declare -a/-A NAME=(…)` REDECLARES the name as an array — a
	-- DIRECT write matching interp (which also doesn't write through a nameref for an array
	-- assign), and rt.array_convert_err now enforces the indexed<->assoc conversion rule the
	-- gate used to defer via delegation, so it is parity-safe in a nameref program / eval fragment.
	if st.index or (EF.has_nameref and not allow_nameref) then
		return false
	end
	for _, e in ipairs(st.elems) do
		if e.brace_bare then
			return false
		end -- `[k]=` value brace-expands (de-keyed): interp
		if e.key ~= nil then
			if static_key(e.key) == nil then
				return false
			end -- dynamic subscript ($/`/mixed) -> interp; a quoted-literal key is unquoted below
			-- A side-effecting arith in a KEYED element's subscript or value (`[100+i++]=$((i++))`)
			-- has a subtle eval order — bash evaluates ALL the values, THEN all the keys — that the
			-- straight-line compiled arrayassign can't reproduce. Delegate (interp gets the order).
			if arith_side_effect(safe_arith(static_key(e.key))) then
				return false
			end
			for _, p in ipairs(e.word.parts) do
				if
					(p.arith and arith_side_effect(safe_arith(p.arith)))
					or (p.arithast and arith_side_effect(p.arithast))
				then
					return false
				end
			end
			if not emitable_word(e.word) then
				return false
			end
		else
			if e.op ~= "=" then
				return false
			end
			if not (word_safe(e.word) or field_word(e.word, lifted) or seg_native(e.word, lifted)) then
				return false
			end
		end
	end
	return true
end
-- Build a `local __a = {...}` argv table for words[from..#words] (each field
-- split+globbed), or nil if any word needs the interpreter. `wrap` is applied to
-- each final field. Used for commands whose args word-split/glob.
local function field_argv(words, from, lifted, wrap, prefix)
	local out = { prefix and ("local __a = {" .. prefix .. "}") or "local __a = {}" }
	-- a long run of plain literal words (`printf x {1..70000}`) becomes ONE constant table:
	-- one statement per word overflows LuaJIT's jump range (as for-in lists do)
	local run = {}
	local function flush_run()
		if #run > 32 then
			out[#out + 1] = ("for _, __v in ipairs({%s}) do __a[#__a+1] = __v end"):format(table.concat(run, ","))
		else
			for _, e in ipairs(run) do
				out[#out + 1] = "__a[#__a+1] = rt.cstr(" .. e .. ")"
			end
		end
		run = {}
	end
	for j = from, #words do
		local w = words[j]
		if not empty_word(w) then -- an empty brace alternative ({X,,Y,}) adds no arg
			if not word_safe(w) and not field_word(w, lifted) and not mixed_expandable(w, lifted) then
				return nil
			end
			local code = emit_fields_into("__a", w, lifted, wrap)
			local lit = code:match('^__a%[#__a%+1%] = rt%.cstr%((%("[^"\\]*"%))%)$')
			if lit then
				run[#run + 1] = lit
			else
				flush_run()
				out[#out + 1] = code
			end
		end
	end
	flush_run()
	return table.concat(out, "; ")
end

-- Arith usable in a VALUE position (what emit_value renders): pure, no side effect,
-- no array subscript / embedded $-expansion / dynamic-special var.
local function arith_value_ok(e)
	if type(e) ~= "table" then
		return false
	end
	local k = e.k
	if k == "num" or k == "param" then
		return true
	end
	-- a subscripted READ (a[i]) is a value emit_value renders via rt.arith_read_elem (write
	-- targets are gated separately by arith_stmt_ok's `not e.idx` on asgn/post/pre).
	if k == "var" then
		if e.idxraw then
			return arith_elem_ok(e)
		end
		return not COMPILE_UNSAFE_VAR[e.name]
	end
	if k == "un" then
		return arith_value_ok(e.e)
	end
	if k == "bin" then
		return arith_value_ok(e.l) and arith_value_ok(e.r)
	end
	if k == "tern" then
		return arith_value_ok(e.c) and arith_value_ok(e.a) and arith_value_ok(e.b)
	end
	return false -- asgn/post/pre/comma/xpand/matherr are not values
end

-- Arith usable at STATEMENT position ((( … )) or forc init/step): a comma sequence,
-- a top-level assignment/inc/dec (with a value-position rhs), or a pure value. A
-- side effect nested in an operand, an array subscript, or a dynamic special var
-- ($LINENO/$_/…) delegates to the interpreter (the emitter renders none of those).
local function arith_stmt_ok(e)
	if type(e) ~= "table" then
		return false
	end
	local k = e.k
	if k == "comma" then
		return arith_stmt_ok(e.l) and arith_stmt_ok(e.r)
	end
	if k == "asgn" then
		-- element WRITE target a[i]= : rt.arith_elem_write, gated on a compilable subscript.
		if e.idxraw then
			return arith_elem_ok(e) and arith_value_ok(e.e)
		end
		return not COMPILE_UNSAFE_VAR[e.name] and arith_value_ok(e.e)
	end
	if k == "post" or k == "pre" then
		if e.idxraw then
			return arith_elem_ok(e)
		end -- ++a[i] / a[i]++ via rt.arith_elem_incr
		return not COMPILE_UNSAFE_VAR[e.name]
	end
	return arith_value_ok(e)
end

-- Emit statements that evaluate arith `e` WITH its side effects, leaving the
-- result int64 in Lua local `dst`. A lifted var is a native int64 local; a
-- non-lifted one goes through the sh:aget/aset int64 accessors (genuine primitive
-- calls on natively-computed values, not an AST re-walk). Compound ops reuse
-- emit_value's operator logic (div0, shifts, **) via a synthetic bin node.
emit_arith_into = function(dst, e, lifted)
	local k = e.k
	if k == "comma" then -- l for its side effect, r for the result
		return emit_arith_into(dst, e.l, lifted) .. "; " .. emit_arith_into(dst, e.r, lifted)
	end
	-- ${..[i]} element WRITE target (gated by arith_stmt_ok via arith_elem_ok): resolve the key
	-- once and store through rt.arith_elem_write/_incr; the operator arithmetic stays in emit_value
	-- via a compute closure over the OLD element value (__o).
	local function elem_args(ee)
		return ("%q, %q, %s"):format(ee.name, ee.idxraw, emit_word(require("parser").parse_word(ee.idxraw), lifted))
	end
	if (k == "asgn" or k == "pre" or k == "post") and e.idxraw then
		if k == "asgn" and e.op == "=" then -- a[i] = e: no read
			return ("%s = rt.arith_elem_write(sh, %s, false, function() return %s end)"):format(
				dst,
				elem_args(e),
				emit_value(e.e, lifted)
			)
		elseif k == "asgn" then -- a[i] OP= e: read old (__o), apply the binop, store
			local newv =
				emit_value({ k = "bin", op = e.op:sub(1, #e.op - 1), l = { k = "raw", code = "__o" }, r = e.e, etxt = e.etxt, etok = e.etok }, lifted)
			return ("%s = rt.arith_elem_write(sh, %s, true, function(__o) return %s end)"):format(
				dst,
				elem_args(e),
				newv
			)
		end
		return ("%s = rt.arith_elem_incr(sh, %s, %dLL, %s)"):format(dst, elem_args(e), e.d, tostring(k == "post"))
	end
	if k == "asgn" then
		local rhs
		if e.op == "=" then
			rhs = emit_value(e.e, lifted) -- pure define: no read of the target
		else
			local cur = lifted[e.name] and lname(e.name) or (arith_varread):format(e.name) -- compound reads first
			rhs = emit_value({ k = "bin", op = e.op:sub(1, #e.op - 1), l = { k = "raw", code = cur }, r = e.e, etxt = e.etxt, etok = e.etok }, lifted)
		end
		if lifted[e.name] then
			return ("%s = %s; %s = %s"):format(lname(e.name), rhs, dst, lname(e.name))
		end
		return ("%s = sh:aset(%q, %s)"):format(dst, e.name, rhs)
	end
	if k == "pre" then -- ++x / --x: update, then result is the new value
		if lifted[e.name] then
			return ("%s = %s + %dLL; %s = %s"):format(lname(e.name), lname(e.name), e.d, dst, lname(e.name))
		end
		return ("%s = sh:aset(%q, %s + %dLL)"):format(dst, e.name, (arith_varread):format(e.name), e.d)
	end
	if k == "post" then -- x++ / x--: result is the OLD value, then update
		if lifted[e.name] then
			return ("%s = %s; %s = %s + %dLL"):format(dst, lname(e.name), lname(e.name), lname(e.name), e.d)
		end
		return ("%s = %s; sh:aset(%q, %s + %dLL)"):format(dst, (arith_varread):format(e.name), e.name, dst, e.d)
	end
	return ("%s = %s"):format(dst, emit_value(e, lifted)) -- a pure value
end

-- Can this arith raise at runtime? A non-lifted read may fault (nounset /
-- recursive-eval parse error / bad array value); /, %, ** and /=, %= can fault
-- (÷0, negative exponent). If none apply, the (( )) result is emitted inline with
-- no pcall — keeping the lifted-int64 hot loop native (JIT-compilable).
local function arith_can_error(e, lifted)
	if type(e) ~= "table" then
		return false
	end
	local k = e.k
	if k == "var" then
		return not lifted[e.name]
	end
	if k == "bin" and (e.op == "/" or e.op == "%" or e.op == "**") then
		return true
	end
	if k == "asgn" then
		if e.op == "/=" or e.op == "%=" then
			return true
		end
		if e.op ~= "=" and not lifted[e.name] then
			return true
		end -- compound reads the target
		return arith_can_error(e.e, lifted)
	end
	if (k == "post" or k == "pre") and not lifted[e.name] then
		return true
	end
	return arith_can_error(e.e, lifted)
		or arith_can_error(e.l, lifted)
		or arith_can_error(e.r, lifted)
		or arith_can_error(e.c, lifted)
		or arith_can_error(e.a, lifted)
		or arith_can_error(e.b, lifted)
end

-- Decide how the compiled tier computes an INDEXED element-assign subscript key. Hung on EF so
-- build_cfg (at the 60-upvalue cap) needs NO new upvalue. Returns (mode, keystr):
--   "native"+emit_value : bare arith subscript reading lifted locals (fixes a[i]= in a lifted-var
--       loop); only for a NON-assoc array (caller gates on is_assoc). Gated to lifted/error-free.
--   "xexp"  : the subscript word EXPANDS ($i) -> expand natively then arith the VALUE.
--   "raw"   : literal non-arith (a[\'3\']) / non-lifted var -> the raw arith_str path (correct
--       when sh.vars is authoritative; also preserves a bash quote syntax error).
EF.elem_keyexpr = function(st, iw, lifted)
	local ia = safe_arith(st.index)
	if arith_value_ok(ia) and not arith_side_effect(ia) and not not_compilable(ia)
		and not arith_reads_unsafe(ia) and not arith_can_error(ia, lifted) then
		return "native", emit_value(ia, lifted)
	end
	for _, pp in ipairs(iw.parts) do
		if pp.var or pp.pexp or pp.param or pp.special or pp.arith or pp.arithast then
			return "xexp"
		end
	end
	return "raw"
end

-- Can this arith raise a THROWN error (as opposed to a flagged read fault)? Only
-- ÷0 / mod-0 / negative ** do — via rt.idiv/imod/ipow. Those need a pcall to catch;
-- everything else (non-lifted reads) records sh.arithfault without throwing, so the
-- common accumulator `(( sum += x ))` needs no per-iteration pcall/closure.
local function arith_can_div_fault(e)
	if type(e) ~= "table" then
		return false
	end
	local k = e.k
	if k == "bin" and (e.op == "/" or e.op == "%" or e.op == "**") then
		return true
	end
	if k == "asgn" and (e.op == "/=" or e.op == "%=") then
		return true
	end
	return arith_can_div_fault(e.e)
		or arith_can_div_fault(e.l)
		or arith_can_div_fault(e.r)
		or arith_can_div_fault(e.c)
		or arith_can_div_fault(e.a)
		or arith_can_div_fault(e.b)
end

-- The CFG compiler only understands ARITHMETIC conditions. A forc cond is
-- already an arith node; a while/if cond is now a command list, which we compile
-- only when it's exactly one `(( expr ))` — extract that arith node here (never
-- mutating the shared AST). Returns nil for a cond the compiler can't handle;
-- assert_compilable (below) has already thrown for those, so post-validation this
-- always yields the arith node for the conds that remain.
local function cond_arith(c)
	if type(c) ~= "table" then
		return nil
	end
	if c.k then
		return c
	end -- an arith node already (forc init/cond/step)
	if #c == 1 and c[1] and c[1].t == "arithcmd" then
		return c[1].expr
	end
	return nil
end

-- `[ A -op B ]` / `test A -op B` do an ARITHMETIC comparison. When both operands
-- are provably integer, the whole test is a native int64 compare — no do_test, no
-- per-iteration argv table. bash errors on a non-integer operand, so a plain string
-- var stays on the do_test path; only a lifted-int64 var, an integer literal, or an
-- arith $((…)) qualifies (quoting is irrelevant in arithmetic).
local TEST_ARITH_OP = { ["-eq"] = "==", ["-ne"] = "!=", ["-lt"] = "<", ["-le"] = "<=", ["-gt"] = ">", ["-ge"] = ">=" }
local function test_operand_arith(w, lifted)
	if #w.parts ~= 1 then
		return nil
	end
	local p = w.parts[1]
	if p.var and lifted[p.var] then
		return { k = "var", name = p.var }
	end
	if p.lit and p.lit:match("^[+-]?%d+$") then
		return { k = "num", v = p.lit }
	end
	if p.arithast then
		return p.arithast
	end
	if p.arith then
		return safe_arith(p.arith)
	end
	return nil
end
-- Returns the equivalent arith comparison node for a compilable `[ … ]`/test cond,
-- or nil (caller falls back to the do_test command path).
local function test_as_arith(cond, lifted)
	if type(cond) ~= "table" or cond.k or #cond ~= 1 then
		return nil
	end
	local st = cond[1]
	if not st or st.t ~= "simple" or st.redirs or st.assigns then
		return nil
	end
	local w = st.words
	local function lit1(x)
		return x and x.parts[1] and #x.parts == 1 and x.parts[1].lit
	end
	local cmd, A, opw, B = lit1(w[1]), nil, nil, nil
	if cmd == "[" then
		if #w ~= 5 or lit1(w[5]) ~= "]" then
			return nil
		end
		A, opw, B = w[2], w[3], w[4]
	elseif cmd == "test" then
		if #w ~= 4 then
			return nil
		end
		A, opw, B = w[2], w[3], w[4]
	else
		return nil
	end
	local op = TEST_ARITH_OP[lit1(opw) or ""]
	if not op then
		return nil
	end
	local l, r = test_operand_arith(A, lifted), test_operand_arith(B, lifted)
	if not l or not r or not_compilable(l) or not_compilable(r) or arith_side_effect(l) or arith_side_effect(r) then
		return nil
	end
	return { k = "bin", op = op, l = l, r = r }
end

-- ...and when an operand is a plain (non-lifted) variable: {cmd, op, A, B} Lua exprs for
-- rt.test_icmp — a native compare when its value is a plain decimal at run time, else
-- the generic test on its fields. nil when neither shape fits.
local function test_as_varcmp(cond, lifted)
	if type(cond) ~= "table" or cond.k or #cond ~= 1 then
		return nil
	end
	local st = cond[1]
	if not st or st.t ~= "simple" or st.redirs or st.assigns then
		return nil
	end
	local w = st.words
	local function lit1(x)
		return x and x.parts[1] and #x.parts == 1 and x.parts[1].lit
	end
	local cmd, A, opw, B = lit1(w[1]), nil, nil, nil
	if cmd == "[" and #w == 5 and lit1(w[5]) == "]" then
		A, opw, B = w[2], w[3], w[4]
	elseif cmd == "test" and #w == 4 then
		A, opw, B = w[2], w[3], w[4]
	else
		return nil
	end
	local op = lit1(opw)
	if not TEST_ARITH_OP[op or ""] then
		return nil
	end
	local nvar = 0
	local function opnd(x)
		if #x.parts == 1 then
			local p = x.parts[1]
			if p.var and not lifted[p.var] and not p.index and not p.pexp and p.var:match("^[%a_][%w_]*$") then
				nvar = nvar + 1
				return ("rt.test_opnd(sh, %q, %s)"):format(p.var, p.q and "true" or "false")
			end
		end
		local e = test_operand_arith(x, lifted)
		if not e or not_compilable(e) or arith_side_effect(e) then
			return nil
		end
		return emit_value(e, lifted)
	end
	local a, b = opnd(A), opnd(B)
	if not a or not b or nvar == 0 then
		return nil
	end
	return { cmd = cmd, op = op, a = a, b = b }
end

-- A word that is exactly one DECIMAL integer literal -> its digits (else nil). A
-- leading-zero literal (`017`) is REJECTED: bash keeps the string and reads it as
-- OCTAL only in arithmetic, but appending "LL" would make Lua parse it as decimal
-- (017LL == 17, not 15). Rejecting it here keeps the var out of the int64 lift
-- (analyze_lift also gates on numeric_word), so it stays a string that aget/arith_num
-- interpret with bash's base rules.
local function numeric_word(w)
	if
		#w.parts == 1
		and w.parts[1].lit
		and w.parts[1].lit:match("^[+-]?%d+$")
		and not w.parts[1].lit:match("^[+-]?0%d")
	then
		return w.parts[1].lit
	end
	return nil
end

-- collect every variable NAME referenced in an arith node / word / stmt list.
local function collect_arith(e, set) -- (every variable an arith tree names, any node shape)
	if type(e) ~= "table" then
		return
	end
	if type(e.name) == "string" then
		set[e.name] = true
	end
	for _, v in pairs(e) do
		if type(v) == "table" then
			collect_arith(v, set)
		end
	end
end
local function collect_word(w, set)
	for _, p in ipairs(w.parts or {}) do
		if p.var then
			set[p.var] = true
		elseif p.arith then
			collect_arith(safe_arith(p.arith), set)
		elseif p.pexp then
			local pe = p.pexp
			if type(pe.name) == "string" then
				set[pe.name] = true
			end
			for _, a in ipairs({ pe.arg, pe.arg2 }) do -- (`${x:-$y}`: the word reads y)
				if type(a) == "string" and a:find("[%$`]") then
					local ok, aw = pcall(require("parser").parse_word, a)
					if ok and aw then
						collect_word(aw, set)
					end
				end
			end
		end
	end
end
-- Every variable a statement list assigns or reads — walking EVERY node shape (&&/||
-- lists, pipelines, groups, (( )), case bodies, …): a lifted var one of these touches
-- must stay in sync, so missing one is a wrong answer, not a slow one.
collect_names = function(stmts, set)
	local function walk(node)
		if type(node) ~= "table" then
			return
		end
		if node.k == "word" or (node.parts and not node.t) then
			collect_word(node, set)
			return
		end
		local t = node.t
		if t == "assign" or t == "arrayassign" then
			if type(node.name) == "string" then
				set[node.name] = true
			end
			if node.arith then
				collect_arith(node.arith, set)
			end
		elseif t == "arithcmd" then
			collect_arith(node.expr, set)
		elseif t == "forc" then
			collect_arith(node.init, set)
			collect_arith(cond_arith(node.cond), set)
			collect_arith(node.step, set)
		elseif (t == "forin" or t == "select") and type(node.name) == "string" then
			set[node.name] = true
		elseif t == "simple" then
			local cmd = node.words and node.words[1] and node.words[1].parts[1] and node.words[1].parts[1].lit
			if cmd == "local" or cmd == "declare" or cmd == "typeset" or cmd == "read" or cmd == "unset"
				or cmd == "export" or cmd == "readonly" or cmd == "let" or cmd == "printf" or cmd == "mapfile" then
				for j = 2, #node.words do -- (names these builtins set)
					local p1 = node.words[j].parts[1]
					local nm = p1 and p1.lit and p1.lit:match("^([%a_][%w_]*)")
					if nm then
						set[nm] = true
					end
				end
			end
		end
		for k, v in pairs(node) do
			if type(v) == "table" and k ~= "arith" and k ~= "init" and k ~= "step" and not (t == "arithcmd" and k == "expr") then
				walk(v)
			end
		end
	end
	for _, st in ipairs(stmts) do
		walk(st)
	end
end
-- every var touched by a NON-INLINABLE function body (those keep an out-of-line
-- closure, so a var they touch must be a shared upvalue, not a run-local).
-- Inlinable functions are spliced into run(), so their var access is run() access.
local function collect_funcvars(stmts, set, inlinable)
	for _, st in ipairs(stmts) do
		if st.t == "funcdef" then
			if not (inlinable and inlinable[st.name]) then
				collect_names(st.body, set)
			end
		elseif st.t == "forc" or st.t == "whilec" or st.t == "forin" then
			collect_funcvars(st.body, set, inlinable)
		elseif st.t == "if" then
			for _, cl in ipairs(st.clauses) do
				collect_funcvars(cl.body, set, inlinable)
			end
		end
	end
end

-- Which vars become native int64 MODULE-LEVEL locals (shared as upvalues by
-- run() and every function closure). A var qualifies if it is assigned somewhere,
-- every assignment is arithmetic or a numeric literal (reads never disqualify),
-- and it is never `local`'d in a function (that would need per-call shadowing,
-- which the sh scope handles instead). Scans EVERYWHERE, including function
-- bodies — a var shared between the top level and a function still lifts, because
-- the upvalue is one real variable both see (no hash lookup, no desync).
-- Variables the SHELL itself reads or writes behind the program's back (getopts updates
-- OPTIND/OPTARG and reads OPTERR, read/select set REPLY, set -x reads BASH_XTRACEFD, calls
-- check FUNCNEST, read -t reads TMOUT, …, plus the dynamic specials): a native register copy
-- would desync from sh.vars, so they are never lifted even when only assigned numbers.
local VAR_WRITERS = { read = 1, printf = 1, getopts = 1, let = 1, mapfile = 1, readarray = 1,
	wait = 1 }
local NO_LIFT = {}
for _, n in ipairs({ "OPTIND", "OPTARG", "OPTERR", "REPLY", "SECONDS", "RANDOM", "SRANDOM",
	"LINENO", "HISTCMD", "HISTSIZE", "HISTFILESIZE", "TMOUT", "COLUMNS", "LINES", "FUNCNEST",
	"BASH_XTRACEFD", "SHLVL", "PPID", "UID", "EUID", "BASHPID", "BASH_SUBSHELL", "EPOCHSECONDS",
	"EPOCHREALTIME", "BASH_ARGC", "COMP_CWORD", "COMP_POINT", "IFS", "_", "FUNCNAME",
	"POSIXLY_CORRECT", "IGNOREEOF", "BASH_ARGV0" }) do
	NO_LIFT[n] = true
end
for n in pairs(require("runtime").LOCALE_VARS) do
	NO_LIFT[n] = true -- (sh:set_str re-applies the locale; a lifted flush wouldn't)
end
analyze_lift = function(ast)
	-- A nameref program writes THROUGH namerefs (name=value -> some other var) via
	-- rt.assign_scalar, which has no lifted-local to update — so an int64 local would desync.
	-- Nameref programs are rare/cold; disable lifting so every var is sh-authoritative.
	if EF.has_nameref then
		return {}
	end
	local assigned, disq, localed = {}, {}, {}
	-- builtins that WRITE a named var through sh (read, printf -v, getopts, let, …): the
	-- write bypasses a native local, so any name among their literal args never lifts
	-- (over-disqualifying an option word is harmless). `let` assigns inside its expressions.
	local function writer_disq(st)
		local w1 = 1
		local p1 = st.words[w1] and st.words[w1].parts[1]
		while p1 and (p1.lit == "command" or p1.lit == "builtin") do
			w1 = w1 + 1
			p1 = st.words[w1] and st.words[w1].parts[1]
		end
		local cmd = p1 and p1.lit
		if not VAR_WRITERS[cmd] then
			return
		end
		for j = w1 + 1, #st.words do
			for _, p in ipairs(st.words[j].parts) do
				if p.lit then
					if cmd == "let" then
						for nm in p.lit:gmatch("[%a_][%w_]*") do
							disq[nm] = true
						end
					else
						local nm = p.lit:match("^([%a_][%w_]*)")
						if nm then
							disq[nm] = true
						end
					end
				end
			end
		end
	end
	-- A subshell can run IN-PROCESS, where an upval-lifted var lives in v_x but `unset`/
	-- `declare`/`readonly`/`export`/`typeset`/an indexed-or-array assign all act on sh.vars —
	-- so such a var would desync. Disqualify it from lifting (only the DISQUALIFIERS matter
	-- here; a plain arith assign inside the subshell is fine — the fragment shares the upval).
	-- Not added to `assigned`, so a subshell-only var still never lifts (no spurious flush).
	local function disq_scan(stmts)
		for _, st in ipairs(stmts) do
			local t = st.t
			if t == "assign" then
				if st.index or st.append or (not st.arith and not (st.rhs and numeric_word(st.rhs))) then
					disq[st.name] = true
				end
			elseif t == "arrayassign" then
				disq[st.name] = true
			elseif t == "simple" then
				local cmd = st.words[1] and st.words[1].parts[1] and st.words[1].parts[1].lit
				if cmd == "local" or cmd == "readonly" or cmd == "declare" or cmd == "typeset"
					or cmd == "export" or cmd == "unset" then
					for j = 2, #st.words do
						local p1 = st.words[j].parts[1]
						local nm = p1 and p1.lit and p1.lit:match("^([%a_][%w_]*)")
						if nm then disq[nm] = true end
					end
				end
			elseif t == "forin" then
				disq[st.name] = true
				disq_scan(st.body)
			elseif t == "pipeline" then
				disq_scan(st.cmds)
			elseif t == "andor" then
				for _, it in ipairs(st.items) do disq_scan({ it.cmd }) end
			elseif t == "if" then
				for _, cl in ipairs(st.clauses) do disq_scan(cl.cond); disq_scan(cl.body) end
			elseif t == "case" then
				for _, cl in ipairs(st.clauses) do disq_scan(cl.body) end
			elseif st.body then
				disq_scan(st.body)
			end
		end
	end
	local function scan(stmts)
		for _, st in ipairs(stmts) do
			if st.t == "assign" then
				assigned[st.name] = true
				-- an INDEXED assign (`a[i]=…`) makes an ARRAY: never int64-lift it (a native
				-- scalar can't hold an array, and the delegated array ops read sh.vars). A scalar
				-- `name+=v` is STRING concatenation (not arith), so it can produce a non-numeric
				-- value and its rt.append_scalar reads sh.vars — never lift an appended var either.
				if st.index or st.append or (not st.arith and not (st.rhs and numeric_word(st.rhs))) then
					disq[st.name] = true
				end
			elseif st.t == "arrayassign" then
				disq[st.name] = true -- `a=(…)` array literal
			elseif st.t == "simple" then
				local cmd = st.words[1] and st.words[1].parts[1] and st.words[1].parts[1].lit
				if cmd == "local" then
					for j = 2, #st.words do
						local p1 = st.words[j].parts[1]
						local nm = p1 and p1.lit and p1.lit:match("^([%a_][%w_]*)")
						if nm then
							localed[nm] = true
						end
					end
				elseif
					cmd == "readonly"
					or cmd == "declare"
					or cmd == "typeset"
					or cmd == "export"
					or cmd == "unset"
				then
					-- these delegated builtins manage the var's BOX + attributes (ro/integer/
					-- exported) in sh.vars; a native-int64 local would desync, so never lift.
					for j = 2, #st.words do
						local p1 = st.words[j].parts[1]
						local nm = p1 and p1.lit and p1.lit:match("^([%a_][%w_]*)")
						if nm then
							disq[nm] = true
						end
					end
				end
			elseif st.t == "forc" or st.t == "whilec" then
				for _, e in ipairs({ st.init, cond_arith(st.cond), st.step }) do
					if e and (e.k == "asgn" or e.k == "post" or e.k == "pre") then
						assigned[e.name] = true
					end
				end
				scan(st.body)
			elseif st.t == "forin" then
				disq[st.name] = true -- a `for x in` var holds arbitrary strings, never lift it
				scan(st.body)
			elseif st.t == "if" then
				for _, cl in ipairs(st.clauses) do
					scan(cl.body)
				end
			elseif st.t == "case" then -- (disqualify only: a non-numeric `x=…` in a clause
				for _, cl in ipairs(st.clauses) do -- keeps x off the lift set)
					disq_scan(cl.body)
				end
			elseif st.t == "andor" then
				for _, it in ipairs(st.items) do
					disq_scan({ it.cmd })
				end
			elseif st.t == "pipeline" then
				disq_scan(st.cmds) -- (stages are subshells: their assignments don't lift anything)
			elseif st.t == "funcdef" then
				scan(st.body)
			elseif st.t == "subshell" or st.t == "group" then
				disq_scan(st.body) -- in-process subshell: disqualify vars it unset/attributes
			end
		end
	end
	scan(ast.stmts)
	for n in pairs(NO_LIFT) do
		disq[n] = true
	end
	-- Arithmetic TEXT the runtime evaluates on sh.vars (array subscripts, substring offsets,
	-- `a[i]=` indices): a name in it is read — and may be written (`${a[n++]}`) — there,
	-- behind any native local. Every identifier in such text stays in sh.
	local function disq_text(t) -- (only text that can WRITE: ++, --, an assignment operator)
		if type(t) == "string" and (t:find("++", 1, true) or t:find("--", 1, true)
			or t:gsub("[=!<>]=", ""):find("=", 1, true) or t:find("[$`]")) then
			for nm in t:gmatch("[%a_][%w_]*") do
				disq[nm] = true
			end
		end
	end
	any_node(ast.stmts, function(n)
		if n.t == "assign" or n.t == "arrayassign" then
			disq_text(n.index)
		end
		if n.pexp then
			disq_text(n.pexp.index)
			if n.pexp.op == "sub" then
				disq_text(n.pexp.arg)
				disq_text(n.pexp.arg2)
			end
		end
		if n.key ~= nil then -- (an array literal's `[k]=` element)
			disq_text(n.key)
		end
		return false
	end)
	-- A trap's action runs through the interpreter, on sh.vars, at points the compiled code
	-- can't see (a signal mid-loop, DEBUG/ERR per command): whatever it names can't live in
	-- a native local. An action that isn't a literal could name anything: lift nothing.
	local trap_opaque = false
	any_node(ast.stmts, function(st)
		local w1 = st.t == "simple" and st.words and st.words[1]
		if w1 and full_lit(w1) == "trap" then
			local j = 2
			while st.words[j] and (full_lit(st.words[j]) or ""):match("^%-") do
				j = j + 1
			end
			local act = st.words[j] and full_lit(st.words[j])
			if st.words[j] and not act then
				trap_opaque = true
			elseif act and act ~= "" and act ~= "-" then
				local ok, tast = pcall(require("parser").parse, act)
				if ok and tast and tast.stmts then
					local names = {}
					collect_names(tast.stmts, names)
					-- (it calls one of the program's functions: count every function body's
					-- variables — they call each other freely)
					if any_node(tast.stmts, function(n)
						local c = n.t == "simple" and n.words and n.words[1] and full_lit(n.words[1])
						return c and any_node(ast.stmts, function(d)
							return d.t == "funcdef" and d.name == c
						end)
					end) then
						any_node(ast.stmts, function(d)
							if d.t == "funcdef" then
								collect_names(d.body, names)
							end
							return false
						end)
					end
					for nm in pairs(names) do
						disq[nm] = true
					end
					if any_node(tast.stmts, function(n)
						local c = n.t == "simple" and n.words and n.words[1] and full_lit(n.words[1])
						return c == "eval" or c == "source" or c == "." or (n.t == "simple" and n.words and n.words[1] and not c)
					end) then
						trap_opaque = true -- (it runs code it names only at runtime)
					end
				else
					trap_opaque = true
				end
			end
		end
		return false
	end)
	if trap_opaque then
		for nm in pairs(assigned) do
			disq[nm] = true
		end
	end
	-- `var=x return` / `var=x :` on a special builtin: under posix the assignment persists,
	-- written by the interpreter (delegated) — keep those vars in sh.vars
	local SPB = require("interp")._int.SPECIAL_BUILTIN
	local function spb_walk(node)
		if type(node) ~= "table" then
			return
		end
		if node.t == "simple" and node.words then
			writer_disq(node)
		elseif node.t == "select" and node.name then
			disq[node.name] = true
		end
		if node.t == "simple" and node.assigns and node.words and node.words[1] then
			local p1 = node.words[1].parts and node.words[1].parts[1]
			if p1 and p1.lit and SPB[p1.lit] then
				for _, a in ipairs(node.assigns) do
					if a.name then
						disq[a.name] = true
					end
				end
			end
		end
		for _, v in pairs(node) do
			if type(v) == "table" then
				spb_walk(v)
			end
		end
	end
	spb_walk(ast.stmts)
	-- A lifted var is a native int64 that can't be UNSET, so it must never be observed
	-- before its first assignment (`if …; then e=1; fi; echo "$e"` would print 0). Lift only
	-- a var whose FIRST mention in program order is an unconditional top-level numeric
	-- assignment (or a `for ((v=…` initializer): it is always set before anything reads it.
	local function mentions(node, nm, seen)
		if type(node) == "string" then
			return node:find("%f[%w_]" .. nm .. "%f[^%w_]") ~= nil
		end
		if type(node) ~= "table" or seen[node] then
			return false
		end
		seen[node] = true
		for _, v in pairs(node) do
			if mentions(v, nm, seen) then
				return true
			end
		end
		return false
	end
	-- In program order within `stmts`: "set" if nm is unconditionally assigned before any
	-- other mention, "bad" if mentioned first some other way, nil if not mentioned. A
	-- function definition is fine to pass over when its OWN body sets nm first (every call
	-- assigns before reading); a body that reads first makes the var unliftable.
	local function first_use(stmts, nm)
		for _, st in ipairs(stmts) do
			if st.t == "assign" and st.name == nm and not st.index then
				return "set" -- (numeric: anything else was disqualified above)
			end
			if st.t == "forc" and st.init and st.init.k == "asgn" and st.init.name == nm then
				return "set"
			end
			if st.t == "funcdef" then
				if mentions(st.body, nm, {}) and first_use(st.body, nm) ~= "set" then
					return "bad"
				end
			elseif mentions(st, nm, {}) then
				return "bad"
			end
		end
		return nil
	end
	local lifted = {}
	for n in pairs(assigned) do
		if not disq[n] and not localed[n] and first_use(ast.stmts, n) ~= "bad" then
			lifted[n] = true
		end
	end
	return lifted, disq, localed
end

-- A function's own integer locals, lifted into registers of its compiled body: the names
-- its LEADING `local NAME=INT` statements declare, when nothing else could see them in sh —
-- dynamic scoping lets a callee read a caller's locals, so the body may call no user
-- function (nor anything that runs code or names variables at runtime: eval/source/trap/
-- declare/set/…, a dynamic command word, ${!ref}) and hold no subshell/redirected compound;
-- and they must pass the same lift analysis as any var (numeric-only assignments, no
-- writer builtins, …). Pipelines/$(…)/delegated statements flush and reload them.
local FL_REJECT = { eval = 1, source = 1, ["."] = 1, trap = 1, declare = 1, typeset = 1, export = 1,
	readonly = 1, unset = 1, set = 1, ["local"] = 1, compgen = 1, exec = 1, command = 1, builtin = 1,
	shopt = 1, enable = 1, alias = 1, unalias = 1, hash = 1, type = 1 }
function func_locals(fst, funcflags)
	local body, names, k = fst.body, {}, 1
	while body[k] and body[k].t == "simple" and not body[k].redirs and not body[k].assigns do
		local w1 = body[k].words and body[k].words[1]
		if not (w1 and full_lit(w1) == "local") then
			break
		end
		for j = 2, #body[k].words do
			-- (canonical decimal only: `local v=010` must keep its text — `$v` is 010, not 8)
			local nm, v = (full_lit(body[k].words[j]) or ""):match("^([%a_][%w_]*)=(%-?%d+)$")
			if nm and #v < 16 and (v == "0" or v:match("^%-?[1-9]%d*$")) then
				names[#names + 1] = nm
			end
		end
		k = k + 1
	end
	if #names == 0 then
		return {}
	end
	local rest = {}
	for i = k, #body do
		rest[#rest + 1] = body[i]
	end
	local bad = any_node(rest, function(n)
		if n.t == "subshell" or n.t == "funcdef" or n.t == "coproc" or n.procsub then
			return true
		end
		if n.t ~= "simple" and n.redirs then
			return true -- (a redirected compound)
		end
		if n.pexp and (n.pexp.op == "indirect" or n.pexp.op == "prefix") then
			return true
		end
		if n.t == "simple" and n.words and n.words[1] then
			local c = full_lit(n.words[1])
			if not c or FL_REJECT[c] or funcflags[c] then
				return true
			end
		end
		return false
	end)
	if bad then
		return {}
	end
	local _, disq = analyze_lift({ stmts = body })
	if not disq then
		return {}
	end
	local out = {}
	for _, nm in ipairs(names) do
		if not disq[nm] and not NO_LIFT[nm] and not (EF.ro_names and EF.ro_names[nm]) then
			out[#out + 1] = nm
		end
	end
	table.sort(out)
	return out
end
-- Names the program makes readonly anywhere: a `local` of one fails, so it never lifts.
local function readonly_names(stmts)
	local ro = {}
	any_node(stmts, function(n)
		local w = n.t == "simple" and n.words
		local c = w and w[1] and full_lit(w[1])
		if c == "readonly" or c == "declare" or c == "typeset" or c == "local" then
			local isro = c == "readonly"
			for j = 2, #w do
				local a = full_lit(w[j]) or ""
				if a:match("^%-[%a]*r") then
					isro = true
				end
			end
			if isro then
				for j = 2, #w do
					local nm = (full_lit(w[j]) or ""):match("^([%a_][%w_]*)")
					if nm then
						ro[nm] = true
					end
				end
			end
		end
		return false
	end)
	return ro
end
EF.readonly_names = readonly_names

-- Does a function need a positional-param swap / a `local` frame? A call to a
-- function that needs neither is emitted bare (fn_x(sh)); one that needs only
-- params uses the lightweight pushParams; only `local` needs the full frame.
local function scan_arith_param(e, f)
	if type(e) ~= "table" then
		return
	end
	if e.k == "param" then
		f.params = true
	end
	-- an embedded $-expansion (`$(( $* ))`, `$(( $1+1 ))`) is re-expanded at runtime and
	-- may reference the positional params — conservatively require the param swap.
	if e.k == "xpand" then
		f.params = true
	end
	scan_arith_param(e.e, f)
	scan_arith_param(e.l, f)
	scan_arith_param(e.r, f)
	scan_arith_param(e.c, f)
	scan_arith_param(e.a, f)
	scan_arith_param(e.b, f)
end
-- A ${…} operator on a POSITIONAL parameter (@, *, or a digit — ${*:1}, ${@//x/y},
-- ${1:-def}) reads the call's params exactly like a bare $@/$*/$n does. Missing this
-- (only bare $special was checked) made such a function dispatch WITHOUT the param
-- swap, so $* inside saw the caller's params: `f(){ echo ${*:1};}; f a b` printed "".
local function pexp_reads_params(pe)
	local n = pe and pe.name
	return n == "@" or n == "*" or (type(n) == "string" and n:match("^%d+$") ~= nil)
end
local function scan_word_param(w, f)
	for _, p in ipairs(w.parts) do
		if p.param or (p.special and p.special ~= "?") then
			f.params = true
		end -- $? is status, not $@
		if p.pexp and pexp_reads_params(p.pexp) then
			f.params = true
		end -- ${*:1}/${1:-x}
		if p.cmdsub then
			f.params = true
		end -- $(…) re-runs against the live frame; its $n/$* need the swap
		if p.arith then
			scan_arith_param(safe_arith(p.arith), f)
		end
	end
end
-- A REDIRECT target/word/heredoc-body is a raw source STRING (`> "$@"`, `>&$1`),
-- not a word AST — but it too can reference positional params, so a function whose
-- ONLY use of $@/$n is in a redirect still needs the param swap (`f(){ echo x >"$@";}`
-- was dispatched bare → $@ empty → wrong/ambiguous redirect; `is_fd_open(){ :>&$1;}`
-- looped forever). Match $@ $* $# $n (optional brace) and any $(…)/`…` command sub.
local function str_reads_params(s)
	if type(s) ~= "string" then
		return false
	end
	return s:find("%$%{?[@*#0-9]") ~= nil or s:find("%$%(") ~= nil or s:find("`") ~= nil
end
local function scan_redir_params(st, f)
	if not st.redirs then
		return
	end
	for _, r in ipairs(st.redirs) do
		if str_reads_params(r.target) or str_reads_params(r.word) or (r.expand and str_reads_params(r.body)) then
			f.params = true
		end
	end
end
-- Walk a [[ … ]] expression tree for $@/$n operands: `and`/`or`/`not` nodes recurse
-- through l/r/e; a `binary` leaf's l/r are WORDS; a `unary` leaf's operand is .word.
-- A function whose only param use is inside [[ ]] (`f(){ [[ -n "$1" ]]; }`) was
-- dispatched bare, so $1 read empty.
local function scan_dbracket(e, f)
	if type(e) ~= "table" then
		return
	end
	if e.parts then
		scan_word_param(e, f)
		return
	end -- a word operand
	if e.word then
		scan_word_param(e.word, f)
	end -- unary operand
	scan_dbracket(e.l, f)
	scan_dbracket(e.r, f)
	scan_dbracket(e.e, f)
end
local function func_flags(body)
	local f = { params = false, locals = false }
	-- Every node, at any depth (&&/|| lists, pipelines, `&` jobs, array literals, (( )),
	-- heredoc/redirect targets …): a miss here calls the function WITHOUT its arguments.
	any_node(body, function(st)
		if st.t then
			scan_redir_params(st, f) -- $@/$n in any redirect target also needs the frame
		end
		if st.t == "simple" then
			local cmd = st.words and st.words[1] and st.words[1].parts[1] and st.words[1].parts[1].lit
			-- declare/typeset inside a function make their names LOCAL (bash), like `local`,
			-- so the call needs a real frame (pushCall) — else a delegated `declare x=1`
			-- writes the GLOBAL. `declare -g` still targets the global (interp honors -g
			-- inside the frame), so treating any declare/typeset as frame-needing is safe.
			if cmd == "local" or cmd == "declare" or cmd == "typeset" then
				f.locals = true
			end
			-- getopts parses $@ and shift mutates it — both implicitly need the callee's
			-- positional params (no $-word to trigger scan_word_param), so force the swap.
			if cmd == "getopts" or cmd == "shift" then
				f.params = true
			end
			-- eval / source / . run an OPAQUE string (or file) against the live frame — it
			-- can reference $@/$n and declare locals (`eval 'local v=$*'`), which the scan
			-- can't see, so conservatively give the callee a full frame (params + locals).
			if cmd == "eval" or cmd == "source" or cmd == "." then
				f.params = true
				f.locals = true
			end
		elseif st.t == "dbracket" then
			scan_dbracket(st.expr, f) -- $@/$n inside [[ … ]]
		elseif st.parts ~= nil and st.t == nil then -- a word
			scan_word_param(st, f)
		elseif st.k ~= nil then -- an arith node ((( … )), x=$(( … )), for (( … )))
			scan_arith_param(st, f)
		end
		return false -- (keep walking)
	end)
	return f
end

-- A function is INLINABLE if its body is flat (only assignments and
-- echo/:/true/false) — no control flow, calls, `return`, or `local`. Such a
-- function is spliced into its direct call sites (params bound directly, no call,
-- no string round-trip), which also lets its shared vars collapse to run-locals.
local function word_varargs(w) -- word that blocks inlining
	for _, p in ipairs(w.parts) do
		-- $@ / $* / $# need a real param array (inlining has no call frame)…
		if p.special and (p.special == "@" or p.special == "*" or p.special == "#") then
			return true
		end
		-- …a ${…} op on a positional param (${*:1}/${1:-x}) is delegated verbatim and
		-- would read the inline SITE's params, not the callee's — don't inline it…
		if p.pexp and pexp_reads_params(p.pexp) then
			return true
		end
		-- …and $( … ) is opaque source re-run against the live frame, so its inner
		-- $n would see the caller's params, not the inlined ones — don't inline it.
		if p.cmdsub then
			return true
		end
	end
	return false
end
-- An arith node is inline-substitutable only if subst_arith reaches every leaf that
-- could reference the caller. An `xpand` (embedded $-expansion, e.g. `$(( $* ))`) is
-- delegated verbatim and would re-read the INLINE SITE's sh.params/vars — never inline it.
local function arith_inlinable(e)
	if type(e) ~= "table" then
		return true
	end
	if e.k == "xpand" then
		return false
	end
	return arith_inlinable(e.e)
		and arith_inlinable(e.l)
		and arith_inlinable(e.r)
		and arith_inlinable(e.c)
		and arith_inlinable(e.a)
		and arith_inlinable(e.b)
end

local function inlinable_body(body)
	for _, st in ipairs(body) do
		-- A redirect whose target references params/cmdsub (`echo x > "$@"`, `: >&$1`)
		-- can't inline — spliced at the call site it would read the SITE's params, not
		-- the callee's (a static `> /tmp/f` redirect is fine and stays inlinable).
		if st.redirs then
			for _, r in ipairs(st.redirs) do
				if
					str_reads_params(r.target)
					or str_reads_params(r.word)
					or (r.expand and str_reads_params(r.body))
				then
					return false
				end
			end
		end
		if st.t == "assign" then
			if st.rhs and word_varargs(st.rhs) then
				return false
			end
			if st.arith and not arith_inlinable(st.arith) then
				return false
			end
		elseif st.t == "simple" then
			local cmd = st.words[1] and st.words[1].parts[1] and st.words[1].parts[1].lit
			if not (cmd == "echo" or cmd == ":" or cmd == "true" or cmd == "false") then
				return false
			end
			if cmd == ":" and st.assigns and #st.assigns > 0 then
				return false -- (`var=x :` — a special builtin's prefix assignment; see simple_compiled)
			end
			for j = 2, #st.words do
				if word_varargs(st.words[j]) then
					return false
				end
			end
		else
			return false
		end
	end
	return true
end

-- Substitute positional params ($n) with the caller's already-computed Lua exprs.
-- pb[n] = { int = <arith Lua expr>, str = <string Lua expr> }.
local function subst_arith(e, pb)
	if type(e) ~= "table" then
		return e
	end
	local k = e.k
	if k == "param" then -- unset positional inside the callee is 0 in arith
		return pb[e.n] and { k = "raw", code = pb[e.n].int } or { k = "num", v = "0" }
	end
	if k == "bin" then
		return { k = "bin", op = e.op, l = subst_arith(e.l, pb), r = subst_arith(e.r, pb) }
	end
	if k == "un" then
		return { k = "un", op = e.op, e = subst_arith(e.e, pb) }
	end
	if k == "asgn" then
		return { k = "asgn", name = e.name, op = e.op, e = subst_arith(e.e, pb) }
	end
	return e -- num, var, post, pre, raw
end
local function subst_word(w, pb)
	local parts = {}
	for _, p in ipairs(w.parts) do
		if p.param then
			parts[#parts + 1] = pb[p.param] and { raw = pb[p.param].str } or { lit = "" } -- unset positional = ""
		elseif p.arith then
			parts[#parts + 1] = { arithast = subst_arith(safe_arith(p.arith), pb) }
		else
			parts[#parts + 1] = p
		end
	end
	return { k = "word", parts = parts }
end
-- (each statement is COPIED with its params substituted — its redirects, prefix
-- assignments and line stay: inlinable_body admits only redirects that read no params)
local function subst_list(body, pb)
	local out = {}
	for _, st in ipairs(body) do
		local c = {}
		for k, v in pairs(st) do
			c[k] = v
		end
		if st.t == "assign" then
			if st.arith then
				c.arith = subst_arith(st.arith, pb)
			else
				c.rhs = subst_word(st.rhs, pb)
			end
		elseif st.t == "simple" then
			local words = {}
			for _, w in ipairs(st.words) do
				words[#words + 1] = subst_word(w, pb)
			end
			c.words = words
			if st.assigns then
				local as = {}
				for i, a in ipairs(st.assigns) do
					local a2 = {}
					for k, v in pairs(a) do
						a2[k] = v
					end
					if a.rhs then
						a2.rhs = subst_word(a.rhs, pb)
					end
					as[i] = a2
				end
				c.assigns = as
			end
		end
		out[#out + 1] = c
	end
	return out
end

-- Build a pc-dispatch CFG for a statement list. Shared by the top-level `run`
-- and every function body. `funcflags[name]` marks user functions (out-of-line
-- call), `inlinefns[name]` gives the body of an inlinable one (spliced in place).
-- Returns { blocks, npc, entry, loopPc, stmtPc, DONE }.
-- Per-statement-type compilers (flatten_stmt dispatches on st.t). Module-level: each takes
-- the per-CFG compile state `cx` (blocks/newpc/loopstack/lifted/delegate/flatten_*/…)
-- explicitly instead of closing over build_cfg.
local H = {}

-- statement handler: assign (split out of flatten_stmt; see H)
H.assign = function(cx, st, after)
	local t = st.t
	-- The program declares a nameref: a plain `name=value` may write THROUGH one
	-- (to a var / array or assoc element / a detected cycle) — only interp's full
	-- assign does that, so delegate. Gated to nameref programs (rare); ordinary
	-- assigns stay native (via rt.assign_scalar, which does the nameref write-through).
	-- A nameref ELEMENT/append/arith assign (ref[i]=, ref+=, ref=$((…))) needs interp's
	-- fuller handling, so delegate those; a plain scalar ref=value compiles.
	if EF.has_nameref and (st.index or st.append or st.arith) then
		if EF.fragment and not EF.frag_nameref and st.arith and not st.index and not st.append then
			-- a fragment only ASSUMES namerefs could exist: native when the var is a plain
			-- scalar at run time (rt.plain_scalar), else interp's full assign
			EF.has_nameref = false
			local ok, pn = pcall(H.assign, cx, st, after)
			EF.has_nameref = true
			if not ok then
				error(pn, 0)
			end
			local pd = cx.delegate(st, after)
			local pg = cx.newpc()
			cx.blocks[pg] = ("if rt.plain_scalar(sh, %q) then pc = %d else pc = %d end"):format(st.name, pn, pd)
			return pg
		end
		return cx.delegate(st, after)
	end
	-- Assigning these fires a side effect only interp's assign implements (resize
	-- history / truncate the histfile); a native set_str would skip it. Delegate.
	if not st.index and (st.name == "HISTSIZE" or st.name == "HISTFILESIZE") then
		return cx.delegate(st, after)
	end
	-- SHELLOPTS/BASHOPTS are readonly derived specials with no var box, so neither a
	-- bare native set nor I.assign_scalar rejects them. Always delegate so interp
	-- reports "readonly variable" (status 1), as bash does.
	if not st.index and (st.name == "SHELLOPTS" or st.name == "BASHOPTS") then
		return cx.delegate(st, after)
	end
	if (st.rhs and not emitable_word(st.rhs)) or (st.arith and arith_side_effect(st.arith)) then
		return cx.delegate(st, after)
	end
	-- a[i]=v / a[i]+=v: compile when the subscript is a non-empty emit_word-able word (rt
	-- .assign_element resolves it as an assoc key or an indexed arith at runtime). An empty
	-- or unrenderable subscript delegates. Gated to non-nameref programs (above) — a nameref
	-- element write needs interp.
	local iw
	if st.index then
		if st.index == "" then
			return cx.delegate(st, after)
		end
		local iok
		iok, iw = pcall(require("parser").parse_word, st.index)
		if not (iok and emitable_word(iw)) then
			return cx.delegate(st, after)
		end
		-- a cmdsub/procsub subscript is expanded once by emit_word AND (for indexed) arith-
		-- evaluated from the raw — two evals of a side-effecting sub. Delegate those.
		for _, pp in ipairs(iw.parts) do
			if pp.cmdsub or pp.procsub then
				return cx.delegate(st, after)
			end
		end
	end
	local p = cx.newpc()
	local d = dbg(st) -- DEBUG trap fires before the assignment (bash: DEBUG_FIRE.assign)
	-- assignment-RHS tilde (string paths only; st.rhs is nil for an arith assign): an
	-- ALL-LITERAL rhs containing ~ expands each `:`-segment (`x=foo:~` -> foo:$HOME).
	-- Only literal tildes expand — a ~ from a variable's value never does.
	local function rhsval()
		local fl = unq_full_lit(st.rhs)
		if fl and fl:find("~", 1, true) then
			return ("rt.tilde_assign(sh, %q)"):format(fl)
		end
		-- a MIXED rhs (`d=~:"q"~`): each unquoted literal gets the assignment tilde rule —
		-- its first segment continues the previous part, and a slash-less last segment
		-- runs into the next part (both stay literal)
		local np, tl = #st.rhs.parts, false
		for _, pp in ipairs(st.rhs.parts) do
			tl = tl or (pp.lit and not pp.q and pp.lit:find("~", 1, true))
		end
		if tl then
			local out = {}
			for i, pp in ipairs(st.rhs.parts) do
				if pp.lit and not pp.q and pp.lit:find("~", 1, true) then
					out[i] = ("rt.tilde_assign(sh, %q, %s, %s)"):format(pp.lit, tostring(i < np), tostring(i > 1))
				else
					out[i] = "(" .. emit_word({ parts = { pp } }, cx.lifted) .. ")"
				end
			end
			return table.concat(out, " .. ")
		end
		return emit_word(st.rhs, cx.lifted)
	end
	local ua = '; sh:set_str("_", "")' -- a bare assignment resets $_ (bash)
	if st.index then -- a[i]=v / a[i]+=v: status 0 first (so a plain RHS is 0; a cmdsub in the
		-- subscript/RHS overwrites it), then the element assign; assign_element leaves status.
		local ec = errchk(st)
		local ecs = ec ~= "" and ("; " .. ec) or ""
		local append = tostring(st.append and true or false)
		local expw = emit_word(iw, cx.lifted)
		-- Compute the INDEXED subscript key from lifted locals (arith_str(sh, raw) reads the STALE
		-- sh.vars copy, so `a[i]=…` in a `for ((;;))` loop mis-keyed every write). Decision hung on
		-- EF.elem_keyexpr so build_cfg (at the 60-upvalue cap) takes no new upvalue.
		local kmode, kstr = EF.elem_keyexpr(st, iw, cx.lifted)
		if kmode == "native" then -- a[i]/a[i+1]/a[3]: native key (reads lifted); assoc uses the raw subscript
			cx.blocks[p] = d
				.. ("sh.status = 0; if sh:is_assoc(%q) then rt.assign_element(sh, %q, %q, %s, %s, %s) else rt.assign_element_i(sh, %q, %s, %s, %s) end%s; pc = %d"):format(
					st.name, st.name, st.index, expw, rhsval(), append,
					st.name, kstr, rhsval(), append, ecs, after)
		elseif kmode == "xexp" then -- a[$i]: arith the natively-expanded (lifted-aware) VALUE
			cx.blocks[p] = d
				.. ("sh.status = 0; rt.assign_element_x(sh, %q, %s, %s, %s)%s; pc = %d"):format(
					st.name, expw, rhsval(), append, ecs, after)
		else -- literal non-arith (a[\'3\']) / non-lifted: the raw arith_str path (sh.vars authoritative)
			cx.blocks[p] = d
				.. ("sh.status = 0; rt.assign_element(sh, %q, %q, %s, %s, %s)%s; pc = %d"):format(
					st.name, st.index, expw, rhsval(), append, ecs, after)
		end
		return p
	end
	if st.append and not st.arith then -- scalar name+=value: rt.append_scalar picks concat /
		-- int arith-add / array[0]-append by the var's type at runtime (interp's append path).
		local ec = errchk(st)
		local ecs = ec ~= "" and ("; " .. ec) or ""
		cx.blocks[p] = d
			.. ("sh.status = 0; rt.append_scalar(sh, %q, %s)%s%s; pc = %d"):format(
				st.name,
				rhsval(),
				ecs,
				ua,
				after
			)
		return p
	end
	if st.arith then
		-- x=$((…)): a non-lifted read honors set -u and resolves recursively (bash),
		-- exactly as the $(())-in-word and (( )) paths do — swap in arith_read.
		local saved = arith_varread
		arith_varread = "rt.arith_read(sh, %q)"
		local rhs = emit_value(st.arith, cx.lifted)
		arith_varread = saved
		cx.blocks[p] = d .. emit_set(st.name, rhs, cx.lifted) .. "; sh.status = 0" .. ua .. ("; pc = %d"):format(after) -- pure arith (side-effecting delegates): $? = 0
	elseif cx.lifted[st.name] then
		-- a lifted RHS is a numeric literal (never a cmdsub), so $? resets to 0 like any
		-- plain assignment (`false; x=1; echo $?` -> 0) — the set_str path does this via st0.
		local ec = errchk(st)
		local ecs = ec ~= "" and ("; " .. ec) or ""
		cx.blocks[p] = d
			.. emit_set(st.name, numeric_word(st.rhs) .. "LL", cx.lifted)
			.. "; sh.status = 0"
			.. ecs
			.. ua
			.. ("; pc = %d"):format(after)
	elseif EF.has_attr or EF.has_nameref then -- readonly / array[0] / -i,-l,-u / nameref write-through
		-- status 0 first so a plain RHS yields 0 (a cmdsub RHS overwrites it), then
		-- assign_scalar (readonly reject + nameref/cycle/subscript write-through); errchk applies.
		local ec = errchk(st)
		local ecs = ec ~= "" and ("; " .. ec) or ""
		cx.blocks[p] = d
			.. ("sh.status = 0; rt.assign_scalar_x(sh, %q, %s)%s%s; pc = %d"):format(
				st.name,
				rhsval(),
				ecs,
				ua,
				after
			)
	else
		-- $? after a plain assignment: the RHS's last cmdsub status, else 0 — but the
		-- RHS is evaluated FIRST (so `st=$?` reads the PREVIOUS status), then reset to 0
		-- only when the RHS has no cmdsub; then errchk fires ERR/errexit (`x=$(false)`).
		local ec = errchk(st)
		local ecs = ec ~= "" and ("; " .. ec) or ""
		local hascmd = false
		if st.rhs then
			for _, pp in ipairs(st.rhs.parts) do
				if pp.cmdsub then
					hascmd = true
					break
				end
			end
		end
		local st0 = hascmd and "" or "; sh.status = 0"
		cx.blocks[p] = d .. ("sh:set_str(%q, %s)%s%s%s; pc = %d"):format(st.name, rhsval(), st0, ecs, ua, after)
	end
	return p
end

-- statement handler: funcdef (split out of flatten_stmt; see H)
H.funcdef = function(cx, st, after)
	local t = st.t
	-- Register the (hoisted) closure into sh.functions when the DEFINITION runs, not
	-- at load — so a function doesn't "exist" (declare -f / delegated call / prefix
	-- assign) before its def line (bash). Direct compiled calls use the hoisted local
	-- regardless. A nested funcdef (not in funcflags: inside `$( )`, `a && f(){…}`, a
	-- pipeline stage …) has no hoisted closure: interp defines it, when it runs.
	-- def-redirect and redefined funcs: interp registers the def (with func_redirs, or
	-- in program order for a redefinition) — the compiled fn_x can't represent either.
	if st.redirs or emit_redir_funcs[st.name] or not cx.funcflags[st.name] then
		return cx.delegate(st, after)
	end
	local p = cx.newpc()
	if not st.name:match("^[%w_:%.+@/%%%^~,!][%w_%.%-:+@/!#=%%%^~,]*$") then -- name is an expansion (`$foo-bar()`):
		cx.blocks[p] = ("io.stderr:write(%q); sh.status = 1; pc = %d") -- non-fatal runtime error (bash)
			:format("curse: `" .. st.name .. "': not a valid identifier\n", after)
	else
		cx.blocks[p] = (st.name:match("^[%a_][%w_]*$") and "" -- (posix: a non-identifier name is fatal)
			or ("if sh.opt_posix and not sh.opt_i then rt.err_at(sh, %s, %q); error({ __curse_exit = 2 }) end; ")
				:format(st.top and tostring(st.eline) or "nil", "curse: `" .. st.name .. "': not a valid identifier\n"))
			.. ("if sh.fn_ro and sh.fn_ro[%q] then rt.err_at(sh, %s, %q); sh.status = 1 else sh.functions[%q] = rt.mark_compiled(%s, %s) end; pc = %d"):format(
			st.name, st.top and tostring(st.eline) or "nil", "curse: " .. st.name .. ": readonly function\n", st.name, EF.upv_wrapped(fnlname(st.name)), fnlname(st.name), after)
	end
	return p
end

-- statement handler: simple (split out of flatten_stmt; see H)
-- In an eval/source program a command name can be (re)defined as a function at RUNTIME
-- (`eval 'true(){ …; }'`, a compiled function replaced by eval) — which the compiled call
-- (native builtin / direct fn_x / external spawn) wouldn't see. Guard each literal command:
-- still static (rt.names_static) -> the compiled code; else the interpreter's live dispatch.
local simple_compiled
H.simple = function(cx, st, after)
	local p = simple_compiled(cx, st, after)
	local w1 = EF.has_dyncode and st.words and st.words[1]
	local c = w1 and w1.parts and #w1.parts == 1 and w1.parts[1].lit
	if not c then
		return p
	end
	local dp = cx.delegate(st, after, { callee = "I.exec_stmt", callargs = ("sh, %s, __noop"):format(ser(st)) })
	local g = cx.newpc()
	cx.blocks[g] = ("if %s then pc = %d else pc = %d end"):format(names_guard({ c }), p, dp)
	return g
end
simple_compiled = function(cx, st, after)
	local t = st.t
	local cmd = st.words[1] and full_lit(st.words[1]) -- full literal → \-escaped builtins (\exit, \echo) dispatch
	-- `var=x return` / `var=x :` …: under set -o posix a special builtin's prefix
	-- assignments PERSIST — interp decides that at run time (opt_posix)
	if cmd and st.assigns and #st.assigns > 0 and require("interp")._int.SPECIAL_BUILTIN[cmd] then
		return cx.delegate(st, after)
	end
	if cmd and emit_redir_funcs[cmd] then
		return cx.delegate(st, after)
	end -- call to a def-redirect func
	-- `local a=(…)` / `declare a=(…)`: the array value lives in st.arrayargs, which
	-- the native builtin paths don't render — interp does the scope-aware array assign.
	if st.arrayargs then
		-- Native path: `declare`/`typeset`/`local NAME=(…)` whose flags are only -a/-A
		-- (indexed/assoc) and/or -r (readonly). Reproduces interp's declare array branch
		-- exactly: localVar for an in-function declaration (bash makes it local), then
		-- declare_assoc for the assoc attribute, then rt.arrayassign for the store (both
		-- key on is_assoc — the runtime twin of do_arrayassign), then readonly LAST. The
		-- element values build with the field engine — no exec_stmt. $_ becomes the target
		-- name (bash). Combos with -i/-x/-n/-g/-p/-l/-u, `export`/`readonly`, multiple
		-- targets, a redirect, or a nameref program keep interp's fuller declare handling.
		local aa = st.arrayargs
		local isassoc, isro, flagsok = false, false, true
		for j = 2, #st.words do
			local w = st.words[j]
			local lit = #w.parts == 1 and w.parts[1].lit
			if not (lit and #lit >= 2 and lit:sub(1, 1) == "-" and lit ~= "--") then
				flagsok = false -- a bare name / value word / `--` / combined non-flag: delegate
				break
			end
			for c in lit:sub(2):gmatch(".") do
				if c == "A" then
					isassoc = true
				elseif c == "r" then
					isro = true
				elseif c ~= "a" then -- -a is the indexed default; any other letter -> delegate
					flagsok = false
				end
			end
			if not flagsok then
				break
			end
		end
		local as_local = (cmd == "local") or ((cmd == "declare" or cmd == "typeset") and not cx.toplevel)
		if
			(cmd == "declare" or cmd == "typeset" or cmd == "local")
			and not (cmd == "local" and cx.toplevel) -- `local` outside a function is an error (interp)
			and not st.assigns
			and not (st.redirs and #st.redirs > 0) -- (a redirected one takes the general path)
			and #aa == 1
			and flagsok
			and arrayassign_ok({ name = aa[1].name, append = aa[1].append, elems = aa[1].elems }, cx.lifted, true)
		then
			local a1 = aa[1]
			local p = cx.newpc()
			local parts = { "local __it = {}" }
			for _, e in ipairs(a1.elems) do
				if e.key ~= nil then
					local fl = unq_full_lit(e.word)
					local valx = (fl and fl:find("~", 1, true)) and ("rt.tilde_assign(sh, %q)"):format(fl)
						or emit_word(e.word, cx.lifted)
					parts[#parts + 1] = ("__it[#__it+1] = {key=%q, op=%q, val=%s}"):format(EF.static_key(e.key), e.op, valx)
				elseif not empty_word(e.word) then
					-- an assoc's key/value words don't split or glob (see H.arrayassign)
					if isassoc then
						parts[#parts + 1] = ("__it[#__it+1] = {val=%s}"):format(emit_word(e.word, cx.lifted))
					else
						if not parts.asq then -- (asked once per statement)
							parts.asq = true
							parts[#parts + 1] = ("local __as = sh:is_assoc(%q)"):format(a1.name)
						end
						parts[#parts + 1] = ("if __as then __it[#__it+1] = {val=%s} else %s end"):format(
							emit_word(e.word, cx.lifted),
							emit_fields_into("__it", e.word, cx.lifted, "{val=%s}")
						)
					end
				end
			end
			local ec = errchk(st)
			local ecs = ec ~= "" and ("; " .. ec) or ""
			local pre = as_local and ("sh:localVar(%q); "):format(a1.name) or ""
			if isassoc then
				pre = pre .. ("sh:declare_assoc(%q); "):format(a1.name)
			end
			local ro = isro and ("; sh:mark_readonly(%q)"):format(a1.name) or ""
			cx.blocks[p] = dbg(st)
				-- bash forbids CHANGING an existing array's kind (-A on indexed / -a on assoc):
				-- status 1, and the RHS values are NOT evaluated (interp assigns the literal only
				-- when status==0). Gate the whole assign (values included) on the conversion check.
				.. ("do if not rt.array_convert_err(sh, %q, %s, %q)%s then "):format(
					a1.name,
					tostring(isassoc),
					cmd,
					as_local and (" and not rt.local_ro(sh, %q)"):format(a1.name) or ""
				)
				-- (the values are expanded BEFORE localizing: `local -a arr=("${arr[@]}")`)
				.. table.concat(parts, "; ")
				.. "; "
				.. pre -- (empty, or ends in "; ")
				.. ("rt.arrayassign(sh, %q, __it, %s)"):format(
					a1.name,
					tostring(a1.append and true or false)
				)
				.. ro
				.. " end end"
				.. ('; sh:set_str("_", %q)'):format(a1.name)
				.. ecs
				.. ("; pc = %d"):format(after)
			return p
		end
		return cx.delegate(st, after)
	end
	-- DYNAMIC command word (first word not a compile-time literal — `$cmd`, `${x}`, …):
	-- the command STRUCTURE is a static simple-command; only the word is late-bound. Build
	-- argv with the field engine and dispatch via rt.exec_dynamic (the command runner),
	-- reusing delegate's control-flow-signal wrapper. A prefix assign (tempenv) still needs
	-- exec_stmt's fuller handling; a redirect is applied around the dispatch (opts.redir).
	if cmd == nil and st.words[1] and not st.assigns then
		local argvbody = field_argv(st.words, 1, cx.lifted, nil, nil)
		local dyn_redir = nil
		if argvbody and st.redirs then
			dyn_redir = cx.redir_conds(st, nil) -- nil => uncompilable redir shape: fall through to full delegate
		end
		if argvbody and not (st.redirs and not dyn_redir) then
			-- hadcs (compile-time): a word contains a command sub, so an empty argv keeps its status.
			local hadcs = false
			for _, w in ipairs(st.words) do
				for _, pp in ipairs(w.parts) do
					if pp.cmdsub then
						hadcs = true
						break
					end
				end
				if hadcs then
					break
				end
			end
			return cx.delegate(
				st,
				after,
				{
					prelude = argvbody,
					callee = "rt.exec_dynamic",
					callargs = ("sh, __a, __noop, %s"):format(tostring(hadcs)),
					redir = dyn_redir,
				}
			)
		end
	end
	-- `command CMD args` (no -p/-v/-V/-- flag): run CMD skipping SHELL FUNCTION lookup
	-- (builtin/external only) — exactly interp's exec_simple(rest, no_func=true). Build argv
	-- from words[2..] and dispatch through rt.exec_dynamic with no_func, reusing delegate's
	-- cf-signal wrapper and opts.redir. A flag form (`command -v`, `command -p`) delegates.
	if cmd == "command" and st.words[2] and not st.assigns then
		local w2 = st.words[2].parts[1]
		-- `command -v/-V NAME…`: a pure lookup query (alias/keyword/builtin/function/PATH)
		-- -> rt.command_query, exactly interp's branch; no execution, so no exec_stmt.
		if w2 and #st.words[2].parts == 1 and (w2.lit == "-v" or w2.lit == "-V") and st.words[3] then
			local qbody = field_argv(st.words, 1, cx.lifted, nil, nil)
			local q_redir = nil
			if qbody and st.redirs then
				q_redir = cx.redir_conds(st, nil)
			end
			if qbody and not (st.redirs and not q_redir) then
				return cx.delegate(st, after, {
					prelude = qbody,
					callee = "rt.command_query",
					callargs = "sh, __a",
					redir = q_redir,
				})
			end
		end
		-- (`command exec >f`: exec's redirections persist — interp's exec branch handles it)
		if not (w2 and w2.lit and (w2.lit:sub(1, 1) == "-" or w2.lit == "exec")) then -- not a flag / --
			local argvbody = field_argv(st.words, 2, cx.lifted, nil, nil)
			local cmd_redir = nil
			if argvbody and st.redirs then
				cmd_redir = cx.redir_conds(st, nil)
			end
			if argvbody and not (st.redirs and not cmd_redir) then
				local hadcs = false
				for j = 2, #st.words do
					for _, pp in ipairs(st.words[j].parts) do
						if pp.cmdsub then
							hadcs = true
							break
						end
					end
					if hadcs then
						break
					end
				end
				return cx.delegate(
					st,
					after,
					{
						prelude = argvbody,
						callee = "rt.exec_dynamic",
						callargs = ("sh, __a, __noop, %s, true"):format(tostring(hadcs)),
						redir = cmd_redir,
					}
				)
			end
		end
	end
	-- `builtin CMD args`: force the shell BUILTIN for CMD (skip any function of that name).
	-- rt.exec_dynamic on the argv WITH "builtin" kept as argv[1] does exactly this — exec_simple
	-- resolves "builtin" to the b_builtin builtin, which force-runs the rest as a builtin —
	-- and reuses delegate's cf-signal wrapper (so `builtin break` in a loop jumps) + opts.redir.
	if cmd == "builtin" and st.words[2] and not st.assigns then
		local argvbody = field_argv(st.words, 1, cx.lifted, nil, nil)
		local bi_redir = nil
		if argvbody and st.redirs then
			bi_redir = cx.redir_conds(st, nil)
		end
		if argvbody and not (st.redirs and not bi_redir) then
			local hadcs = false
			for j = 2, #st.words do
				for _, pp in ipairs(st.words[j].parts) do
					if pp.cmdsub then
						hadcs = true
						break
					end
				end
				if hadcs then
					break
				end
			end
			return cx.delegate(
				st,
				after,
				{
					prelude = argvbody,
					callee = "rt.exec_dynamic",
					callargs = ("sh, __a, __noop, %s"):format(tostring(hadcs)),
					redir = bi_redir,
				}
			)
		end
	end
	-- `eval CODE…`: COMPILE the joined code at runtime (rt.eval, fragment mode) rather than
	-- exec_stmt-ing it — the args expand through the field engine here, and rt.eval tiers the
	-- resulting string (falling back to the interpreter for aliases / a syntax error / a
	-- construct emit still delegates). delegate's cf-wrapper catches a return/break/continue/
	-- exit the eval'd code raises; opts.redir applies a redirect around the call.
	if cmd == "eval" and not st.assigns then
		local argvbody = field_argv(st.words, 1, cx.lifted, nil, nil)
		local ev_redir = nil
		if argvbody and st.redirs then
			ev_redir = cx.redir_conds(st, nil)
		end
		if argvbody and not (st.redirs and not ev_redir) then
			return cx.delegate(st, after, {
				prelude = argvbody,
				callee = "rt.eval",
				callargs = "sh, __a",
				redir = ev_redir,
			})
		end
	end
	-- `source FILE`/`. FILE`: run the file in the current shell, COMPILED (rt.source) —
	-- same fragment mode as eval, plus positional-param setup and the RETURN trap; it
	-- falls back to the interpreter for a missing/dir file, aliases, or a syntax error.
	if (cmd == "source" or cmd == ".") and st.words[2] and not st.assigns then
		local argvbody = field_argv(st.words, 1, cx.lifted, nil, nil)
		local sr_redir = nil
		if argvbody and st.redirs then
			sr_redir = cx.redir_conds(st, nil)
		end
		if argvbody and not (st.redirs and not sr_redir) then
			return cx.delegate(st, after, {
				prelude = argvbody,
				callee = "rt.source",
				callargs = st.line and ("sh, __a, %d"):format(st.line) or "sh, __a", -- (its line: BASH_LINENO)
				redir = sr_redir,
			})
		end
	end
	-- `declare`/`typeset` INSIDE a function (no -g) make each name local, exactly like
	-- `local` (bash) — so route a plain one through the native local path. A flag (incl.
	-- -g), an array value (st.arrayargs delegated above), or `a[i]=` fails the plain check
	-- below and delegates, as for local. At the top level declare stays a global (decl_native).
	local as_local = cmd == "local" or ((cmd == "declare" or cmd == "typeset") and not cx.toplevel)
	-- The native `local` fast path (sh:localAssign) handles ONLY a plain scalar
	-- `local NAME[=val]`: it can't validate the name, honor a flag (-n/-A/-p), do
	-- an array element `a[i]=`, or LIST (bare `local`). Delegate anything else to
	-- interp's full `local`, which also errors a bad name and skips a readonly
	-- (matching bash). Done BEFORE the simple-stmt's newpc so no pc is orphaned.
	if cmd == "local" and cx.toplevel then -- (outside a function: interp's error — unless a
		return cx.delegate(st, after) -- function is sourcing this file)
	end
	if as_local then
		-- (readonly / set -a are handled per-name at runtime by sh:localAssign — a
		-- readonly operand fails with $?=1, a set -a local is exported — so no
		-- whole-program blanket is needed here.)
		local plain = #st.words >= 2
		-- declare/typeset (not `local`) whose operands are ONLY -flags and bare NAMEs
		-- (no `name=value`, no `a[i]=`, no expansion) route to the rt.builtin path
		-- below (decl_in_fn), which honors -p/-A/-i/… and localizes via a calldepth
		-- bump. `declare -pa`, `declare -A m`, `declare -i n` inside a function or a
		-- pipeline-stage fragment. `local` has no such native flag path, so it still
		-- delegates when not plain.
		local flagsonly = (cmd == "declare" or cmd == "typeset") and #st.words >= 2
		for j = 2, #st.words do
			local p1 = st.words[j].parts[1]
			local lit = p1 and p1.lit
			local single = #st.words[j].parts == 1
			if
				not (
					lit
					and (lit:match("^[%a_][%w_]*%+?=") or (lit:match("^[%a_][%w_]*$") and single))
				)
			then
				plain = false
			end
			if not (lit and single and (lit:match("^%-%a+$") or lit:match("^[%a_][%w_]*$"))) then
				flagsonly = false
			end
		end
		if not plain and not flagsonly then
			return cx.delegate(st, after)
		end
	end
	-- `unset map["$key"]`: the quoted subscript parts must not be expanded twice — interp's
	-- expand_args protects them (unset_arrayref); delegate rather than duplicate that
	if cmd == "unset" then
		for j = 2, #st.words do
			local ps = st.words[j].parts
			if ps[1] and ps[1].lit and not ps[1].q and ps[1].lit:match("^[%a_][%w_]*%[") then
				for k = 2, #ps do
					if ps[k].q then
						return cx.delegate(st, after)
					end
				end
			end
		end
	end
	-- `exec` with ONLY redirects and no command word (`exec > log`, `exec 3< f`,
	-- `exec 2>&1`): a PERSISTENT redirect — apply the redirs to the shell's own fds and do
	-- NOT restore (they outlive the statement), status 0 / 1 on failure, exactly interp's
	-- exec path. `exec cmd…` (process replacement) and an uncompilable redir shape delegate.
	if cmd == "exec" and #st.words == 1 and st.redirs and not st.assigns then
		local re = cx.redir_conds(st, nil) -- nil cmd bypasses the exec guard in redir_conds
		if re then
			local p = cx.newpc()
			cx.blocks[p] = dbg(st)
				.. ("do rt.iso_save_fds(sh); local __rs = {}; sh.status = (%s) and 0 or 1; rt.redir_discard(__rs); if sh.coprocs then rt.coproc_fdcheck(sh) end end; pc = %d"):format(re, after)
			return p
		end
	end
	-- redirects compile (targets computed natively, syscalls via rt.redir_apply)
	-- when every one is compilable AND this isn't `exec` (its redirs persist);
	-- otherwise the whole command delegates.
	local redir_apply = nil
	if st.redirs then
		redir_apply = cx.redir_conds(st, cmd)
		if not redir_apply then
			return cx.delegate(st, after)
		end
	end
	-- a redirect-ONLY command (`> file`, `< f`): no command runs; apply the redirs
	-- (their open/truncate is the effect), status 0 (or 1 on failure), then restore.
	-- BUT a prefix assignment with no command (`abc=def > f`) performs the assignment
	-- in the current shell EVEN when the redirect fails — the native path here would
	-- drop it, so delegate to interp, which applies the assignment then the redirect.
	if not st.words[1] then
		if st.assigns then
			return cx.delegate(st, after)
		end
		local p = cx.newpc()
		cx.blocks[p] = dbg(st)
			.. ("do local __rs = {}; sh.status = %s and 0 or 1; rt.redir_restore(__rs) end; pc = %d"):format(
				redir_apply,
				after
			)
		return p
	end
	-- delegate if it needs the field engine (splitting/glob/pexp), or a builtin
	-- without a native compiled form.
	local NATIVE_BUILTIN = {
		echo = 1,
		[":"] = 1,
		["true"] = 1,
		["false"] = 1,
		["local"] = 1,
		["return"] = 1,
		test = 1,
		["["] = 1,
	}
	local isfunc = (cx.inlinefns and cx.inlinefns[cmd]) or cx.funcflags[cmd]
	if cmd == "return" and redir_apply then
		return cx.delegate(st, after)
	end -- rare; wrapper assumes a run body
	-- Simple interp-only builtins (printf/set/shopt/umask/type/read/getopts/…): build
	-- argv with the shared field engine and dispatch through exec_simple — the command
	-- RUNNER, not statement re-interpretation. EXCLUDED (they need exec_stmt's fuller
	-- handling, compiled separately): assignment builtins whose `name=val` args must NOT
	-- word-split (export/declare/readonly/local/typeset), code/control-flow builtins
	-- (eval/source/./command/builtin/exit/return/break/continue). exec_stmt sets $_ to
	-- the last arg; replicate that. Prefix-env (`x=v cmd`) keeps interp's tempenv binding.
	-- `wait` needs interp's job-control context, so it still delegates. A REDIRECTED builtin
	-- IS compiled below (install redirs, run, flush-before-restore, honor a flagged write error).
	local EXEC_SIMPLE_SKIP = {
		export = 1,
		declare = 1,
		readonly = 1,
		["local"] = 1,
		typeset = 1,
		eval = 1,
		source = 1,
		["."] = 1,
		command = 1,
		builtin = 1,
		exit = 1,
		["return"] = 1,
		["break"] = 1,
		["continue"] = 1,
		exec = 1,
		wait = 1,
	}
	-- Declaration builtins normally delegate because a LITERAL `name=value` arg must
	-- expand its value in assignment context (no word-split/glob, tilde after =) —
	-- which this field path can't do. But when NO arg is a literal assignment (only
	-- flags and bare names: `export FOO`, `readonly -p`, `declare -A m`, `declare -f`),
	-- their args split like any builtin's, so run them natively via rt.builtin. A
	-- `name=value` written in source, an array value (st.arrayargs), or `a[i]=` still
	-- delegates. (`$x` that expands to `name=value` is a normal split arg the builtin
	-- assigns — that is correct here, matching bash.)
	-- Only at top level: inside a function, declare/typeset (and a bare name) DEFAULT
	-- to a LOCAL, which needs the function-scope context the delegation path sets up
	-- but rt.builtin does not — so an in-function `declare -A d` would leak to global.
	-- At top level there is no local scope, so the native dispatch is exact.
	local DECL_BUILTIN = { export = 1, declare = 1, readonly = 1, typeset = 1 }
	-- declare/typeset ALSO compile inside a function (no array value, no `name=value`
	-- literal below): b_export makes each name local when sh.calldepth>0, which the
	-- dispatch bumps to 1 (matching the delegate's calldepth guard). The frame itself
	-- is pushed by the caller — func_flags marks any declare/typeset body `locals`.
	-- decl_in_fn: a flagged declare/typeset in a function/fragment LOCALIZES each name, so the
	-- dispatch bumps calldepth. decl_list: export/readonly (which NEVER localize) and a bare
	-- `declare`/`typeset` LISTING (no operands) — pure query/global ops safe via rt.builtin in
	-- any context, no bump. A `name=value` literal still delegates (handled below / literal path).
	local decl_in_fn = false
	local decl_list = false
	if not cx.toplevel and not st.arrayargs then
		if cmd == "export" or cmd == "readonly" then
			decl_list = true
		elseif (cmd == "declare" or cmd == "typeset") and #st.words == 1 then
			decl_list = true -- bare `declare`/`typeset`: list variables, no name to localize
		elseif cmd == "declare" or cmd == "typeset" then
			for j = 2, #st.words do
				local p1 = st.words[j].parts[1]
				if p1 and p1.lit and p1.lit:match("^%-%a") then
					decl_in_fn = true
					break
				end
			end
		end
	end
	local decl_native = (DECL_BUILTIN[cmd] and cx.toplevel and not st.arrayargs) or decl_in_fn or decl_list
	if decl_native then
		for j = 2, #st.words do
			local p1 = st.words[j].parts[1]
			local lit = p1 and p1.lit
			if lit and (lit:match("^[%a_][%w_]*%+?=") or lit:match("^[%a_][%w_]*%b[]%+?=")) then
				decl_native = false
				decl_in_fn = false
				decl_list = false
				break
			end
		end
	end
	-- Top-level declaration builtin WITH a literal `name=value` arg (`export FOO=bar`,
	-- `declare -i n=5`, `export PATH=$PATH:/x`): build argv statically, expanding each
	-- assignment value in assignment context — no word-split (emit_word renders the
	-- whole `name=value` word to a single field), and tilde after `=`/`:` via
	-- rt.tilde_assign for an all-literal value. b_export then does attribute processing
	-- (arith for -i, etc.) on the expanded string. Defers to delegation for an array
	-- element `a[i]=`, a value with a literal ~ mixed with expansions (needs the
	-- assign-context tilde engine), or a splitting/unrenderable non-assignment arg.
	if
		DECL_BUILTIN[cmd]
		and cx.toplevel
		and not st.arrayargs
		and not decl_native
		and cmd
		and st.assigns == nil
		and not redir_apply
		and not isfunc
	then
		local items, ok = {}, true
		for j = 1, #st.words do
			local w = st.words[j]
			local p1 = w.parts[1]
			local lit = p1 and p1.lit
			if j > 1 and lit and lit:match("^[%a_][%w_]*%b[]") then
				ok = false
				break -- a[i]=/a[i]
			elseif j > 1 and lit and lit:match("^[%a_][%w_]*%+?=") then -- scalar assignment
				local pfx = lit:match("^([%a_][%w_]*%+?=)")
				local fl = unq_full_lit(w)
				if fl then -- all-literal name=value
					if fl:find("~", 1, true) then
						items[#items + 1] = ("rt.cstr(%q .. rt.tilde_assign(sh, %q))"):format(
							pfx,
							fl:sub(#pfx + 1)
						)
					else
						items[#items + 1] = ("rt.cstr(%q)"):format(fl)
					end
				else -- value has expansions: emit_word renders name=value (no split); a
					local htilde = false -- literal ~ mixed in needs the assign-tilde engine → defer
					for _, pp in ipairs(w.parts) do
						if pp.lit and pp.lit:find("~", 1, true) then
							htilde = true
							break
						end
					end
					if htilde or not emitable_word(w) then
						ok = false
						break
					end
					items[#items + 1] = ("rt.cstr(%s)"):format(emit_word(w, cx.lifted))
				end
			else -- command word / flag / bare name: must not need the field engine
				if not word_safe(w) then
					ok = false
					break
				end
				items[#items + 1] = ("rt.cstr(%s)"):format(emit_word(w, cx.lifted))
			end
		end
		if ok then
			local p = cx.newpc()
			local ec = errchk(st)
			local ecs = ec ~= "" and ("; " .. ec) or ""
			local d = dbg(st)
			local lastarg = "if #__a > 0 then sh:set_str('_', __a[#__a]) end"
			cx.blocks[p] = d
				.. ("local __a = { %s }; rt.builtin(sh, __a, __noop); "):format(table.concat(items, ", "))
				.. lastarg
				.. ecs
				.. ("; pc = %d"):format(after)
			return p
		end
	end
	-- `VAR=val … cmd args` (prefix env): evaluate each scalar prefix value in the
	-- CURRENT env (bash/interp agree a sibling prefix isn't visible, and the args also
	-- expand pre-prefix), then apply them as an exported tempenv via rt.run_prefix, run
	-- the command (a builtin sees the temp values, e.g. `IFS=: read`; a forked external
	-- inherits them via the setenv, e.g. `MSG=hi sh -c …`), and restore. Handles a
	-- static BUILTIN or a static EXTERNAL name; the code/scope builtins (EXEC_SIMPLE_SKIP:
	-- eval/declare/local/…), the statically-native ones (NATIVE_BUILTIN: echo/[/:/…), a
	-- function, and a dynamic command word keep interp's fuller prefix handling. An
	-- array-element/array-literal/append prefix, or an unrenderable value/argv, delegates.
	local px_builtin = cmd and require("interp").BUILTINS[cmd]
	local px_external = cmd
		and not px_builtin
		and not (cx.inlinefns and cx.inlinefns[cmd])
		and not cx.funcflags[cmd]
	if
		st.assigns
		and cmd
		and not NATIVE_BUILTIN[cmd]
		and not EXEC_SIMPLE_SKIP[cmd]
		and not isfunc
		and (px_builtin or px_external)
	then
		local pnames, pvals, pok = {}, {}, true
		for _, a in ipairs(st.assigns) do
			if a.index or a.raw or a.append or not a.rhs or not emitable_word(a.rhs) then
				pok = false
				break
			end
			pnames[#pnames + 1] = ("%q"):format(a.name)
			-- assignment-context value: an all-literal ~ colon-expands (rt.tilde_assign),
			-- else the ordinary word value (no split — assignment RHS).
			local fl = unq_full_lit(a.rhs)
			pvals[#pvals + 1] = (fl and fl:find("~", 1, true)) and ("rt.tilde_assign(sh, %q)"):format(fl)
				or emit_word(a.rhs, cx.lifted)
		end
		local builder = pok and field_argv(st.words, 1, cx.lifted, "rt.cstr(%s)")
		if pok and builder then
			local p = cx.newpc()
			local ec = errchk(st)
			local ecs = ec ~= "" and ("; " .. ec) or ""
			local d = dbg(st)
			local lastarg = "if #__a > 0 then sh:set_str('_', __a[#__a]) end"
			local run = px_builtin and "rt.builtin(sh, __a, __noop)" or "sh:exec(unpack(__a))"
			local dispatch
			if not redir_apply then
				dispatch = run
			elseif px_builtin then -- a builtin's buffered output must reach the target fd before restore
				dispatch = ("do local __rs = {}; if %s then sh.write_err = nil; %s; io.flush() else sh.status = 1 end; rt.redir_restore(__rs); if sh.write_err then sh.status = 1 end end"):format(
					redir_apply,
					run
				)
			else -- external: it runs with its own fds, a failed redirect is $?=1
				dispatch = ("do local __rs = {}; if %s then %s else sh.status = 1 end; rt.redir_restore(__rs) end"):format(
					redir_apply,
					run
				)
			end
			-- __pv (prefix values) FIRST, then __a (argv) — both in the pre-prefix env,
			-- in bash's left-to-right order — then apply + run + restore via rt.run_prefix.
			cx.blocks[p] = d
				.. ("local __pv = { %s }; "):format(table.concat(pvals, ", "))
				.. builder
				.. ("; rt.run_prefix(sh, { %s }, __pv, function() %s end); "):format(
					table.concat(pnames, ", "),
					dispatch
				)
				.. lastarg
				.. ecs
				.. ("; pc = %d"):format(after)
			return p
		end
	end
	if
		cmd
		and st.assigns == nil
		and not NATIVE_BUILTIN[cmd]
		and not isfunc
		and (not EXEC_SIMPLE_SKIP[cmd] or decl_native)
		and require("interp").BUILTINS[cmd]
	then
		local builder = field_argv(st.words, 1, cx.lifted, "rt.cstr(%s)") -- argv entries are C strings (cut at NUL, like interp's expand_args)
		if builder then
			local p = cx.newpc()
			local ec = errchk(st)
			local ecs = ec ~= "" and ("; " .. ec) or ""
			local d = dbg(st) -- DEBUG fires before the command and its expansions
			local lastarg = "if #__a > 0 then sh:set_str('_', __a[#__a]) end" -- $_ = last arg (bash)
			-- In-function declare/typeset: bump calldepth (save/restore) so b_export
			-- localizes each name, exactly as the delegate's cf-wrapper does. Elsewhere
			-- (top level, other builtins) this is a plain dispatch.
			local bcall = (decl_in_fn or (not cx.toplevel and (cmd == "command" or cmd == "builtin")))
					and "do local __sc = sh.calldepth; if (sh.calldepth or 0) < 1 then sh.calldepth = 1 end; rt.builtin(sh, __a, __noop); sh.calldepth = __sc end"
				or "rt.builtin(sh, __a, __noop)"
			if redir_apply then
				-- a REDIRECTED builtin (`printf x > f`, `read v < f`, `type ls > f`): install the
				-- redirs, run it (its output/input now on the target fd), then io.flush BEFORE
				-- restoring — buffered output must reach the target fd, not the restored one
				-- (interp flushes here too). A write error the builtin flagged (full disk) is
				-- status 1, like bash's sh_chkwrite.
				cx.blocks[p] = d
					.. builder
					.. ("; do local __rs = {}; if %s then sh.write_err = nil; %s; io.flush() else sh.status = 1 end; rt.redir_restore(__rs); if sh.write_err then sh.status = 1 end end; %s%s; pc = %d"):format(
						redir_apply,
						bcall,
						lastarg,
						ecs,
						after
					)
			else
				cx.blocks[p] = d
					.. builder
					.. ("; %s; "):format(bcall)
					.. lastarg
					.. ecs
					.. ("; pc = %d"):format(after)
			end
			return p
		end
	end
	-- FIELD-ENGINE path: an argument word-splits or globs, so argv is variable
	-- length. Commands with a STATIC dispatch (echo, test/[, a named external, a
	-- non-inline function) consume it via rt.field_split on natively-computed
	-- operands; everything else (inline fn, interp-only builtin, prefix env,
	-- dynamic command word) delegates.
	if st.assigns == nil then
		local anyfield = false
		-- A `local`/in-function `declare` VALUE word (j>1) never word-splits or globs
		-- (assignment context), so a merely-renderable value (`local x=$y`) is NOT a
		-- field-engine word — gate it on emitable_word, letting it reach the native
		-- localAssign path below rather than delegating here.
		for j = 1, #st.words do
			if as_local and j > 1 then
				if not emitable_word(st.words[j]) then
					anyfield = true
					break
				end
			elseif not word_safe(st.words[j]) then
				anyfield = true
				break
			end
		end
		if anyfield then
			local from, wrap, call, prefix
			if cmd == "echo" then
				from = 2
				call = "sh:echo_cmd(unpack(__a))"
			elseif cmd == "test" or cmd == "[" then -- the [ / test command word is a literal (dispatched by
				from = 2
				wrap = "rt.cstr(%s)"
				call = "rt.do_test(sh, __a)" -- name, never glob-expanded)
				prefix = ("rt.cstr(%q)"):format(cmd)
			elseif cx.funcflags[cmd] and (cx.funcflags[cmd].locals or cx.funcflags[cmd].params) then
				from = 2
				local ff = cx.funcflags[cmd]
				call = inl_sync(cmd, fnwrap(
					cmd,
					st.line,
					ff.locals and ("sh:pushCall(unpack(__a)); %s(sh); sh:popCall()"):format(fnlname(cmd))
						or ("sh:pushParams(unpack(__a)); %s(sh); sh:popParams()"):format(fnlname(cmd))
				), cx)
			elseif cx.funcflags[cmd] then -- bare function (references NO positional params): build argv
				from = 2 -- to run the args' side effects, then a bare call (params unread)
				call = inl_sync(cmd, fnwrap(cmd, st.line, ("%s(sh)"):format(fnlname(cmd))), cx)
			elseif
				cmd ~= nil
				and not NATIVE_BUILTIN[cmd]
				and not (cx.inlinefns and cx.inlinefns[cmd])
				and not cx.funcflags[cmd]
				and not require("interp").BUILTINS[cmd]
			then
				from = 1
				call = "sh:exec(unpack(__a))" -- external, static command name
			else
				return cx.delegate(st, after)
			end
			wrap = wrap or "rt.cstr(%s)" -- argv entries are C strings: cut each at NUL (bash/interp)
			local builder = field_argv(st.words, from, cx.lifted, wrap, prefix)
			if not builder then
				return cx.delegate(st, after)
			end
			local p = cx.newpc()
			local ec = errchk(st)
			local ecs = ec ~= "" and ("; " .. ec) or ""
			local d = dbg(st) -- DEBUG fires before the command (and its expansions)
			-- PIPESTATUS after a simple command is a one-element array of its status
			-- (bash), like the static-dispatch path below; gated on the program reading it.
			local ps = EF.pipestatus and '; sh:array_assign("PIPESTATUS", {tostring(sh.status)}, false)' or ""
			-- $_ = the last argument (the command name when there are none), after the call
			ps = ("; sh:set_str('_', #__a > 0 and __a[#__a] or %q)"):format(cmd or "") .. ps
			if redir_apply then
				-- bash order: expand the words (side-effecting cmdsubs run) BEFORE the
				-- redirects are applied, so `cmd $(read f) > f` reads f before it's
				-- truncated. Build argv first, then install redirs around the dispatch.
				cx.blocks[p] = d
					.. builder
					.. ("; do local __rs = {}; if %s then %s else sh.status = 1 end; rt.redir_restore(__rs) end%s%s; pc = %d"):format(
						redir_apply,
						call,
						ps,
						ecs,
						after
					)
			else
				cx.blocks[p] = d .. builder .. "; " .. call .. ps .. ecs .. ("; pc = %d"):format(after)
			end
			return p
		end
	end
	local mustdeleg = st.assigns ~= nil -- prefix env -> delegate
	if not mustdeleg then
		for j, w in ipairs(st.words) do
			-- The command word of a NATIVE builtin is dispatched by literal name (never
			-- glob-expanded), so skip its field-engine check — otherwise `[` trips the
			-- unquoted-glob rule on its own `[` char and the whole `[ … ]` delegates.
			if j == 1 and NATIVE_BUILTIN[cmd] then -- literal builtin name
			-- functions stay native (so they inline / call fn_x) unless an arg has a
			-- ${..} the codegen can't render; other commands delegate on any word
			-- that needs the field engine (splitting/glob/multi).
			elseif isfunc then
				if not emitable_word(w) then
					mustdeleg = true
					break
				end
			-- `local`/in-function `declare|typeset` VALUE word (j>1): an assignment RHS
			-- never word-splits or globs, so it needs only to be renderable (emitable_word),
			-- not word_safe — `local x=$y` / `local x=$(cmd)` / `local x=*.txt` assign the
			-- value verbatim. (The command word j==1 keeps the word_safe/native-builtin path.)
			elseif as_local and j > 1 then
				if not emitable_word(w) then
					mustdeleg = true
					break
				end
			elseif not word_safe(w) then
				mustdeleg = true
				break
			end
		end
	end
	-- interp-only builtins (no native compiled form) delegate. Use interp's own
	-- builtin set so the two backends stay in lockstep as builtins are added. `as_local`
	-- (in-function declare/typeset) has a native form (sh:localAssign) — don't delegate it.
	if not mustdeleg and cmd and not NATIVE_BUILTIN[cmd] and not isfunc and not as_local then
		if require("interp").BUILTINS[cmd] then
			mustdeleg = true
		end
	end
	if mustdeleg then
		return cx.delegate(st, after)
	end
	-- A DYNAMIC command word (`"$a"`, cmd is not a compile-time literal) must be
	-- resolved at runtime against functions → builtins → externals, exactly as the
	-- interpreter does. The native fall-through below assumes an EXTERNAL command
	-- (sh:exec = PATH lookup), so `a=typeset; "$a" v=1` reported "command not found"
	-- instead of running the builtin. Delegate — before the newpc, so no pc leaks.
	if cmd == nil then
		return cx.delegate(st, after)
	end
	if cmd == "return" then -- exit the current CFG (function or top level)
		local w2 = st.words[2]
		if w2 and #w2.parts == 1 and w2.parts[1].lit == "--" and not w2.parts[1].q then
			w2 = st.words[3] -- (`return -- N`)
			if st.words[4] then
				return cx.delegate(st, after)
			end
		elseif st.words[3] then -- (too many arguments: interp discards the command)
			return cx.delegate(st, after)
		end
		local p = cx.newpc()
		local n = w2 and ("rt.return_code(sh, %s)"):format(emit_word(w2, cx.lifted)) or "sh.status"
		cx.blocks[p] = ("sh.status = (%s) or 0; pc = %d"):format(n, cx.DONE)
		return p
	end
	if cx.inlinefns and cx.inlinefns[cmd] and not redir_apply then
		-- INLINE: bind $n to the caller's exprs and splice the body flowing to `after`.
		local pb = {}
		for j = 2, #st.words do
			local w = st.words[j]
			local strExpr = emit_word(w, cx.lifted)
			local intExpr
			if #w.parts == 1 then
				local pp = w.parts[1]
				if pp.var then
					intExpr = cx.lifted[pp.var] and lname(pp.var) or ("sh:aget(%q)"):format(pp.var)
				elseif pp.lit and pp.lit:match("^[+-]?%d+$") then
					intExpr = pp.lit .. "LL"
				elseif pp.arith then
					intExpr = emit_value(safe_arith(pp.arith), cx.lifted)
				else
					intExpr = ("rt.str_to_i64(%s)"):format(strExpr)
				end
			else
				intExpr = ("rt.str_to_i64(%s)"):format(strExpr)
			end
			pb[j - 1] = { int = intExpr, str = strExpr }
		end
		-- $_ after the call is the call's LAST argument (or the name), expanded BEFORE the
		-- body runs (which may change it): capture it, splice the body, then set $_.
		local us = cx.newloopvar()
		local lastw = st.words[#st.words]
		local post = cx.newpc()
		cx.blocks[post] = ('sh:set_str("_", %s); pc = %d'):format(us, after)
		local bodyentry = cx.flatten_list(subst_list(cx.inlinefns[cmd], pb), post)
		local pre = cx.newpc()
		cx.blocks[pre] = ("%s = %s; pc = %d"):format(us, emit_word(lastw, cx.lifted), bodyentry)
		return pre
	end
	local p = cx.newpc()
	local args = {}
	-- argv entries are C strings: cut each at NUL (bash/interp expand_args), so
	-- `echo $'a\0b'` / a function arg with a NUL match. Command name kept as-is.
	for j = 2, #st.words do
		if not empty_word(st.words[j]) then
			args[#args + 1] = ("rt.cstr(%s)"):format(emit_word(st.words[j], cx.lifted))
		end
	end
	local body
	if cmd == "echo" then
		body = "sh:echo_cmd(" .. table.concat(args, ", ") .. ")"
	elseif cmd == ":" or cmd == "true" or cmd == "false" then
		-- :/true/false ignore their args but bash still EXPANDS them, so a side-effecting arg
		-- (`: $((a/=3))`, `: "${x:=d}"`, `: "$(cmd)"`) must run. Evaluate the argv, discard it.
		local ev = #args > 0 and ("local __a = { " .. table.concat(args, ", ") .. " }; ") or ""
		body = ev .. ("sh.status = %d"):format(cmd == "false" and 1 or 0)
	elseif as_local then -- local / in-function declare|typeset: each NAME[=val] a local
		-- bash expands ALL the assignment words FIRST (in the OUTER scope), THEN localizes
		-- + assigns them — so `local a=1 b=$a` gives b=<outer a>, not 1. Pre-evaluate every
		-- value into a temp before any localAssign so a later operand can't see an earlier
		-- one's new binding. A `local NAME=foo:~` arg tilde-expands the RHS (all-literal only).
		local tmps, calls = {}, {}
		for j = 2, #st.words do
			local aw = st.words[j]
			if not empty_word(aw) then
				local av = emit_word(aw, cx.lifted)
				local fl = unq_full_lit(aw)
				if fl and fl:find("~", 1, true) then
					av = ("rt.tilde_word_initial(sh, %q)"):format(fl)
				end
				local tn = "__lv" .. (#tmps + 1)
				tmps[#tmps + 1] = ("local %s = %s"):format(tn, av)
				-- localAssign returns false for a READONLY name (message + that operand fails);
				-- `local` returns 1 if ANY operand failed, else 0 — the others still localize.
				calls[#calls + 1] = ("__lok = (sh:localAssign(%s) ~= false) and __lok"):format(tn)
			end
		end
		if #calls == 0 then
			body = "sh.status = 0"
		else
			body = table.concat(tmps, "; ")
				.. "; local __lok = true; "
				.. table.concat(calls, "; ")
				.. "; sh.status = __lok and 0 or 1"
			-- a function's lifted locals (func_locals): their registers take the new values
			for j = 2, #st.words do
				local nm = (unq_full_lit(st.words[j]) or ""):match("^([%a_][%w_]*)=")
				if nm and EF.fn_locals and EF.fn_locals[nm] and cx.lifted[nm] then
					body = body .. ("; %s = sh:aget(%q)"):format(lname(nm), nm)
				end
			end
		end
	elseif cmd == "test" or cmd == "[" then
		-- [ EXPR ] / test EXPR: the operator/arity are compile-time known; compute the
		-- args natively (word_safe, so no field engine) and run the POSIX test logic
		-- via the do_test PRIMITIVE (access/stat/string/arith on the VALUES — not an
		-- AST re-walk). do_test sets $? (0/1, or 2 on a malformed expression). Each arg
		-- is rt.cstr'd: an argv entry is a C string, so a NUL truncates it (`$'\0'`);
		-- interp truncates in expand_args, external exec via C — do_test is Lua-side.
		local allargs = {}
		for j = 1, #st.words do
			if not empty_word(st.words[j]) then
				allargs[#allargs + 1] = ("rt.cstr(%s)"):format(emit_word(st.words[j], cx.lifted))
			end
		end
		body = "rt.do_test(sh, {" .. table.concat(allargs, ", ") .. "})"
	elseif cx.funcflags[cmd] then
		local ff = cx.funcflags[cmd]
		if ff.locals then -- full frame (save/restore shadowed vars + params)
			body = fnwrap(
				cmd,
				st.line,
				("sh:pushCall(%s); %s(sh); sh:popCall()"):format(table.concat(args, ", "), fnlname(cmd))
			)
		elseif ff.params then -- positional swap only (no per-call frame table)
			body = fnwrap(
				cmd,
				st.line,
				("sh:pushParams(%s); %s(sh); sh:popParams()"):format(table.concat(args, ", "), fnlname(cmd))
			)
		else -- neither: bare call, no allocation
			body = fnwrap(cmd, st.line, ("%s(sh)"):format(fnlname(cmd)))
		end
		body = inl_sync(cmd, body, cx)
	else -- external command — OR a function DEFINED AT RUNTIME (via source/eval).
		local allargs = {}
		for j = 1, #st.words do
			if not empty_word(st.words[j]) then
				allargs[#allargs + 1] = ("rt.cstr(%s)"):format(emit_word(st.words[j], cx.lifted))
			end
		end
		-- The name wasn't a funcdef at compile time, but source/eval can install one
		-- into sh.functions before this runs; bash resolves function → builtin →
		-- external, so check sh.functions at runtime and delegate to interp (which
		-- sets up the frame/params/return) when present — else exec the external.
		local ei = {}
		for n in spairs(cx.lifted) do
			ei[#ei + 1] = ("sh:aset(%q, %s)"):format(n, lname(n))
		end
		local eo = {}
		for n in spairs(cx.lifted) do
			eo[#eo + 1] = ("%s = sh:aget(%q)"):format(lname(n), n)
		end
		local si = #ei > 0 and (table.concat(ei, "; ") .. "; ") or ""
		local so = #eo > 0 and ("; " .. table.concat(eo, "; ")) or ""
		body = ("if sh.functions[%q] then %srt.call_dynamic_fn(sh, {%s})%s else sh:exec(%s) end"):format(
			cmd,
			si,
			table.concat(allargs, ", "),
			so,
			table.concat(allargs, ", ")
		)
	end
	local ec = errchk(st) -- errexit after a failing native simple command
	local ecs = ec ~= "" and ("; " .. ec) or ""
	local u = und(st, cx.lifted) -- $_ = this command's last arg (bash), for the NEXT command
	if cmd == "echo" and u ~= "" and body:sub(1, 12) == "sh:echo_cmd(" then
		-- (echo sets $_ from the argv it already built: the last word isn't evaluated twice)
		body = "sh:echo_cmd_u(" .. body:sub(13)
		u = ""
	end
	-- PIPESTATUS after a simple command is a one-element array of its status (bash);
	-- set BEFORE errchk so an ERR trap sees it. Gated on the program reading it.
	local ps = EF.pipestatus and '; sh:array_assign("PIPESTATUS", {tostring(sh.status)}, false)' or ""
	local d = dbg(st) -- DEBUG fires before the command
	if redir_apply then
		-- install the redirs (backing up fds), run the command only if they all
		-- succeeded (else $?=1, bash), then restore the fds — real syscalls, no AST.
		cx.blocks[p] = d
			.. ("do local __rs = {}; if %s then %s else sh.status = 1 end; rt.redir_restore(__rs) end%s%s%s; pc = %d"):format(
				redir_apply,
				body,
				ps,
				ecs,
				u,
				after
			)
	else
		cx.blocks[p] = d .. body .. ps .. ecs .. u .. ("; pc = %d"):format(after)
	end
	return p
end

-- statement handler: arithcmd (split out of flatten_stmt; see H)
H.arithcmd = function(cx, st, after)
	local t = st.t
	-- (( expr )): evaluate expr WITH side effects natively (assignments, ++/--,
	-- comma), then $? = (result != 0) ? 0 : 1 — bash's arith-command status. No
	-- delegation; the interpreter is only used for the parts the emitter can't
	-- render (array subscripts, embedded $-expansion, $LINENO/$_).
	-- A redirect (`(( … )) 2>/dev/null`) is applied around the eval and restored
	-- after (its only effect is to steer a div0/error message).
	local ac_redir = nil
	if st.redirs then
		ac_redir = cx.redir_conds(st, nil)
		if not ac_redir then
			return cx.delegate(st, after)
		end
	end
	if not arith_stmt_ok(st.expr) then
		return cx.delegate(st, after)
	end
	local p = cx.newpc()
	local ec = errchk(st)
	local ecs = ec ~= "" and ("; " .. ec) or ""
	local d = dbg(st) -- DEBUG fires before the (( )) command (bash: DEBUG_FIRE.arithcmd)
	local saved = arith_varread
	arith_varread = "rt.arith_read(sh, %q)" -- nounset+recursive-eval reads
	local code = emit_arith_into("__ar", st.expr, cx.lifted)
	arith_varread = saved
	local sbody -- the status-setting body (redirect-wrapped below when present)
	-- (a write to a READONLY var raises the same matherr — only possible in a program that
	-- sets attributes, so ordinary `((i++))` loops keep the inline form)
	if arith_can_div_fault(st.expr) or (EF.has_attr and arith_side_effect(st.expr)) then
		-- ÷0 / mod-0 / negative ** THROW a non-fatal matherr — catch it (and any
		-- flagged read fault) as $?=1 and continue, like interp; re-raise anything else.
		sbody = (
			"do local __ia = sh.in_arithcmd; sh.arithfault = false; sh.in_arithcmd = true; local __ok, __v = pcall(function() local __ar = 0LL; %s; return (__ar ~= 0LL) and 0 or 1 end); sh.in_arithcmd = __ia; "
			.. "if not __ok then if type(__v) == 'table' and __v.__curse_matherr and not __v.__curse_subscript then sh.status = 1 else error(__v) end "
			.. "elseif sh.arithfault then sh.status = 1 else sh.status = __v end end"
		):format(code)
	elseif arith_can_error(st.expr, cx.lifted) then
		-- a non-lifted read may fault; INSIDE the (( )) command arith_read records it in
		-- sh.arithfault WITHOUT throwing (sh.in_arithcmd gates that), so no per-iteration
		-- pcall/closure — the accumulator stays JIT-native.
		sbody = ("do local __ia = sh.in_arithcmd; sh.arithfault = false; sh.in_arithcmd = true; local __ar = 0LL; %s; sh.in_arithcmd = __ia; sh.status = sh.arithfault and 1 or ((__ar ~= 0LL) and 0 or 1) end"):format(
			code
		)
	else -- provably error-free (lifted ints, +-*/comparisons): inline, JIT-native
		sbody = ("do local __ar = 0LL; %s; sh.status = (__ar ~= 0LL) and 0 or 1 end"):format(code)
	end
	if ac_redir then -- install redirs, run, restore; a failed redirect is $?=1 (bash)
		sbody = ("do local __rs = {}; if %s then %s else sh.status = 1 end; rt.redir_restore(__rs) end"):format(
			ac_redir,
			sbody
		)
	end
	cx.blocks[p] = d .. sbody .. ecs .. ("; pc = %d"):format(after)
	return p
end

-- statement handler: forc (split out of flatten_stmt; see H)
H.forc = function(cx, st, after)
	local t = st.t
	if st.redirs then
		return cx.delegate(st, after)
	end -- redirs on the loop: interp applies them
	if hard_cf(st.body) then
		return cx.delegate(st, after)
	end -- un-static break/continue
	if
		not_compilable(st.init)
		or not_compilable(st.cond)
		or not_compilable(st.step)
		or arith_side_effect(st.cond) -- a side-effecting cond can't be an emit_bool expr
		or arith_reads_unsafe(st.init)
		or arith_reads_unsafe(st.cond)
		or arith_reads_unsafe(st.step)
	then
		return cx.delegate(st, after) -- $LINENO/$RANDOM/… in the arith: interp reproduces the value
	end
	local condp = cx.newpc()
	cx.loopPc[st.id] = condp
	local stepp = cx.newpc()
	cx.loopstack[#cx.loopstack + 1] = { brk = after, cont = stepp } -- break exits, continue steps
	local bodyentry = cx.flatten_list(st.body, stepp)
	cx.loopstack[#cx.loopstack] = nil
	local d = dbg(st) -- DEBUG fires at the for(( header for the init, each cond, and each step (bash)
	cx.blocks[stepp] = d
		.. (st.step and emit_arith_stmt(st.step, cx.lifted) .. "; " or "")
		.. ("pc = %d"):format(condp)
	-- (a loop that runs no iteration has status 0; else its last body command's — `ran`
	-- says which, reset each time the loop is entered; 1 at an OSR entry, which skips the
	-- reset — that loop has been iterating in the interpreter)
	local ran = cx.newloopvar(1)
	local bodyp, exitp = cx.newpc(), cx.newpc()
	cx.blocks[bodyp] = ("%s = 1; pc = %d"):format(ran, bodyentry)
	cx.blocks[exitp] = ("if %s == 0 then sh.status = 0 end; pc = %d"):format(ran, after)
	cx.blocks[condp] = d
		.. ("if %s then pc = %d else pc = %d end"):format(
			st.cond and emit_bool(st.cond, cx.lifted) or "true",
			bodyp,
			exitp
		)
	local ep = cx.newpc()
	if st.init then
		local ip = cx.newpc()
		cx.blocks[ip] = d .. emit_arith_stmt(st.init, cx.lifted) .. ("; pc = %d"):format(condp)
		cx.blocks[ep] = ("%s = 0; pc = %d"):format(ran, ip)
	else
		cx.blocks[ep] = ("%s = 0; pc = %d"):format(ran, condp)
	end
	return ep
end

-- statement handler: whilec (split out of flatten_stmt; see H)
H.whilec = function(cx, st, after)
	local t = st.t
	if st.redirs then
		return cx.delegate(st, after)
	end -- redirs on the loop (heredoc/file): interp applies them
	-- un-static break/continue in the body, or ANY in the command condition (loopstack
	-- isn't active there) → delegate the whole loop (else the signal is lost → spin).
	if hard_cf(st.body) or (type(st.cond) == "table" and not st.cond.k and hard_cf(st.cond, true)) then
		return cx.delegate(st, after)
	end
	local arith = cond_arith(st.cond)
	if arith and arith_reads_unsafe(arith) then
		-- a `(( ))` condition reading an unreproducible special ($LINENO/$RANDOM/…):
		-- delegate the whole loop to interp, which reproduces the value.
		return cx.delegate(st, after)
	end
	if arith and not st.negate and not not_compilable(arith) and not arith_side_effect(arith) then
		-- fast path: a native arith condition `while (( expr ))` — no command run.
		local condp = cx.newpc()
		cx.loopPc[st.id] = condp
		cx.loopstack[#cx.loopstack + 1] = { brk = after, cont = condp }
		local bodyentry = cx.flatten_list(st.body, condp)
		cx.loopstack[#cx.loopstack] = nil
		-- DEBUG fires before each evaluation of the condition command (bash)
		local cst = type(st.cond) == "table" and st.cond[1] or nil
		cx.blocks[condp] = (cst and dbg(cst) or "") .. ("if %s then pc = %d else pc = %d end"):format(
			emit_bool(arith, cx.lifted),
			bodyentry,
			after
		)
		return condp
	end
	-- fast path: `while/until [ A -op B ]` with integer operands — a native int64
	-- compare instead of building an argv table and running do_test each iteration.
	-- Keeps [ ]'s own $? (0/1) for the body's first command AND the loop's
	-- last-body exit status (lv), exactly like the command-condition path below.
	local tarith = test_as_arith(st.cond, cx.lifted)
	local tvar = not tarith and test_as_varcmp(st.cond, cx.lifted)
	if tarith or tvar then
		local lv = cx.newloopvar()
		local condp = cx.newpc()
		cx.loopPc[st.id] = condp
		local exitp = cx.newpc()
		cx.blocks[exitp] = ("sh.status = %s; pc = %d"):format(lv, after)
		cx.loopstack[#cx.loopstack + 1] = { brk = after, cont = condp }
		local bodysave = cx.newpc()
		local bodyentry = cx.flatten_list(st.body, bodysave)
		cx.loopstack[#cx.loopstack] = nil
		cx.blocks[bodysave] = ("%s = sh.status; pc = %d"):format(lv, condp)
		local cst = type(st.cond) == "table" and st.cond[1] or nil
		local stexpr
		if tarith then -- ($_ is the test's last argument: `]`, or test's right operand)
			local tw = st.cond[1].words
			local lastw = tw[#tw]
			stexpr = ("sh.status = (%s) and 0 or 1; sh:set_str(\"_\", %s)"):format(emit_bool(tarith, cx.lifted),
				emit_word(lastw, cx.lifted))
		else
			stexpr = ("rt.test_icmp(sh, %s, %q, %s, %q)"):format(tvar.a, tvar.op, tvar.b, tvar.cmd)
		end
		cx.blocks[condp] = (cst and dbg(cst) or "") .. ("%s; if sh.status %s 0 then pc = %d else pc = %d end"):format(
			stexpr,
			st.negate and "~=" or "==",
			bodyentry,
			exitp
		)
		local entry = cx.newpc()
		cx.blocks[entry] = ("%s = 0; pc = %d"):format(lv, condp)
		return entry
	end
	-- COMMAND condition (or `until`): run the condition list as a sub-CFG with
	-- sh.noerr raised (errexit-exempt, like the interpreter), then branch on its
	-- exit status — `while` enters the body on 0, `until` on non-zero. The loop's
	-- exit status is the LAST body command's status (bash), which the condition
	-- clobbers — so one native register (lv) remembers it across the re-test.
	-- loopPc = the condition entry (an OSR resumes at the re-test point). Genuine
	-- control flow, no delegation.
	local lv = cx.newloopvar()
	local prep = cx.newpc()
	cx.loopPc[st.id] = prep
	local donep = cx.newpc()
	local exitp = cx.newpc()
	cx.blocks[exitp] = ("sh.status = %s; pc = %d"):format(lv, after)
	cx.loopstack[#cx.loopstack + 1] = { brk = after, cont = prep } -- break exits (status 0), continue re-tests
	local bodysave = cx.newpc()
	local bodyentry = cx.flatten_list(st.body, bodysave)
	cx.loopstack[#cx.loopstack] = nil
	cx.blocks[bodysave] = ("%s = sh.status; pc = %d"):format(lv, prep)
	cx.blocks[donep] = ("sh.noerr = sh.noerr - 1; if sh.status %s 0 then pc = %d else pc = %d end"):format(
		st.negate and "~=" or "==",
		bodyentry,
		exitp
	)
	local listentry = cx.flatten_list(st.cond, donep)
	cx.blocks[prep] = ("sh.noerr = sh.noerr + 1; pc = %d"):format(listentry)
	local entry = cx.newpc()
	cx.blocks[entry] = ("%s = 0; pc = %d"):format(lv, prep) -- status 0 if body never runs
	return entry
end

-- statement handler: forin (split out of flatten_stmt; see H)
H.forin = function(cx, st, after)
	local t = st.t
	if st.redirs then
		return cx.delegate(st, after)
	end -- redirs on the loop: interp applies them
	if hard_cf(st.body) then
		return cx.delegate(st, after)
	end -- un-static break/continue
	if not st.name:match("^[%a_][%w_]*$") then
		return cx.delegate(st, after)
	end -- invalid loop var → interp errors
	-- Each word expands to for-list fields exactly like a command argument: word_safe (one
	-- field), a field_word (an unquoted expansion/glob the field engine splits+globs), or a
	-- seg_native mixed word (rt.expand_fields — literal+$x, $@/$*, ${a[@]}, ${!a[@]}, scalar
	-- ${..} ops). emit_fields_into renders each fully natively (no interp field engine); a
	-- word only the shared engine could take still delegates the loop (rare, cold).
	for _, w in ipairs(st.words) do
		-- $LINENO in a for-in list on a CONTINUATION line is the word's line, not the `for`
		-- line (st.line) the compile-time constant would use — delegate so interp's per-line
		-- tracking gives the exact value (rare; the whole loop is cold anyway).
		for _, p in ipairs(w.parts) do
			if p.var == "LINENO" then
				return cx.delegate(st, after)
			end
		end
		if not word_safe(w) and not field_word(w, cx.lifted) and not EF.seg_native(w, cx.lifted) then
			return cx.delegate(st, after)
		end
	end
	local initp = cx.newpc()
	local advp = cx.newpc()
	cx.loopPc[st.id] = advp -- back-edge = resume point
	cx.loopstack[#cx.loopstack + 1] = { brk = after, cont = advp } -- break exits, continue advances
	local bodyentry = cx.flatten_list(st.body, advp)
	cx.loopstack[#cx.loopstack] = nil
	-- init: expand the word list ONCE into sh.forstate[id] (so OSR resumes it)
	local parts = { "local __l = {}" }
	-- a long run of plain literal words (`for i in {1..4000}`) becomes ONE constant table:
	-- thousands of separate appends overflow LuaJIT's per-block jump range
	local run = {}
	local function flush_run()
		if #run > 32 then
			parts[#parts + 1] = ("for _, __v in ipairs({%s}) do __l[#__l+1] = __v end"):format(table.concat(run, ","))
		else
			for _, e in ipairs(run) do
				parts[#parts + 1] = "__l[#__l+1] = " .. e
			end
		end
		run = {}
	end
	for _, w in ipairs(st.words) do
		if not empty_word(w) then
			local code = emit_fields_into("__l", w, cx.lifted)
			local lit = code:match('^__l%[#__l%+1%] = (%("[^"\\]*"%))$')
			if lit then
				run[#run + 1] = lit
			else
				flush_run()
				parts[#parts + 1] = code
			end
		end
	end
	flush_run()
	-- The loop state lives in a LOCAL of this function activation (a recursive call, or a
	-- $( … ) fragment running a loop with the same id, must not clobber it), published in
	-- sh.forstate[id] for an OSR entry — which adopts it (below). Capped: a function has
	-- only so many Lua locals.
	cx.forlocals = cx.forlocals or {}
	local fsl = #cx.forlocals < 48 and ("__fs" .. st.id) or nil
	if fsl and not cx.forlocals[fsl] then
		cx.forlocals[#cx.forlocals + 1] = fsl
		cx.forlocals[fsl] = true
	end
	parts[#parts + 1] = fsl and ("%s = {list=__l, idx=0}; sh.forstate[%d] = %s"):format(fsl, st.id, fsl)
		or ("sh.forstate[%d] = {list=__l, idx=0}"):format(st.id)
	local getfs = fsl and ("local fs = %s or sh.forstate[%d]; %s = fs"):format(fsl, st.id, fsl)
		or ("local fs = sh.forstate[%d]"):format(st.id)
	cx.blocks[initp] = table.concat(parts, "; ") .. ("; pc = %d"):format(advp)
	if EF.has_attr then -- a readonly loop variable: bash reports it and runs no iteration
		cx.blocks[initp] = ("if rt.for_var_ro(sh, %q) then pc = %d else %s end"):format(st.name, after, cx.blocks[initp])
	end
	-- DEBUG fires at the `for` header before each iteration (bash), with an element present.
	-- (no iteration at all: the loop's status is 0 — else it's the last body command's)
	-- (a nameref program: rt.for_assign re-points a nameref loop variable, and a failed
	-- assignment — a bad target — ends the loop with status 1)
	if EF.has_nameref then
		cx.blocks[advp] = ("%s; fs.idx = fs.idx + 1; if fs.idx > #fs.list then if fs.idx == 1 then sh.status = 0 end; pc = %d elseif not rt.for_assign(sh, %q, fs.list[fs.idx]) then sh.status = 1; pc = %d else %spc = %d end"):format(
			getfs,
			after,
			st.name,
			after,
			dbg(st),
			bodyentry
		)
	else
		cx.blocks[advp] = ("%s; fs.idx = fs.idx + 1; if fs.idx > #fs.list then if fs.idx == 1 then sh.status = 0 end; pc = %d else sh:set_str(%q, fs.list[fs.idx]); %spc = %d end"):format(
			getfs,
			after,
			st.name,
			dbg(st),
			bodyentry
		)
	end
	return initp
end

-- statement handler: if (split out of flatten_stmt; see H)
H["if"] = function(cx, st, after)
	local t = st.t
	-- Each clause's condition is either a native arith `(( ))` (emit_bool) or a
	-- COMMAND LIST run for its status. Both compile — the command condition is a
	-- sub-CFG run with sh.noerr raised (errexit-exempt, like the interpreter),
	-- then we branch on sh.status. No delegation. Flatten bodies once, then build
	-- clauses back-to-front so each false-branch target (the next condition, the
	-- else body, or `after`) already exists.
	if st.redirs then
		return cx.delegate(st, after)
	end -- redirs on the whole `if`: interp applies them
	local bentry = {}
	local has_else = false
	for i, cl in ipairs(st.clauses) do
		bentry[i] = cx.flatten_list(cl.body, after)
		if not cl.cond then
			has_else = true
		end
	end
	-- With no else clause, falling past every (false) condition runs no body, so
	-- the `if` yields status 0 (bash) — route that fall-through through a reset.
	local fallthrough = after
	if not has_else then
		local s0 = cx.newpc()
		cx.blocks[s0] = ("sh.status = 0; pc = %d"):format(after)
		fallthrough = s0
	end
	local condentry = {}
	for i = #st.clauses, 1, -1 do
		local cl = st.clauses[i]
		local nxt = st.clauses[i + 1] and (condentry[i + 1] or bentry[i + 1]) or fallthrough
		if not cl.cond then
			condentry[i] = bentry[i] -- an `else` clause: its body runs unconditionally
		else
			local arith = cond_arith(cl.cond)
			local tarith = not arith and test_as_arith(cl.cond, cx.lifted) -- `[ A -op B ]`, integer operands
			if arith and not not_compilable(arith) and not arith_side_effect(arith) then
				local cp = cx.newpc()
				cx.blocks[cp] = ("if %s then pc = %d else pc = %d end"):format(
					emit_bool(arith, cx.lifted),
					bentry[i],
					nxt
				)
				condentry[i] = cp
			elseif tarith then -- native int64 compare, and set [ ]'s own $? (0/1)
				local cp = cx.newpc()
				cx.blocks[cp] = ("sh.status = (%s) and 0 or 1; if sh.status == 0 then pc = %d else pc = %d end"):format(
					emit_bool(tarith, cx.lifted),
					bentry[i],
					nxt
				)
				condentry[i] = cp
			else -- command condition: noerr++ ; run list ; noerr-- ; branch on status
				local donep = cx.newpc()
				cx.blocks[donep] = ("sh.noerr = sh.noerr - 1; if sh.status == 0 then pc = %d else pc = %d end"):format(
					bentry[i],
					nxt
				)
				local listentry = cx.flatten_list(cl.cond, donep)
				local prep = cx.newpc()
				cx.blocks[prep] = ("sh.noerr = sh.noerr + 1; pc = %d"):format(listentry)
				condentry[i] = prep
			end
		end
	end
	return condentry[1] or after
end

-- statement handler: andor (split out of flatten_stmt; see H)
H.andor = function(cx, st, after)
	local t = st.t
	-- `a && b || c`: run item 1, then each item iff the previous status matches
	-- its operator (&& on 0, || on non-zero) — pure control flow. Errexit exempts
	-- every operand EXCEPT the final one that runs (bash), so raise sh.noerr across
	-- the non-final operands and restore it right before the last, letting only its
	-- own errchk fire. Status is the last item that ran (natural). break/continue
	-- inside an operand compile to native jumps via flatten_stmt (that's why this
	-- must be real codegen, not delegation). `!`-negation lives on each pipeline.
	if st.redirs then
		return cx.delegate(st, after)
	end
	local items = st.items
	local nI = #items
	local runafter = {} -- where item i flows after running
	for i = 1, nI - 1 do
		runafter[i] = 0
	end -- filled with checkp[i+1] below
	runafter[nI] = after
	local checkp = {}
	for i = 2, nI do
		checkp[i] = cx.newpc()
	end
	for i = 1, nI - 1 do
		runafter[i] = checkp[i + 1]
	end
	local runentry = {}
	for i = 1, nI do
		runentry[i] = cx.flatten_stmt(items[i].cmd, runafter[i])
	end
	for i = 2, nI do
		local cmp = (items[i].op == "&&") and "==" or "~=" -- && runs on success, || on failure
		if i == nI then -- last operand: restore noerr so its OWN errchk applies
			cx.blocks[checkp[i]] = ("sh.noerr = sh.noerr - 1; if sh.status %s 0 then pc = %d else pc = %d end"):format(
				cmp,
				runentry[i],
				after
			)
		else
			cx.blocks[checkp[i]] = ("if sh.status %s 0 then pc = %d else pc = %d end"):format(
				cmp,
				runentry[i],
				checkp[i + 1]
			)
		end
	end
	local entry = cx.newpc()
	-- raise noerr for the non-final operands; a lone-item andor never occurs (>=2).
	cx.blocks[entry] = ("sh.noerr = sh.noerr + 1; pc = %d"):format(runentry[1])
	return entry
end

-- statement handler: subshell (split out of flatten_stmt; see H)
H.subshell = function(cx, st, after)
	local t = st.t
	-- ( body ): a subshell is not special, just SEPARATED — fork, and the child
	-- runs the body as a BOUNDED sub-CFG that _exits at its end (so it never runs
	-- the top-level continuation); the parent waits. The body's loops get their
	-- own loopPc entries, so a forked child that started in interp can OSR into
	-- the RIGHT place (its own fragment), honoring interp/bg-compile/OSR.
	-- Redirs on the subshell apply in the CHILD (they belong to the fork and die with
	-- it — no restore), so compile them when the shapes are compilable; else delegate.
	local sub_redir = nil
	if st.redirs then
		sub_redir = cx.redir_conds(st, nil)
		if not sub_redir then
			return cx.delegate(st, after)
		end
	end
	-- A body that toggles options with `set` (e.g. `set -e` mid-body) needs the
	-- interpreter's per-command semantics, which the straight-line sub-CFG can't
	-- reproduce — delegate the whole subshell (interp forks + enforces it).
	-- IN-PROCESS (no fork): the fat-LuaJIT fork dominates subshell cost. When the body
	-- needs no real child — no trap/ERR/DEBUG program, no eval/source, and it runs no
	-- exec/&/user-function-call and reads no per-subshell special ($RANDOM/$BASHPID/…) —
	-- run it as a CHECKPOINTED fragment (rt subshell_run copy-isolates every escaping
	-- piece of shell state). The fragment RAISES exit/return (caught by subshell_run),
	-- so subshell_exit_pc is cleared around its build. Anything else falls through to the
	-- fork path below (still correct). break/continue can't cross into it — subshell_run's
	-- fragment has its own loopstack, like the fork body.
	local inproc_pc = nil -- in-process branch behind a runtime guard (see below)
	local strict = #st.body > 0 and EF.subshell_inproc_ok(st.body)
	local late = not strict and #st.body > 0 and EF.subshell_late_ok(st.body)
	if not EF.inproc_trap_block and (strict or late) then
		local saved_ssx = EF.subshell_exit_pc
		EF.subshell_exit_pc = nil
		-- Compile the body WITH the program lift set so it shares the module's lifted
		-- upvalues with any function it calls (no sh.vars-vs-upvalue desync).
		local id = emit_fragment(st.body, nil, EF.lifted_set)
		EF.subshell_exit_pc = saved_ssx
		if id then
			local p = cx.newpc()
			local ec = errchk(st)
			local ecs = ec ~= "" and ("; " .. ec) or ""
			-- Swap game: save every lifted upvalue, run the (isolating) subshell, then
			-- restore — so a body/function mutation to a native-int64 var never escapes.
			-- subshell_run swallows exit/return, so the restore always runs.
			local swpre, swpost = "", ""
			local ln = EF.lifted_names or {}
			if #ln > 0 then
				local sav, vs = {}, {}
				for i, n in ipairs(ln) do
					sav[i] = "__sv" .. i
					vs[i] = lname(n)
				end
				local vlist = table.concat(vs, ", ")
				swpre = ("local %s = %s; "):format(table.concat(sav, ", "), vlist)
				swpost = ("; %s = %s"):format(vlist, table.concat(sav, ", "))
			end
			if sub_redir then
				cx.blocks[p] = ("%slocal __rs = {}; if %s then sh:subshell_run(cs_%d, __rs) else rt.redir_restore(__rs); sh.status = 1 end%s%s; pc = %d"):format(
					swpre, sub_redir, id, swpost, ecs, after)
			else
				cx.blocks[p] = ("%ssh:subshell_run(cs_%d)%s%s; pc = %d"):format(swpre, id, swpost, ecs, after)
			end
			if strict and not EF.has_dyncode then
				return p
			end
			inproc_pc = p
		end
	end
	-- errexit INHERITED at entry is now COMPILED: the forked child runs the body with
	-- errchk guards that exit the SUBSHELL on a failing command (EF.subshell_exit_pc, set
	-- below), and a condition subshell auto-suppresses via the inherited sh.noerr (the
	-- enclosing if/while/&&/|| already raised it). A trap program keeps delegating the
	-- errexit case (ERR/DEBUG per-command + a forked child's trap reset are interp-side).
	local errexit_deleg = EF.has_err or EF.has_debug or EF.has_trap
	local delpc = errexit_deleg and cx.delegate(st, after) or nil
	local exitpc = cx.newpc()
	cx.blocks[exitpc] = "rt.subshell_exit(sh.status or 0, sh)"
	-- A subshell is a fork: break/continue inside it target only loops WITHIN the
	-- subshell, never the parent's. Hide the enclosing loopstack while flattening
	-- the body (a break/continue with no in-subshell loop becomes a no-op, like
	-- bash), then restore it for the parent's control flow.
	local saved_loops = cx.loopstack
	cx.loopstack = {}
	local saved_ssx = EF.subshell_exit_pc -- errchk in the body exits THIS subshell (restored after)
	EF.subshell_exit_pc = exitpc
	cx.subexit[#cx.subexit + 1] = exitpc -- `return` in the body exits THIS subshell
	local bodyentry = cx.flatten_list(st.body, exitpc)
	cx.subexit[#cx.subexit] = nil
	EF.subshell_exit_pc = saved_ssx
	cx.loopstack = saved_loops
	local p = cx.newpc()
	-- errexit/ERR after a failing subshell fires in the PARENT — this errchk uses the
	-- ENCLOSING context (restored above): exits the enclosing subshell (if any) or the shell.
	local ec = errchk(st)
	local ecs = ec ~= "" and ("; " .. ec) or ""
	-- The forked child sets sh._ff = the subshell's exit pc, so a lineabort raised in the
	-- body (div0, failglob, an invalid-indirect, …) exits the SUBSHELL (subshell_exit ->
	-- _exit) instead of fast-forwarding into the PARENT's continuation and re-running it.
	-- With redirs, the child installs them first (no restore — it _exits), then runs the
	-- body REGARDLESS of the result: interp's subshell child applies the redirs and ignores
	-- whether they succeeded (a failed subshell redirect does not abort the body there), so
	-- match that — the redir expression runs for its side effect, its boolean discarded.
	local child = sub_redir
			and ("sh._ff = %d; local __rs = {}; local _ = %s; pc = %d"):format(exitpc, sub_redir, bodyentry)
		or ("sh._ff = %d; pc = %d"):format(exitpc, bodyentry)
	local fork = ("local __pid = rt.subshell_fork(sh); if __pid == 0 then %s else sh.status = rt.subshell_wait(__pid)%s; pc = %d end"):format(
		child,
		ecs,
		after
	)
	-- Non-trap program: always fork (errexit handled in the child via subshell-exit errchk).
	-- Trap program: under errexit, delegate (delpc) — ERR/DEBUG per-command semantics are interp-side.
	if errexit_deleg then
		cx.blocks[p] = ("if sh.opt_e then pc = %d else %s end"):format(delpc, fork)
	else
		cx.blocks[p] = fork
	end
	if inproc_pc then
		-- late-fork body: not inside a pipeline stage; eval/source program: names still static
		local cond = late and "not rt.in_stage()" or ("(not rt.in_stage() or %s)"):format(dyn_guard(st.body))
		local g = cx.newpc()
		cx.blocks[g] = ("if %s then pc = %d else pc = %d end"):format(cond, inproc_pc, p)
		return g
	end
	return p
end

-- statement handler: group (split out of flatten_stmt; see H)
H.group = function(cx, st, after)
	local t = st.t
	-- { list; }: not a subshell — just a sequence in the current shell. Flatten the
	-- body inline (redirs on the group still delegate; break/continue flow natively).
	if st.redirs then
		return cx.delegate(st, after)
	end
	return cx.flatten_list(st.body, after)
end

-- statement handler: pipeline (split out of flatten_stmt; see H)
H.pipeline = function(cx, st, after)
	local t = st.t
	-- a | b | c: compile each stage to a fragment and let the runtime orchestrate the
	-- fork/pipe/wait/PIPESTATUS, running the COMPILED stages — not exec_stmt. Gated to
	-- no trap/DEBUG/ERR (a forked stage otherwise resets signal traps / re-fires
	-- per-stage traps — interp-side). Flush lifted before (stages read sh) and reload
	-- after (a lastpipe last stage runs in-process and may write).
	-- DEBUG fires per pipeline element in bash (interp models it); compiled stages don't hook it
	if EF.inproc_trap_block or EF.has_debug then
		return cx.delegate(st, after)
	end
	local n = #st.cmds
	local frags = {}
	for i = 1, n do
		-- nst==1 is `! cmd` (a single negated command run in the current shell): compile
		-- it as a negated fragment so its OWN errexit is exempt; run_pipeline also raises
		-- noerr for a negated pipeline under errexit, so errexit inside anything it calls (a
		-- function, an eval) is ignored too (bash). Real pipe stages (n>=2) compile normally.
		-- compiled WITH the upval lift set: a stage and the functions it calls share
		-- `v_x`; the scheduler swaps those upvalues per stage like its fds.
		local id = emit_fragment({ st.cmds[i] }, n == 1 and st.negate, EF.lifted_set)
		if not id then
			return cx.delegate(st, after)
		end
		frags[i] = "cs_" .. id
	end
	local reload = {} -- run-local lifted vars only: stages keep those in sh (a lastpipe
	-- stage writes the shell's own); upvalues are swapped/restored by the scheduler
	for nm in spairs(cx.lifted) do
		if not EF.lifted_set[nm] then
			reload[#reload + 1] = ("%s = sh:aget(%q)"):format(lname(nm), nm)
		end
	end
	local post = #reload > 0 and ("; " .. table.concat(reload, "; ")) or ""
	local p = cx.newpc()
	-- errexit/ERR are exempt for a `!`-inverted pipeline (bash: the -e setting is
	-- ignored when the return value is inverted with !), regardless of the negated status.
	local ec = st.negate and "" or errchk(st)
	local ecs = ec ~= "" and ("; " .. ec) or ""
	-- bash quirk (execute_cmd.c): a failing `( … )` LAST stage runs ERR itself, on top of the
	-- pipeline's own ERR — keyed on that subshell's status, not the pipeline's `!`.
	if EF.has_err and n >= 2 and st.cmds[n].t == "subshell" then
		ecs = "; if sh.noerr == 0 and (sh.last_stage_status or 0) ~= 0 then I.fire_err_trap(sh) end" .. ecs
	end
	-- Per stage: run IN-PROCESS under the coroutine scheduler, or fork (a stage that
	-- needs a real child: exec, ulimit, set, eval, … — EF.sub_unsafe_fn).
	local inproc = {}
	for i = 1, n do
		local ok = n >= 2 and EF.subshell_inproc_ok({ st.cmds[i] })
		local yes = require("runtime").stage_flat(st.cmds[i], function(c)
			return cx.funcflags[c] or (cx.inlinefns and cx.inlinefns[c])
		end) and '"flat"' or "true"
		local g = ok and dyn_guard({ st.cmds[i] })
		inproc[i] = ok and (g and ("(%s) and %s"):format(g, yes) or yes) or "false"
	end
	cx.blocks[p] = dbg(st)
		.. lifted_flush(cx.lifted)
		.. ("sh:run_pipeline({%s}, %s, {%s}%s)"):format(
			table.concat(frags, ", "), st.negate and "true" or "false", table.concat(inproc, ", "),
			(EF.lifted_names and #EF.lifted_names > 0) and ", __upv_get, __upv_set" or "")
		.. post
		.. ecs
		.. ("; pc = %d"):format(after)
	return p
end

-- ${…} operators with no side effect and no error output (safe to expand in the PARENT
-- for a spawned `ext args &`): plain, defaults/alternates, trims, replacements, case ops
local BG_PURE_PEXP = { [""] = 1, ["-"] = 1, [":-"] = 1, ["+"] = 1, [":+"] = 1, ["#"] = 1, ["##"] = 1,
	["%"] = 1, ["%%"] = 1, ["/"] = 1, ["//"] = 1, ["^"] = 1, ["^^"] = 1, [","] = 1, [",,"] = 1 }
-- statement handler: background (split out of flatten_stmt; see H)
H.background = function(cx, st, after)
	local t = st.t
	-- cmd & : fork, run the COMPILED command in the child; the parent records $! + the
	-- job and continues with status 0. Reuses the fragment mechanism (the child is a
	-- subprogram). Gated to trap-free programs — a forked child otherwise resets caught
	-- signal traps (interp-side signal machinery). Flush lifted operands so the child
	-- (which reads sh) sees current values; no reload (the parent's copy is unaffected).
	-- a REAL-signal trap must be reset in the child (interp's signal machinery); pseudo
	-- traps don't reach it (no EXIT on _exit, ERR/DEBUG scoped out by in_subprogram)
	if EF.bg_trap_block then
		return cx.delegate(st, after)
	end
	-- bash doesn't run ERR (even under errtrace) for the async job's OWN top command —
	-- only for commands nested in a job that's a group/subshell/… — so a simple/pipeline
	-- job compiles with its direct command errexit/ERR-exempt (as `! cmd` does).
	local topexempt = st.cmd.t == "simple" or st.cmd.t == "pipeline"
	local id = emit_fragment({ require("runtime").bg_tail_stmt(st.cmd) }, topexempt)
	if not id then
		return cx.delegate(st, after)
	end
	local c1 = st.cmd -- best-effort command text for the job table
	while c1 and c1.t == "pipeline" and c1.cmds do
		c1 = c1.cmds[1]
	end
	local dtext = require("deparse").command_text(st.cmd) -- (the job as bash's print_cmd.c shows it)
	local cmdstr = (dtext ~= "" and dtext) or st.text
		or (c1 and c1.words and c1.words[1] and c1.words[1].parts[1] and c1.words[1].parts[1].lit)
		or "job"
	-- a lone simple command naming an EXTERNAL (not a builtin/function) is the child's
	-- last act: the child execs it in place instead of spawning (bash does the same)
	local ext = false
	local sc = st.cmd
	if sc.t == "simple" and sc.words and sc.words[1] then
		local c = full_lit(sc.words[1])
		if c == nil then
			ext = true -- dynamic word: rt.exec_dynamic disarms it unless it resolves to an external
		else
			ext = c ~= "" and not cx.funcflags[c] and not (cx.inlinefns and cx.inlinefns[c])
				and not require("interp").BUILTINS[c] and not emit_redir_funcs[c]
		end
	end
	-- Fast path: a literal external whose words are PURE (bash expands them in the child,
	-- so nothing with a side effect — $(…), ${x:=…}, arith assignment — may move to the
	-- parent) and no redirects/assignments: build argv here and spawn, no fork at all. A
	-- raise while expanding (set -u) or a spawn the runtime declines takes the fork path.
	local spawn = nil
	if ext and not sc.redirs and not sc.assigns then
		local pure = true
		for _, w in ipairs(sc.words) do
			for _, pt in ipairs(w.parts or {}) do
				if pt.cmdsub or pt.procsub or pt.backtick or pt.arithast
					or (pt.arith and (not safe_arith(pt.arith) or arith_side_effect(safe_arith(pt.arith))))
					or (pt.pexp and not BG_PURE_PEXP[pt.pexp.op or ""])
					or pt.special == "!" or pt.special == "_"
				then
					pure = false
				end
			end
		end
		if pure then
			local builder = field_argv(sc.words, 1, cx.lifted, "rt.cstr(%s)")
			if builder then
				spawn = builder
			end
		end
	end
	local fork = ("sh:run_background(cs_%d, %q, %s, %s, %s)"):format(id, cmdstr, ext and "true" or "false",
		st.cmd.t == "subshell" and "true" or "false", st.cmd.t == "simple" and "true" or "false")
	local body = fork
	if spawn then
		body = ("do local __ok, __a = pcall(function() %s; return __a end); if not (__ok and sh:spawn_bg(__a, %q)) then %s end end"):format(
			spawn,
			cmdstr,
			fork
		)
	end
	local p = cx.newpc()
	cx.blocks[p] = dbg(st) .. lifted_flush(cx.lifted) .. body .. ("; pc = %d"):format(after)
	return p
end

-- statement handler: arrayassign (split out of flatten_stmt; see H)
H.arrayassign = function(cx, st, after)
	local t = st.t
	-- `a=(1 2 3)` / `a=($x)` / `a=([0]=x [k]=v)` / `a+=(…)` / `a=()`: build the element
	-- items natively — a bare word field-splits via the field engine into {val=field}
	-- entries, a keyed element renders {key,op,val} — then store via rt.arrayassign. No
	-- interp: keyed subscripts are gated to literals (resolved by arith_str/verbatim).
	if arrayassign_ok(st, cx.lifted) then
		local p = cx.newpc()
		local parts = { "local __it = {}" }
		for _, e in ipairs(st.elems) do
			if e.key ~= nil then
				-- keyed value: assign-context RHS (an all-literal ~ colon-expands via
				-- rt.tilde_assign, like scalar `x=~:~`), else the ordinary word value.
				local fl = unq_full_lit(e.word)
				local valx = (fl and fl:find("~", 1, true)) and ("rt.tilde_assign(sh, %q)"):format(fl)
					or emit_word(e.word, cx.lifted)
				parts[#parts + 1] = ("__it[#__it+1] = {key=%q, op=%q, val=%s}"):format(EF.static_key(e.key), e.op, valx)
			elseif not empty_word(e.word) then
				-- a bare word field-splits and globs for an INDEXED target, but is one plain word
				-- in an ASSOCIATIVE key/value list (bash) — which one is only known at run time
				local fields = emit_fields_into("__it", e.word, cx.lifted, "{val=%s}")
				if unq_full_lit(e.word) and not unq_full_lit(e.word):find("[%*%?%[]") then
					parts[#parts + 1] = fields -- (a plain literal is the same either way)
				else
					if not parts.asq then -- (asked once per statement)
						parts.asq = true
						parts[#parts + 1] = ("local __as = sh:is_assoc(%q)"):format(st.name)
					end
					parts[#parts + 1] = ("if __as then __it[#__it+1] = {val=%s} else %s end"):format(
						emit_word(e.word, cx.lifted),
						fields
					)
				end
			end
		end
		local ec = errchk(st)
		local ecs = ec ~= "" and ("; " .. ec) or ""
		cx.blocks[p] = dbg(st)
			.. "do "
			.. table.concat(parts, "; ")
			.. ("; rt.arrayassign(sh, %q, __it, %s) end"):format(st.name, tostring(st.append and true or false))
			.. ecs
			.. ("; pc = %d"):format(after)
		return p
	end
	-- a=(…): dispatch to the array-assign runtime primitive (readonly/index checks +
	-- error-contained do_arrayassign + status/$_), NOT the exec_stmt tree-walker. Flush
	-- lifted operands to sh first (an elem may read one) and reload after (a `$((b=…))`
	-- elem may write one).
	local sync, reload = {}, {}
	for n in spairs(cx.lifted) do
		sync[#sync + 1] = ("sh:aset(%q, %s)"):format(n, lname(n))
	end
	for n in spairs(cx.lifted) do
		reload[#reload + 1] = ("%s = sh:aget(%q)"):format(lname(n), n)
	end
	local p = cx.newpc()
	local ec = errchk(st)
	local ecs = ec ~= "" and ("; " .. ec) or ""
	local pre = #sync > 0 and (table.concat(sync, "; ") .. "; ") or ""
	local post = #reload > 0 and ("; " .. table.concat(reload, "; ")) or ""
	cx.blocks[p] = dbg(st)
		.. pre
		.. ("I.run_arrayassign(sh, %s)"):format(ser(st))
		.. post
		.. ecs
		.. ("; pc = %d"):format(after)
	return p
end

-- statement handler: case (split out of flatten_stmt; see H)
H.case = function(cx, st, after)
	local t = st.t
	-- case SUBJ in pat) body ;; … esac. Evaluate the subject once (native single string),
	-- then a chain of match blocks: each tests the subject against its clause's patterns
	-- via the shared matcher (I.case_match — vars expand, quoted metachars literal,
	-- nocasematch honored) and branches to the clause body or the next match. A body
	-- flows to `after` (;;), the next body (;& = "fall"), or the next match (;;& = "test").
	if st.redirs then
		return cx.delegate(st, after)
	end -- redirs on the case: interp applies them
	-- Subject must be emittable AND free of a dynamic special var ($LINENO/$_/…) whose value
	-- the CFG can't reproduce — those run on the interp tier (compile-eventually), else the
	-- native subject would read a wrong LINENO/etc.
	if not db_word_ok(st.subject) then
		return cx.delegate(st, after)
	end
	local sv = cx.newloopvar()
	local n = #st.clauses
	local matchentry, bodyentry = {}, {}
	-- a matching body still sees the PREVIOUS $? (bash); the case's status is its last
	-- executed body's — 0 if that was empty or nothing matched. `ran` records whether the
	-- last body taken was non-empty (a ;;& can fall off the end after one).
	-- (only a ;;& can reach "no match" after a body ran, so only then is `ran` needed —
	-- each is a real local, and a big script's cases must stay under Lua's local limit)
	local ran
	for _, cl in ipairs(st.clauses) do
		if cl.term == "test" then
			ran = cx.newloopvar()
			break
		end
	end
	local nomatch = cx.newpc()
	cx.blocks[nomatch] = (ran and ("if not %s then sh.status = 0 end; "):format(ran) or "sh.status = 0; ")
		.. ("pc = %d"):format(after)
	for i = n, 1, -1 do -- back-to-front so forward targets (next body/match) already exist
		local cl = st.clauses[i]
		local btarget = (cl.term == "fall" and (i < n and bodyentry[i + 1] or after))
			or (cl.term == "test" and (i < n and matchentry[i + 1] or after))
			or after
		-- an empty body that ENDS the case (;;) leaves 0 (the last executed body's status);
		-- ;& / ;;& pass through, the previous $? still visible (bash)
		if #cl.body == 0 and cl.term ~= "fall" and cl.term ~= "test" then
			bodyentry[i] = cx.newpc()
			cx.blocks[bodyentry[i]] = ("sh.status = 0; pc = %d"):format(btarget)
		elseif ran then
			local first = cx.flatten_list(cl.body, btarget)
			bodyentry[i] = cx.newpc()
			cx.blocks[bodyentry[i]] = ("%s = %s; pc = %d"):format(ran, tostring(#cl.body > 0), first)
		else
			bodyentry[i] = cx.flatten_list(cl.body, btarget)
		end
		local nextmatch = (i < n) and matchentry[i + 1] or nomatch
		-- Compile each pattern's glob-form and match natively (rt.glob_match); a clause
		-- with a pattern emit can't render (cmdsub/arith/${…}-op/$@/$*) keeps I.case_match.
		local globs, allok = {}, true
		for _, pat in ipairs(cl.pats) do
			local g = emit_pattern_glob(pat, cx.lifted)
			if g == nil then
				allok = false
				break
			end
			globs[#globs + 1] = g
		end
		local mp = cx.newpc()
		if allok and #globs > 0 then
			local disj = {}
			for _, g in ipairs(globs) do
				disj[#disj + 1] = ("rt.glob_match(%s, %s, __ic)"):format(sv, g)
			end
			cx.blocks[mp] = ("local __ic = sh.shopt.nocasematch and true or nil; if %s then pc = %d else pc = %d end"):format(
				table.concat(disj, " or "),
				bodyentry[i],
				nextmatch
			)
		else
			local pq = {}
			for _, pat in ipairs(cl.pats) do
				pq[#pq + 1] = ("%q"):format(pat)
			end
			cx.blocks[mp] = ("if I.case_match(sh, %s, {%s}) then pc = %d else pc = %d end"):format(
				sv,
				table.concat(pq, ", "),
				bodyentry[i],
				nextmatch
			)
		end
		matchentry[i] = mp
	end
	if st.line then
		EF.cur_line = st.line
		EF.cur_cline = st.cline or st.line
	end -- clause flattening moved it; restore for $LINENO in the subject
	local subjp = cx.newpc()
	cx.blocks[subjp] = dbg(st)
		.. ("%s = %s; %spc = %d"):format(
			sv,
			emit_word(st.subject, cx.lifted),
			ran and (ran .. " = false; ") or "",
			n > 0 and matchentry[1] or nomatch
		)
	return subjp
end

build_cfg = function(stmts, lifted, funcflags, inlinefns, toplevel)
	-- per-CFG compile state, passed explicitly to the module-level statement handlers (H)
	local cx = { stmts = stmts, lifted = lifted, funcflags = funcflags, inlinefns = inlinefns, toplevel = toplevel }
	emit_toplevel = cx.toplevel and true or false -- gates top-level-only ERR firing (see errchk)
	-- each block remembers the source line being compiled when it was written (cx.pcline)
	local pcline = {}
	cx.pcline = pcline
	cx.blocks = setmetatable({}, {
		__newindex = function(t, k, v)
			rawset(t, k, v)
			pcline[k] = EF.cur_line
		end,
	})
	cx.loopPc, cx.stmtPc = {}, {}
	cx.npc = 0
	function cx.newpc()
		local p = cx.npc
		cx.npc = cx.npc + 1
		return p
	end

	cx.DONE = cx.newpc()
	cx.blocks[cx.DONE] = "break"

	-- Compile-time loop stack for break/continue: each entry is { brk = pc to exit
	-- the loop, cont = pc to re-test/advance }. `break N` / `continue N` jump to the
	-- Nth-innermost enclosing loop — a compile-time decision, so they become native
	-- jumps (no runtime unwind). loopvars are run()-level status holders (one per
	-- command-condition while), declared 0 and used to give the loop bash's exit
	-- status (last body command, or 0). Both are returned for assemble to declare.
	cx.loopstack, cx.loopvars, cx.loopinit = {}, {}, nil
	function cx.newloopvar(init) -- (init: its value on entry to run — else 0)
		local v = "__lw" .. #cx.loopvars
		cx.loopvars[#cx.loopvars + 1] = v
		if init then
			cx.loopinit = cx.loopinit or {}
			cx.loopinit[v] = init
		end
		return v
	end
	-- Stack of subshell exit pcs (subshell_exit). `return` inside a subshell exits the
	-- subshell with that status (like `exit`), so it targets this — not the function's
	-- DONE, which in the forked child would return PAST the subshell.
	cx.subexit = {}



	-- Delegate a cold statement to the shared interpreter on a baked AST node. Lifted
	-- locals are synced to `sh` before and reloaded after, so the interpreter sees
	-- current values and picks up any it changed (delegated statements are cold, so
	-- this sync costs nothing). This is how the compiled tier reaches feature parity
	-- without re-implementing the word engine in generated code.
	-- `opts` (optional) swaps the interp delegation for a compiled dispatch that reuses this
	-- wrapper's control-flow-signal translation: opts.prelude is emitted first (e.g. building
	-- __a, a native argv), and opts.callee(opts.callargs) replaces I.exec_stmt(sh, ser(st)).
	-- Used by the dynamic command word (rt.exec_dynamic on a field-engine-built argv).
	--local redirected_compound -- forward: defined with the redirect compilers below  (now a cx field)
	function cx.delegate(st, after, opts)
		-- a redirected compound (`for … done <f`) compiles its body instead of delegating
		if not opts and st.redirs then
			local rp = cx.redirected_compound(st, after)
			if rp then
				return rp
			end
		end
		if EF.stats and not opts then -- opt-in census of what still delegates (tools/…)
			EF.stats[#EF.stats + 1] = st.t .. "@" .. debug.getinfo(2, "l").currentline
		end
		local p = cx.newpc()
		local prelude = opts and opts.prelude
		local callee = (opts and opts.callee) or "I.exec_stmt"
		local callargs = (opts and opts.callargs) or ("sh, %s, __noop"):format(ser(st))
		local sync_in, sync_out = {}, {}
		for n in spairs(cx.lifted) do
			sync_in[#sync_in + 1] = ("sh:aset(%q, %s)"):format(n, lname(n))
		end
		-- opts.upv_keep: the callee is a fragment compiled WITH the upvalue lift set — it
		-- wrote those upvalues directly, so reloading them from sh would clobber its writes.
		local keep = opts and opts.upv_keep and EF.lifted_set or {}
		for n in spairs(cx.lifted) do
			if not keep[n] then
				sync_out[#sync_out + 1] = ("%s = sh:aget(%q)"):format(lname(n), n)
			end
		end
		-- errexit: a delegated errexit-relevant statement (interp's exec_stmt doesn't
		-- fire it — exec_list does) gets the guard here. Compounds (if/for/case) fire
		-- errexit for their inner commands inside exec_stmt already, so they're excluded.
		local ec = errchk(st)
		-- CONTROL FLOW THROUGH DELEGATION: a delegated `eval break`, a dynamic command
		-- word that resolves to break/continue/return (`b=break; $b`), or a delegated
		-- compound (case/pipeline) containing one, raises a __curse_break/continue/return
		-- from the interpreter. The compiled CFG is pc-based (no Lua loop to unwind to),
		-- so unguarded it would escape run() entirely. When this delegate sits inside a
		-- compiled loop or function, wrap exec_stmt in a pcall and translate the signal
		-- into the native pc jump the corresponding literal keyword would make. loopdepth/
		-- calldepth are set to the compile-time nesting first, so the interpreter's break/
		-- continue/return actually FIRE (they gate on "is there an enclosing loop/func").
		local inloop, infunc = #cx.loopstack > 0, not cx.toplevel
		-- a `$( … )` body is a CFG of its own, but its return/break/continue belong to where
		-- the substitution sits: a function (or not), a loop (or not)
		local cs_ld
		if EF.cs_active and not inloop then
			infunc = infunc and EF.cs_in_func and true or false
			cs_ld = EF.cs_in_loop and 1 or 0
		end
		-- opts.redir (a redir_conds expression) wraps the compiled callee in install/restore:
		-- the redirs apply around the dispatch (a failed one -> status 1, no call), then restore.
		local redir = opts and opts.redir
		-- opts.redir_body: the callee is a compound's compiled BODY. Like interp's compound
		-- redirect: builtins write the (redirected) fd 1 directly while it runs, the fds are
		-- restored even when the body raises (exit / errexit / a break-continue-return signal),
		-- and a failed redirect runs opts.redir_fail (ERR/errexit) instead of the body.
		local rbody = opts and opts.redir_body
		local so_in = (rbody and rbody.stdout and "sh.out = io.write; " or "")
			.. (rbody and rbody.stdin and "sh.stdin_redir = (sh.stdin_redir or 0) + 1; " or "")
		local si_out = rbody and rbody.stdin and "sh.stdin_redir = sh.stdin_redir - 1; " or ""
		local rfail = rbody and rbody.fail and ("; " .. rbody.fail) or ""
		local function callwrap()
			if rbody then
				return ("do local __rs, __so = {}, sh.out; if %s then %slocal __ok, __e = pcall(%s, %s); %ssh.out = __so; rt.redir_restore(__rs); if not __ok then error(__e, 0) end else rt.redir_restore(__rs); sh.status = 1%s end end"):format(
					redir,
					so_in,
					callee,
					callargs,
					si_out,
					rfail
				)
			end
			if redir then
				return ("do local __rs = {}; if %s then %s(%s) else sh.status = 1 end; rt.redir_restore(__rs) end"):format(
					redir,
					callee,
					callargs
				)
			end
			return ("%s(%s)"):format(callee, callargs)
		end
		if not (inloop or infunc) then -- top level, no loop: nothing to catch (interp no-ops)
			local out = {}
			for _, s in ipairs(sync_in) do
				out[#out + 1] = s
			end
			if cs_ld then -- (a raised break/continue leaves the $( … ): its capture restores this)
				out[#out + 1] = ("sh.loopdepth = %d"):format(cs_ld)
			end
			if prelude then
				out[#out + 1] = prelude
			end
			out[#out + 1] = callwrap()
			for _, s in ipairs(sync_out) do
				out[#out + 1] = s
			end
			if ec ~= "" then
				out[#out + 1] = ec
			end
			out[#out + 1] = ("pc = %d"):format(after)
			cx.blocks[p] = table.concat(out, "; ")
			return p
		end
		local o = { "do", table.concat(sync_in, "; ") }
		if prelude then
			o[#o + 1] = prelude
		end
		o[#o + 1] = "local __sl, __sc = sh.loopdepth, sh.calldepth"
		if inloop then
			o[#o + 1] = ("sh.loopdepth = %d"):format(#cx.loopstack)
		end
		if infunc then
			o[#o + 1] = "if (sh.calldepth or 0) < 1 then sh.calldepth = 1 end"
		end
		if redir then
			-- install the redirs, run the dispatch (still under pcall so a break/continue/return
			-- signal is caught below) only if they succeeded, then restore — regardless of signal.
			o[#o + 1] = "local __rs, __so, __rf = {}, sh.out, false; local __ok, __e = true, nil"
			o[#o + 1] = ("if %s then %s__ok, __e = pcall(%s, %s); sh.out = __so else sh.status = 1; __rf = true end"):format(
				redir,
				so_in,
				callee,
				callargs
			)
			o[#o + 1] = "rt.redir_restore(__rs)"
			if rfail ~= "" then -- after the restore: the ERR handler / errexit sees the original fds
				o[#o + 1] = "if __rf then " .. rfail:sub(3) .. " end"
			end
		else
			o[#o + 1] = ("local __ok, __e = pcall(%s, %s)"):format(callee, callargs)
		end
		o[#o + 1] = "sh.loopdepth, sh.calldepth = __sl, __sc"
		o[#o + 1] = table.concat(sync_out, "; ")
		o[#o + 1] = ("if __ok then %spc = %d"):format(ec ~= "" and (ec .. "; ") or "", after)
		o[#o + 1] = 'elseif type(__e) == "table" then'
		local hs = {}
		if inloop then
			local brk, cont = {}, {} -- innermost-first: level 1 = nearest enclosing loop
			for i = #cx.loopstack, 1, -1 do
				brk[#brk + 1] = tostring(cx.loopstack[i].brk)
				cont[#cont + 1] = tostring(cx.loopstack[i].cont)
			end
			-- interp already set sh.status before raising (0 normal, 1/128 on a bad arg);
			-- leave it — the loop's exit status is the break/continue command's, like bash.
			hs[#hs + 1] = ("if __e.__curse_break then local __lv = __e.__curse_break; if __lv > %d then __lv = %d end; pc = ({%s})[__lv]"):format(
				#cx.loopstack,
				#cx.loopstack,
				table.concat(brk, ", ")
			)
			hs[#hs + 1] = ("elseif __e.__curse_continue then local __lv = __e.__curse_continue; if __lv > %d then __lv = %d end; pc = ({%s})[__lv]"):format(
				#cx.loopstack,
				#cx.loopstack,
				table.concat(cont, ", ")
			)
		end
		if infunc then
			hs[#hs + 1] = ("%s __e.__curse_return ~= nil then sh.status = __e.__curse_return; pc = %d"):format(
				#hs > 0 and "elseif" or "if",
				cx.subexit[#cx.subexit] or cx.DONE
			)
		end
		o[#o + 1] = table.concat(hs, " ") .. " else error(__e) end"
		o[#o + 1] = "else error(__e) end"
		o[#o + 1] = "end"
		cx.blocks[p] = table.concat(o, "\n")
		return p
	end

	-- Statement types with no native compiled form yet -> always delegate.
	cx.DELEGATE = {
		parse_error = 1,
		assignlist = 1,
	}

	-- Compile one redirect's target to a native Lua expr (op + fd are already
	-- compile-time constants). Returns the expr, or nil when this redirect isn't
	-- monomorphic enough to compile — a `{var}>` named fd, a fd MOVE (`>&N-`), an
	-- expanding heredoc, a dup target that isn't a plain fd, or a FILE target that
	-- needs the field engine ($/glob/brace/tilde/split/ambiguity). The caller then
	-- delegates the whole command (honest transition; those are the defect to grind).
	cx.P = require("parser")
	cx.REDIR_FILE = { out = 1, app = 1, ["in"] = 1, clobber = 1, rw = 1, appboth = 1, outboth = 1 }
	-- One redirect -> its full rt.redir_apply[_expand] call expression, or nil to delegate the
	-- whole command (a {var}> named fd, a fd MOVE, an expanding heredoc, a dup to a dynamic fd,
	-- a brace/cmdsub/procsub/non-seg target). A FILE target that is a static literal path applies
	-- directly; an EXPANDABLE one ($/glob/~ etc.) hands mask-aware segments to redir_apply_expand
	-- (field expansion + the ambiguous-redirect check at runtime).
	function cx.redir_apply_expr(r)
		if r.fdvar then
			return nil
		end
		local op, fd = r.op, r.fd or 0
		if cx.REDIR_FILE[op] then
			-- (the word as written: r.target has its outer quotes stripped, `"$f"` -> `$f`)
			local t = r.src or r.target or ""
			if t == "" then
				return nil
			end
			if not t:find("[%$`%*%?%[~{()'\"\\]") then -- static literal path
				return ("rt.redir_apply(sh, %q, %d, %q, __rs)"):format(op, fd, t)
			end
			if t:find("{", 1, true) then
				return nil
			end -- brace expansion in the target: let interp handle it
			local ok, w = pcall(cx.P.parse_word, t)
			if not (ok and seg_native(w)) then
				return nil
			end -- cmdsub/arith/procsub/nameref target: delegate
			local segs = {}
			for i, p in ipairs(w.parts) do
				segs[#segs + 1] = emit_seg(p, i, cx.lifted, w)
			end
			return ("rt.redir_apply_expand(sh, %q, %d, {%s}, %q, __rs)"):format(op, fd, table.concat(segs, ", "), t)
		elseif op == "dup" or op == "dupin" then
			local t = r.target or ""
			if t == "-" or t:match("^%d+$") then
				return ("rt.redir_apply(sh, %q, %d, %q, __rs)"):format(op, fd, t)
			end
			return nil -- a dynamic fd, or a MOVE (`>&5-`): delegate
		elseif op == "herestring" then
			local w = cx.P.parse_word(r.word or "")
			if not emitable_word(w) then
				return nil
			end
			return ('rt.redir_apply(sh, %q, %d, (%s .. "\\n"), __rs)'):format(op, fd, emit_word(w, cx.lifted))
		elseif op == "heredoc" then
			if r.expand then
				-- an UNquoted-delimiter heredoc (<<EOF) expands its body like a double-quoted string
				-- ($var/$(cmd)/arith, no split/glob): parse it in heredoc mode and render with emit_word,
				-- exactly interp's expand_word(parse_heredoc(body, true)). A part emit_word can't render
				-- (procsub/nameref/$LINENO/…) fails emitable_word -> delegate.
				local ok, w = pcall(cx.P.parse_heredoc, r.body or "", true, r.aenv)
				if not (ok and emitable_word(w)) then
					return nil
				end
				return ("rt.redir_apply(sh, %q, %d, %s, __rs)"):format(op, fd, emit_word(w, cx.lifted))
			end
			return ("rt.redir_apply(sh, %q, %d, %q, __rs)"):format(op, fd, r.body or "")
		end
		return nil
	end
	-- Build the "install all redirs, run, restore" conditions for `st.redirs`, or nil if any redir
	-- can't be compiled (caller delegates) or the command is `exec` (whose redirs must PERSIST).
	function cx.redir_conds(st, cmd)
		if cmd == "exec" then
			return nil
		end
		local conds = {}
		for _, r in ipairs(st.redirs) do
			local e = cx.redir_apply_expr(r)
			if not e then
				return nil
			end
			conds[#conds + 1] = e
		end
		return table.concat(conds, " and ")
	end

	-- A compound command with trailing redirects (`for … done <f`, `{ …; } >out`, `if …
	-- fi 2>/dev/null`): compile its BODY as a fragment and run it in the current shell
	-- between install/restore of the redirs — no interpreter. break/continue/return in the
	-- body raise to delegate()'s cf-wrapper (cfraise), which jumps like the keyword would.
	-- nil -> caller falls back (uncompilable redir, traps, or a shape the fragment can't carry).
	cx.REDIR_COMPOUND = { forc = 1, whilec = 1, forin = 1, ["if"] = 1, andor = 1, group = 1, case = 1 }
	function cx.has_node(node, pred)
		if type(node) ~= "table" then
			return false
		end
		if pred(node) then
			return true
		end
		for _, v in pairs(node) do
			if type(v) == "table" and cx.has_node(v, pred) then
				return true
			end
		end
		return false
	end
	function cx.is_funcdef(n)
		return n.t == "funcdef"
	end
	function cx.is_return(n)
		if n.t ~= "simple" or not n.words then
			return false
		end
		local w1 = n.words[1]
		local c = w1 and w1.parts and w1.parts[1] and w1.parts[1].lit
		return c == "return" or c == "builtin" or c == "command" or c == "eval" or c == "source" or c == "."
	end
	function cx.stdout_redir(rd)
		for _, r in ipairs(rd) do
			if
				not r.fdvar
				and (
					r.op == "outboth"
					or r.op == "appboth"
					or (r.fd == 1 and (r.op == "out" or r.op == "app" or r.op == "clobber" or r.op == "dup" or r.op == "rw"))
				)
			then
				return true
			end
		end
		return false
	end
	function cx.redirected_compound(st, after)
		-- DEBUG: the body fragment has no per-command DEBUG hooks (dbg is top-level only)
		if not cx.REDIR_COMPOUND[st.t] or EF.inproc_trap_block or EF.has_debug then
			return nil
		end
		local conds = cx.redir_conds(st, nil)
		if not conds then
			return nil
		end
		-- hoisted function bodies must not inherit the raise scope; a top-level `return`
		-- (error + continue in bash) or a return reached via builtin/command/eval keeps
		-- interp's handling.
		if cx.has_node(st, cx.is_funcdef) or (cx.toplevel and cx.has_node(st, cx.is_return)) then
			return nil
		end
		local body = {}
		for k, v in pairs(st) do
			body[k] = v
		end
		body.redirs = nil
		local id = emit_fragment({ body }, false, EF.lifted_set, { loop = #cx.loopstack > 0, func = not cx.toplevel })
		if not id then
			return nil
		end
		local exitfail = EF.subshell_exit_pc and "rt.subshell_exit(1, sh)" or "error({ __curse_exit = 1 })"
		-- a failed redirect on a compound fires ERR (interp's compound-redirect path does)
		-- ($LINENO is NOT updated for the redirect — bash reports the last command's line)
		local errfire = EF.has_err and "if sh.noerr == 0 then I.fire_err_trap(sh) end; " or ""
		-- (a redirect error names the line bash is at: a top-level compound's end, else the
		-- command before it — a compound doesn't move the line itself)
		local sl = EF.cur_line
		EF.cur_line = st.top and st.redirs[1].line or cx.prev_line or sl
		local p = cx.delegate(st, after, {
			callee = "cs_" .. id,
			callargs = "sh",
			redir = conds,
			upv_keep = true,
			redir_body = {
				stdout = cx.stdout_redir(st.redirs),
				stdin = require("runtime").redirs_stdin(st.redirs), -- (async jobs inside keep it)
				fail = ("%sif sh.opt_e and sh.noerr == 0 then %s end"):format(errfire, exitfail),
			},
		})
		EF.cur_line = sl
		return p
	end

	-- Build blocks for `st`; its exit flows to pc `after`. Returns st's entry pc.
	function cx.flatten_stmt(st, after)
		local t = st.t
		if t == "noop" then
			return after
		end
		EF.cur_loopn = #cx.loopstack -- (compile_cmdsub: is this command inside a loop …
		EF.cur_infunc = not cx.toplevel -- … or a function)
		if st.line then
			cx.prev_line = EF.cur_line -- (the command before: a redirected compound's errors)
			EF.cur_line = t == "simple" and st.cline or st.line -- (a simple command: interp's rule)
			EF.cur_cline = st.cline or st.line
		end -- for $LINENO (compile-time constant)
		-- `time [-p] pipeline`: start clocks, run the statement itself, report to stderr.
		if st.timed then
			local inner = {}
			for k, v in pairs(st) do
				inner[k] = v
			end
			inner.timed, inner.timed_p = nil, nil
			local pe = cx.newpc()
			cx.blocks[pe] = ("rt.time_report(sh, %s); pc = %d"):format(tostring(st.timed_p == true), after)
			local p0 = cx.newpc()
			cx.blocks[p0] = ("rt.time_push(sh); pc = %d"):format(cx.flatten_list({ inner }, pe))
			return p0
		end
		-- break / continue [N]: a compile-time jump to the Nth enclosing loop's exit or
		-- re-test point. Both set $?=0 (bash). Outside any loop it's a no-op. A
		-- non-literal level (`break $n`) is rare — delegate it.
		local cf_op, cf_arg = resolve_cf(st)
		if cf_op == "break" or cf_op == "continue" then
			local lvl, ok = 1, true
			if st.words[cf_arg] then
				local wl = full_lit(st.words[cf_arg])
				if wl and wl:match("^%d+$") and not st.words[cf_arg + 1] then
					lvl = tonumber(wl)
				else
					ok = false
				end
			end
			if ok then
				local p = cx.newpc()
				local d = dbg(st) -- DEBUG fires before break/continue too (it's a command)
				if #cx.loopstack == 0 then
					if ((EF.fragment and cx.toplevel) or (EF.cf_raise and EF.cf_raise.loop)) and #cx.subexit == 0 then
						-- eval/source fragment: break/continue with no enclosing loop IN the fragment
						-- targets the CALLER's loop -- raise the signal (level) for the enclosing
						-- delegated cf-wrapper, exactly as interp's break/continue do.
						cx.blocks[p] = d .. (EF.cf_flush or "") .. ("error({ __curse_%s = %d })"):format(cf_op, lvl)
					elseif EF.cs_in_loop and #cx.subexit == 0 then -- (in a `$( … )` inside a loop: ends it)
						cx.blocks[p] = d .. ("error({ __curse_%s = %d })"):format(cf_op, lvl)
					else -- outside any loop: bash says so (status 0) and carries on
						cx.blocks[p] = d .. ("if not sh.opt_posix then io.stderr:write(%q) end; sh.status = 0; pc = %d"):format(
							"curse: " .. cf_op .. ": only meaningful in a `for', `while', or `until' loop\n", after)
					end
				else
					local idx = #cx.loopstack - (lvl - 1)
					if idx < 1 then
						idx = 1
					end
					local tgt = (cf_op == "break") and cx.loopstack[idx].brk or cx.loopstack[idx].cont
					if EF.fragment and lvl > #cx.loopstack and #cx.subexit == 0 then
						-- (an eval / hot-loop fragment inside the caller's loops: the levels past
						-- its own reach them — bash counts across; with none, it clamps)
						cx.blocks[p] = d .. ("if sh.loopdepth > 0 then %serror({ __curse_%s = %d }) end; sh.status = 0; pc = %d"):format(
							EF.cf_flush or "", cf_op, lvl - #cx.loopstack, tgt)
					else
						cx.blocks[p] = d .. ("sh.status = 0; pc = %d"):format(tgt)
					end
				end
				return p
			end
		elseif cf_op == "return" then
			-- `return` at the top level is an error (status 2 + diagnostic, but execution
			-- continues) — not a program exit. A compiled top level is always the main
			-- script (source runs through interp), so delegate and let interp diagnose.
			-- (`var=x return`: a posix-persistent prefix assignment — interp does that too)
			if (cx.toplevel and not EF.fragment) or (st.assigns and #st.assigns > 0)
				or (EF.cs_active and not EF.cs_in_func and #cx.subexit == 0) then -- ($(return) at top)
				return cx.delegate(st, after)
			end
			-- return [N] (incl. \return / builtin return / command return): set $? and exit
			-- the CFG. rt.return_status: N%256, or 2 + diagnostic on non-numeric; no arg → $?.
			-- inside a subshell, `return` exits the subshell (subshell_exit) with the
			-- status; otherwise it exits the function/CFG at DONE.
			local retpc = cx.subexit[#cx.subexit] or cx.DONE
			-- eval/source fragment top level: `return` propagates to the CALLER (a delegated
			-- eval's cf-wrapper) as a raised signal, like interp; a return inside a compiled
			-- subshell (subexit) still jumps locally.
			local frag_return = ((EF.fragment and cx.toplevel) or (EF.cf_raise and EF.cf_raise.func)) and #cx.subexit == 0
			local retjmp = frag_return and ((EF.cf_flush or "") .. "error({ __curse_return = sh.status })")
				or ("pc = %d"):format(retpc)
			local aw = st.words[cf_arg]
			if not st.words[cf_arg + 1] then -- at most one status WORD (pre-split)
				local d = dbg(st) -- DEBUG fires before return too
				if not aw then -- `return` with no arg → previous status
					local p = cx.newpc()
					cx.blocks[p] = d .. retjmp
					return p
				elseif word_safe(aw) then -- one field (literal/quoted): `return ""` → 2, `return 42` → 42
					local p = cx.newpc()
					cx.blocks[p] = d
						.. ("sh.status = rt.return_status(sh, %s); "):format(emit_word(aw, cx.lifted)) .. retjmp
					return p
				elseif field_word(aw, cx.lifted) then -- unquoted expansion: split — 0 fields → $?, else 1st field
					local fw = field_word(aw, cx.lifted)
					local p = cx.newpc()
					cx.blocks[p] = d
						.. ("do local __f = rt.field_split(sh, %s, %s); if #__f > 0 then sh.status = rt.return_status(sh, __f[1]) end end; "):format(
							fw.expr,
							tostring(fw.split)
						) .. retjmp
					return p
				end -- else (pexp/${…}): not intercepted — falls through (emit deopts to interp, which is correct)
			end
		elseif cf_op == "exit" then
			-- `exit [N]` inside a compiled subshell exits ONLY the subshell (bash), so jump to its
			-- subshell_exit pc with the status; otherwise raise __curse_exit, which finish() catches
			-- (sets $?, runs the EXIT trap, ends the shell) — the same signal delegation raised, so
			-- no behavioral change but no I.exec_stmt. A delegated __curse_exit inside a compiled
			-- subshell would unwind to run_trap's pcall and the child would CONTINUE, hence the
			-- subshell jump. Multi-arg (`exit a b`: too-many, non-fatal) / dynamic arg -> delegate.
			local exitp = #cx.subexit > 0 and cx.subexit[#cx.subexit] or nil
			local aw = st.words[cf_arg]
			if not st.words[cf_arg + 1] then
				local d = dbg(st)
				local statusexpr = aw
						and word_safe(aw)
						and ('rt.return_status(sh, %s, "exit")'):format(emit_word(aw, cx.lifted))
					or (not aw and "sh.status")
					or nil
				if statusexpr then
					local p = cx.newpc()
					if exitp then
						cx.blocks[p] = d .. ("sh.status = %s; pc = %d"):format(statusexpr, exitp)
					else
						cx.blocks[p] = d .. ("error({ __curse_exit = %s })"):format(statusexpr)
					end
					return p
				end
			end -- dynamic/multi-arg: fall through to delegate
		end
		if t == "dbracket" then
			-- [[ ]] : compile the and/or/not tree + leaf comparisons natively; $? = 0/1.
			-- Any leaf the compiler can't render (mixed-quote glob, procsub) -> delegate.
			-- A redirect (`[[ … ]] 2>/dev/null`) is applied around the evaluation and
			-- restored after (its only effect is to steer leaf/regex error output).
			local db_redir = nil
			if st.redirs then
				db_redir = cx.redir_conds(st, nil)
				if not db_redir then
					return cx.delegate(st, after)
				end
			end
			local function db_wrap(sbody) -- sbody sets sh.status; wrap in the redirect when present
				if not db_redir then
					return sbody
				end
				return ("do local __rs = {}; if %s then %s else sh.status = 1 end; rt.redir_restore(__rs) end"):format(db_redir, sbody)
			end
			-- `[[ L =~ R ]]` as the SOLE condition: emit_dbracket can't express =~ (it has a
			-- BASH_REMATCH side effect AND a tri-state status — 0 match / 1 no-match / 2 bad
			-- regex — that the boolean leaf model has no slot for), so compile it here via
			-- rt.regex_captures (real POSIX ERE, exactly interp's path). The RHS is rendered
			-- mask-aware by emit_regex_glob. A =~ nested inside and/or/not still delegates.
			if st.expr.kind == "binary" and st.expr.op == "=~" and db_word_ok(st.expr.l) then
				local re = EF.emit_regex_glob(st.expr.r, cx.lifted)
				if re then
					local p = cx.newpc()
					local d = dbg(st)
					local ec = errchk(st)
					local ecs = ec ~= "" and ("; " .. ec) or ""
					cx.blocks[p] = d
						.. db_wrap(
							('do local __c, __bad = rt.regex_captures(%s, %s, (sh.shopt.nocasematch and true or nil)); if __bad then sh.status = 2 else sh:array_assign("BASH_REMATCH", __c or {}, false); sh.status = __c and 0 or 1 end end'):format(
								emit_word(st.expr.l, cx.lifted),
								re
							)
						)
						.. ecs
						.. ("; pc = %d"):format(after)
					return p
				end
			end
			local cond = emit_dbracket(st.expr, cx.lifted)
			if not cond then
				return cx.delegate(st, after)
			end
			local p = cx.newpc()
			local d = dbg(st)
			local ec = errchk(st)
			local ecs = ec ~= "" and ("; " .. ec) or ""
			cx.blocks[p] = d
				.. db_wrap(("sh.status = (%s) and 0 or 1"):format(cond))
				.. ecs
				.. ("; pc = %d"):format(after)
			return p
		end
		if cx.DELEGATE[t] then
			return cx.delegate(st, after)
		end
		if t == "assign" then
			return H.assign(cx, st, after)
		elseif t == "funcdef" then
			return H.funcdef(cx, st, after)
		elseif t == "simple" then
			return H.simple(cx, st, after)
		elseif t == "arithcmd" then
			EF.acmd = "((" -- (bash's this_command_name, baked into its arith error texts)
			local r = H.arithcmd(cx, st, after)
			EF.acmd = nil
			return r
		elseif t == "forc" then
			return H.forc(cx, st, after)
		elseif t == "whilec" then
			return H.whilec(cx, st, after)
		elseif t == "forin" then
			return H.forin(cx, st, after)
		elseif t == "if" then
			return H["if"](cx, st, after)
		elseif t == "andor" then
			return H.andor(cx, st, after)
		elseif t == "subshell" then
			return H.subshell(cx, st, after)
		elseif t == "group" then
			return H.group(cx, st, after)
		elseif t == "pipeline" then
			return H.pipeline(cx, st, after)
		elseif t == "background" then
			return H.background(cx, st, after)
		elseif t == "arrayassign" then
			return H.arrayassign(cx, st, after)
		elseif t == "case" then
			return H.case(cx, st, after)
		else
			return cx.delegate(st, after) -- unknown/cold statement: run it via the interpreter
		end
	end


	cx.flatten_list = function(list, after)
		local nextpc = after
		for k = #list, 1, -1 do
			nextpc = cx.flatten_stmt(list[k], nextpc)
		end
		return nextpc
	end

	-- Top-level line-abort markers (parity with the interp's line model): each
	-- top-level statement is entered through a tiny marker that records `_ff`, the
	-- pc to fast-forward to if a div0/failglob lineabort fires — the marker of the
	-- first LATER statement on a NEW line (or DONE). run's retry loop jumps there and
	-- sets $?=1 (a "fancy goto"), so `;` is not a newline and a fatal expansion aborts
	-- only the rest of the current line, matching the interpreter. CRITICAL: each
	-- statement must FLOW INTO the next statement's marker (not its real entry), so
	-- `sh._ff` is refreshed before every statement — else a lineabort fast-forwards to a
	-- stale target and re-runs the current statement (e.g. failglob in a for-in list).
	local mark = {}
	if cx.toplevel then
		for k = 1, #stmts do
			mark[k] = cx.newpc()
		end
	end
	local nextpc = cx.DONE
	for k = #stmts, 1, -1 do
		nextpc = cx.flatten_stmt(stmts[k], cx.toplevel and (mark[k + 1] or cx.DONE) or nextpc)
		cx.stmtPc[k] = nextpc -- the statement's REAL entry
	end
	if cx.toplevel then
		-- Sync lifted vars to sh at each marker so, on a lineabort, the tier's retry
		-- wrapper can re-enter run at sh._ff with the pre-statement state intact (run
		-- re-seeds lifted from sh). Once per TOP-LEVEL statement (never in a hot loop body).
		-- Signal traps are delivered by the async VM hook (lib_cursesig.c), not polled here.
		local wb = {}
		for n in spairs(cx.lifted) do
			wb[#wb + 1] = ("sh:aset(%q, %s)"):format(n, lname(n))
		end
		local wbs = #wb > 0 and (table.concat(wb, "; ") .. "; ") or ""
		for k = 1, #stmts do
			local ff = cx.DONE
			for j = k + 1, #stmts do
				if (stmts[j].line or 0) > (stmts[k].line or 0) then
					ff = mark[j]
					break
				end
			end
			-- `set -n` (noexec): once set, the shell READS but does not execute the rest of
			-- a non-interactive script — so every later top-level statement is skipped (which
			-- also means a later `set +n` never runs). Checked here at the top-level boundary
			-- only (never in a hot loop body). opt_n is off until `set -n` actually runs.
			cx.blocks[mark[k]] = ("if sh.opt_n then pc = %d else sh._ff = %d; %spc = %d end"):format(
				cx.DONE,
				ff,
				wbs,
				cx.stmtPc[k]
			)
			cx.stmtPc[k] = mark[k] -- entry/OSR resume enters at the marker so sh._ff + state are set
		end
		return {
			blocks = cx.blocks,
			pcline = cx.pcline,
			npc = cx.npc,
			entry = mark[1] or cx.DONE,
			loopPc = cx.loopPc,
			stmtPc = cx.stmtPc,
			loopvars = cx.loopvars,
			loopinit = cx.loopinit,
			forlocals = cx.forlocals,
		}
	end
	return {
		blocks = cx.blocks,
		pcline = cx.pcline,
		npc = cx.npc,
		entry = cx.stmtPc[1] or cx.DONE,
		loopPc = cx.loopPc,
		stmtPc = cx.stmtPc,
		loopvars = cx.loopvars,
		loopinit = cx.loopinit,
		forlocals = cx.forlocals,
	}
end

-- Assemble a CFG into a Lua function string. `liftvars` (top-level only) are
-- seeded from `sh` on entry and written back on exit.
-- opts.runlocals: lifted vars DECLARED as run()-locals here (register-allocated,
-- fast in hot loops). opts.upvals: lifted vars declared at module level (shared
-- as upvalues with functions) — seeded/written-back but not re-declared. Both are
-- seeded from `sh` on entry and written back on exit (run() only).
assemble = function(cfg, sig, opts)
	opts = opts or {}
	local o = { sig }
	-- `pc` is local slot 2 in every dispatch function (a param of run; the FIRST local of a
	-- fn_x / cs_N body): rt's error prefix reads it off the stack to find the line
	if opts.fnresume then -- fn_x(sh, pc): an interpreted call may continue here at a loop
		o[#o + 1] = "  local __resume = pc ~= nil"
	elseif not opts.toplevel then
		o[#o + 1] = ("  local pc = %d"):format(cfg.entry)
	end
	if cfg.forlocals and #cfg.forlocals > 0 then -- (this activation's for-in loop states)
		o[#o + 1] = "  local " .. table.concat(cfg.forlocals, ", ")
	end
	-- register compiled function closures into sh.functions so the interpreter
	-- (reached via delegation) can call them too — full interp/compiled interop.
	for _, n in ipairs(opts.register or {}) do
		o[#o + 1] = ("  sh.functions[%q] = rt.mark_compiled(%s, %s)"):format(n, EF.upv_wrapped(fnlname(n)), fnlname(n))
	end
	-- verbatim definition source for `declare -f`/`type` (parity with the interpreter)
	if opts.funcsrc and next(opts.funcsrc) then
		o[#o + 1] = "  sh.func_src = sh.func_src or {}"
		for n, txt in spairs(opts.funcsrc) do
			o[#o + 1] = ("  sh.func_src[%q] = %q"):format(n, txt)
		end
	end
	-- definition line/file for `declare -F` under extdebug (name line file). The file is
	-- the runtime source (a compiled top level is the main script or a sourced file).
	if opts.funcline and next(opts.funcline) then
		o[#o + 1] = "  sh.func_line = sh.func_line or {}; sh.func_file = sh.func_file or {}; sh.func_bline = sh.func_bline or {}"
		for n, ln in spairs(opts.funcline) do
			o[#o + 1] = ('  sh.func_line[%q] = %d; sh.func_bline[%q] = %d; sh.func_file[%q] = rt.def_source(sh)'):format(
				n, ln[1], n, ln[2], n)
		end
	end
	for _, n in ipairs(opts.runlocals or {}) do
		o[#o + 1] = ("  local %s = sh:aget(%q)"):format(lname(n), n)
	end
	-- a function's lifted locals: loaded by their `local` statement, never written back (the
	-- call's local frame is dropped on return; a `local` that failed — readonly — isn't ours)
	for _, n in ipairs(opts.fnlocals or {}) do
		o[#o + 1] = ("  local %s = 0LL"):format(lname(n))
	end
	if opts.fnresume then -- (resumed mid-call: its lifted locals come from sh; else the entry)
		local seeds = {}
		for _, n in ipairs(opts.fnlocals or {}) do
			seeds[#seeds + 1] = ("%s = sh:aget(%q)"):format(lname(n), n)
		end
		o[#o + 1] = ("  if __resume then %s else pc = %d end"):format(
			#seeds > 0 and table.concat(seeds, "; ") or "", cfg.entry)
	end
	for _, n in ipairs(opts.upvals or {}) do
		o[#o + 1] = ("  %s = sh:aget(%q)"):format(lname(n), n)
	end
	-- per-loop status holders (while-command loops): plain native locals, init 0.
	for _, v in ipairs(cfg.loopvars or {}) do
		o[#o + 1] = ("  local %s = %s"):format(v, cfg.loopinit and cfg.loopinit[v] or 0)
	end
	-- pc stays a plain LOCAL (register-allocated, fast in hot loops). A div0/failglob
	-- lineabort thrown from compiled code is caught by the tier's retry wrapper, which
	-- re-enters run at sh._ff — the markers wrote lifted state + sh._ff back per
	-- top-level statement, so no closure/upvalue boxing (which would slow hot loops).
	if opts.toplevel then
		o[#o + 1] = ("  pc = pc or %d"):format(cfg.entry)
	end
	o[#o + 1] = "  while true do"
	-- a loop's head checks for preemption (a background job whose CPU slice ran out
	-- yields there: rt.preempt) — in a trace the load is hoisted, ~free
	local heads = {}
	for _, hp in pairs(cfg.loopPc or {}) do
		heads[hp] = true
	end
	for p = 0, cfg.npc - 1 do
		o[#o + 1] = ("    %s pc == %d then %s%s"):format(p == 0 and "if" or "elseif", p,
			heads[p] and "if __pre[0] ~= 0 then rt.preempt() end " or "", cfg.blocks[p])
	end
	o[#o + 1] = '    else error("curse: internal error: no block for pc " .. tostring(pc)) -- (never spin)'
	o[#o + 1] = "    end"
	o[#o + 1] = "  end"
	for _, n in ipairs(opts.runlocals or {}) do
		o[#o + 1] = ("  sh:aset(%q, %s)"):format(n, lname(n))
	end
	for _, n in ipairs(opts.upvals or {}) do
		o[#o + 1] = ("  sh:aset(%q, %s)"):format(n, lname(n))
	end
	o[#o + 1] = "end"
	-- pc -> source line, for error-message prefixes (read only on the error path)
	local fname = sig:match("^local function ([%w_]+)") or sig:match("^([%w_]+) = function")
	if fname and cfg.pcline then
		local lt = {}
		for p = 0, cfg.npc - 1 do
			local ln = cfg.pcline[p]
			if ln and ln > 0 then
				lt[#lt + 1] = ("[%d]=%d"):format(p, ln)
			end
		end
		if #lt > 0 then -- (a function's also names itself: its errors carry its file's label)
			o[#o + 1] = ("rt.pcline(%s, {%s}%s)"):format(fname, table.concat(lt, ","),
				opts.shname and (", %q"):format(opts.shname) or "")
		end
	end
	return table.concat(o, "\n")
end

-- The CFG compiler is a subset. Throw for anything it can't faithfully compile,
-- so cache.lua/tier fall back to the interpreter (the semantic oracle) rather
-- than miscompiling. As coverage grows these gates are removed one by one.
local function assert_compilable(stmts)
	for _, st in ipairs(stmts) do
		local t = st.t
		if t == "parse_error" then
			error("curse-nocompile: parse_error (deferred)")
		elseif t == "arithcmd" then
			error("curse-nocompile: (( )) command")
		elseif t == "andor" then
			error("curse-nocompile: && / || list")
		elseif t == "pipeline" then
			error("curse-nocompile: pipeline")
		elseif t == "case" then
			error("curse-nocompile: case")
		elseif t == "group" then
			error("curse-nocompile: group")
		elseif t == "subshell" then
			if st.redirs then
				error("curse-nocompile: subshell with redirs")
			end
			assert_compilable(st.body) -- bare ( body ) compiles: fork + bounded sub-CFG
		elseif t == "dbracket" then
			error("curse-nocompile: [[ ]]")
		elseif t == "arrayassign" then
			error("curse-nocompile: array assign")
		elseif t == "assign" and (st.index or st.append) then
			error("curse-nocompile: array/append assign")
		elseif t == "whilec" then
			if st.negate or cond_arith(st.cond) == nil then
				error("curse-nocompile: while/until cond")
			end
			assert_compilable(st.body)
		elseif t == "if" then
			for _, cl in ipairs(st.clauses) do
				if cl.cond ~= nil and cond_arith(cl.cond) == nil then
					error("curse-nocompile: if cond")
				end
				assert_compilable(cl.body)
			end
		elseif t == "forc" or t == "forin" or t == "funcdef" then
			assert_compilable(st.body)
		elseif t == "simple" then
			if st.redirs then
				error("curse-nocompile: redirection")
			end
			local w1 = st.words[1]
			local cmd = w1 and w1.parts[1] and w1.parts[1].lit
			local BUILTIN = {
				test = 1,
				["["] = 1,
				exit = 1,
				cd = 1,
				unset = 1,
				set = 1,
				shift = 1,
				read = 1,
				export = 1,
				declare = 1,
				typeset = 1,
			}
			if BUILTIN[cmd] then
				error("curse-nocompile: builtin " .. cmd)
			end
		end
	end
end

-- Aliases compile when their effect is STATICALLY known. The parser (sh-less) expands
-- them as a function of the source text: alias/unalias/`shopt ±s expand_aliases` apply from
-- the NEXT line (bash parses a line before running it), and each $(…) body carries the
-- alias state of its line. That model is exact only when every alias-affecting command is
-- a TOP-LEVEL simple command (runs unconditionally, in order) with fully literal operands,
-- and no eval/source can add more. Anything else — inside a function/compound/pipeline,
-- `alias "$x"`, `shopt -s $opt`, eval/source — refuses (the interpreter's live per-line
-- parse gets it right). Returns: "none" (no alias use), "static", or "dynamic".
local ALIAS_CMDS = { alias = 1, unalias = 1, shopt = 1 }
local function static_lit(w)
	if not w or not w.parts then
		return false
	end
	for _, p in ipairs(w.parts) do
		if p.lit == nil then
			return false
		end
	end
	return true
end
local function alias_cmd(st)
	if st.t ~= "simple" or not st.words or not st.words[1] then
		return nil
	end
	local w1 = st.words[1].parts
	local c = #w1 == 1 and not w1[1].q and w1[1].lit
	if not c or not ALIAS_CMDS[c] then
		return nil
	end
	if c == "shopt" then -- only an expand_aliases toggle is alias-affecting
		local hit, dyn = false, false
		for j = 2, #st.words do
			if not static_lit(st.words[j]) then
				dyn = true
			elseif st.words[j].parts[1].lit == "expand_aliases" then
				hit = true
			end
		end
		if not (hit or dyn) then
			return nil
		end
		return dyn and "dynamic" or "static"
	end
	for j = 2, #st.words do
		if not static_lit(st.words[j]) then
			return "dynamic"
		end
	end
	return "static"
end
local function scan_alias_nested(node)
	if type(node) ~= "table" then
		return false
	end
	if node.t == "simple" and alias_cmd(node) then
		return true
	end
	for _, v in pairs(node) do
		if type(v) == "table" and scan_alias_nested(v) then
			return true
		end
	end
	return false
end
local function scan_alias(stmts)
	local kind = "none"
	for _, st in ipairs(stmts or {}) do
		local a = alias_cmd(st)
		if a == "dynamic" then
			return "dynamic"
		elseif a == "static" then
			kind = "static"
			if st.redirs or st.assigns then
				return "dynamic" -- `alias x=y >f` / `X=1 alias …`: keep it simple
			end
		elseif st.t ~= "simple" and scan_alias_nested(st) then
			return "dynamic" -- conditional / function-scoped / pipeline-stage alias command
		end
	end
	return kind
end
function M.emit(ast, opts)
	emit_frags, emit_frag_n = {}, 0 -- compiled `$(…)` fragments (cs_N closures) collected during build
	-- Fragment mode (eval/source, compiled at runtime): the code runs in the CALLER's
	-- execution context, so a top-level return/break/continue must RAISE its signal for
	-- the enclosing (delegated) cf-wrapper to catch, not jump to this fragment's own DONE.
	EF.fragment = opts and opts.fragment or false
	-- xtrace/verbose (`set -x`, `set -o xtrace`, `set -v`) trace per command; the compiled
	-- tier has no trace hooks, so such a program stays in the interpreter (which traces).
	if scan_xtrace(ast.stmts) then
		error("curse-nocompile: xtrace")
	end
	-- a RETURN trap fires as each function returns (one set during a call, or inherited
	-- under functrace): interp's run_function does that; compiled calls don't
	if scan_trap(ast.stmts, { RETURN = 1 }) then
		error("curse-nocompile: RETURN trap")
	end
	local alias_kind = scan_alias(ast.stmts)
	if alias_kind == "dynamic" or (alias_kind == "static" and scan_dyncode(ast.stmts)) then
		error("curse-nocompile: alias expansion needs line-at-a-time parse")
	end
	EF.alias_static = alias_kind == "static"
	-- A fragment runs in the CALLER's context, where any var may carry an attribute
	-- (readonly/integer/case/nameref) the fragment's own code can't see, so force the
	-- attribute- and nameref-aware assign paths (they do the readonly check, int coercion,
	-- nameref write-through). Otherwise a compiled `eval "x=v"` would skip readonly, etc.
	EF.has_attr = EF.fragment or scan_attr(ast.stmts) -- gate compiled attribute-aware scalar assign
	EF.has_dyncode = scan_dyncode(ast.stmts) -- eval/source present → a $(…) can't assume its body's names are externals
	EF.ro_names = nil -- (this program's readonly names: computed on first need — func_locals)
	EF.frag_nameref = EF.fragment and scan_nameref(ast.stmts) -- (the fragment's own text)
	EF.has_nameref = EF.fragment or scan_nameref(ast.stmts) -- declare -n present → delegate scalar assigns
	EF.has_err = scan_trap(ast.stmts, { ERR = 1 }) -- gate compiled ERR-trap firing
	EF.has_debug = scan_trap(ast.stmts, { DEBUG = 1 }) -- gate compiled DEBUG-trap firing
	EF.funcstack = reads_debugstack(ast.stmts) -- gate FUNCNAME/BASH_SOURCE/BASH_LINENO stacks
	EF.pipestatus = reads_var(ast.stmts, "PIPESTATUS") -- gate $PIPESTATUS after simple cmds
	EF.has_trap = scan_any_trap(ast.stmts) -- gate compiled `&`/pipeline (forked child resets signal traps)
	-- in-process subshell/$(…)/pipeline-stage gate: only a REAL-signal trap (or DEBUG under
	-- functrace, which reaches into subshells) keeps them forked/delegated
	EF.inproc_trap_block = EF.has_debug and scan_functrace(ast.stmts)
	-- (`&` still forks: a real-signal trap must be reset in its child — interp's machinery)
	EF.bg_trap_block = scan_sigtrap(ast.stmts) or EF.inproc_trap_block
	local funcflags, inlinable, inlinefns = {}, {}, {}
	-- With a DEBUG/ERR trap, DON'T inline: an inlined body runs at the caller's level,
	-- where its commands would fire DEBUG/ERR that bash scopes to the (un-entered)
	-- function. A normal call fires the trap once at the call site and keeps the body
	-- silent (its build_cfg is non-toplevel).
	local no_inline = EF.has_err or EF.has_debug or EF.funcstack
	emit_redir_funcs = {}
	emit_multidef = {}
	do -- a name defined by more than one top-level funcdef can't be a single hoisted fn_x;
		-- neither can a function whose name is `unset` (the call after the unset must fail).
		local seen, unset = {}, {}
		local BUILTINS = require("interp").BUILTINS
		for _, st in ipairs(ast.stmts) do
			if st.t == "funcdef" then
				if seen[st.name] then
					emit_multidef[st.name] = true
				else
					seen[st.name] = true
				end
				-- A function shadowing a builtin must dispatch in PROGRAM ORDER: a call to the
				-- name BEFORE its definition runs the builtin, and `set -o posix` forbids
				-- redefining a special builtin at all. A single hoisted fn_x (defined at load,
				-- before any statement) can't model either — so delegate the def AND its calls
				-- to the interpreter, the oracle for builtin-vs-function resolution.
				if BUILTINS[st.name] then
					emit_multidef[st.name] = true
				end
			end
		end
		collect_unset(ast.stmts, unset)
		for name in pairs(seen) do
			if unset[name] then
				emit_multidef[name] = true
			end
		end
		collect_nested_funcdefs(ast.stmts, emit_multidef, true) -- nested defs + their calls delegate
		-- route every delegated-function name (redef/unset/nested) through the same
		-- def-and-call delegation the def-redirect path uses.
		for name in pairs(emit_multidef) do
			emit_redir_funcs[name] = true
		end
	end
	for _, st in ipairs(ast.stmts) do
		if st.t == "funcdef" then
			-- A function with a DEFINITION redirect (`f(){…} >&2`) applies that redirect per
			-- call (target re-evaluated each time) — interp's run_function does this; a compiled
			-- fn_x can't. Delegate the funcdef AND its calls to the interpreter. Same for a
			-- redefined name: interp registers each body in sh.functions in program order.
			if st.redirs or emit_multidef[st.name] then
				emit_redir_funcs[st.name] = true
			else
				funcflags[st.name] = func_flags(st.body)
				if not no_inline and inlinable_body(st.body) then
					inlinable[st.name] = true
					inlinefns[st.name] = st.body
				end
			end
		end
	end
	EF.inlinefns = inlinefns -- (inl_sync: a non-spliced call of one of these)
	-- Lift purely-arith vars to native int64. A var touched by no OUT-OF-LINE
	-- function becomes a run()-LOCAL (register-allocated — fast in hot loops); a
	-- direct call to an inlinable function is spliced in, so its var access counts
	-- as run() access. A var reached through a non-inlined function becomes a
	-- module-level UPVALUE both run() and that function's closure see (no hash
	-- lookup, no desync) — it can't be register-held across a loop, but such vars
	-- are updated per-call, not per-hot-iteration. Every fn_x is still emitted (for
	-- indirect/dynamic dispatch).
	-- No lifting in a fragment: a lifted native-int64 local would neither see nor sync the
	-- caller's real sh var (which may be readonly/exported), so keep every var in sh.
	local lifted, lift_disq, lift_localed = {}, {}, {}
	if not EF.fragment then
		lifted, lift_disq, lift_localed = analyze_lift(ast)
	end
	local funcTouched = {}
	collect_funcvars(ast.stmts, funcTouched, inlinable)
	-- Fragment-local lifting (emit_fragment): a var assigned only inside fragments
	-- (subshell / $(…) / pipeline-stage bodies) never lifts in run(), but can be a
	-- register local of the fragment if nothing anywhere makes its value non-numeric
	-- (disq/local'd) and no function reads it via sh. Off with eval/source/namerefs.
	EF.frag_lift_ok = nil
	if not EF.fragment and not EF.has_nameref and not scan_dyncode(ast.stmts) then
		EF.frag_lift_ok = function(n)
			return not lift_disq[n] and not lift_localed[n] and not funcTouched[n]
		end
	end

	-- Subshell in-process call-graph safety. A `( … )` that calls a user function runs
	-- fork-free IFF the function needs no real child: no exec/&/special/dynamic-command,
	-- and it only calls other SAFE functions. Its shell-var mutations are copy-isolated by
	-- subshell_run; its native-int64 (lifted) mutations are swap-saved by the caller — so
	-- state has full parity. Delegated functions (redef/nested/builtin-shadow) run via the
	-- interpreter and may do anything → unsafe. Monotone fixpoint over the compiled funcdefs.
	do
		local unsafe = {}
		for name in pairs(emit_redir_funcs) do unsafe[name] = true end
		local bodies = {}
		for _, st in ipairs(ast.stmts) do
			if st.t == "funcdef" and funcflags[st.name] then bodies[st.name] = st.body end
		end
		local changed = true
		while changed do
			changed = false
			for name, body in pairs(bodies) do
				if not unsafe[name] and not EF.subshell_inproc_ok(body, unsafe) then
					unsafe[name] = true
					changed = true
				end
			end
		end
		EF.sub_unsafe_fn = unsafe
	end
	local upvals, runlocals = {}, {}
	for n in spairs(lifted) do
		if funcTouched[n] then
			upvals[#upvals + 1] = n
		else
			runlocals[#runlocals + 1] = n
		end
	end
	table.sort(upvals)
	table.sort(runlocals)
	local upset = {}
	for _, n in ipairs(upvals) do
		upset[n] = true
	end
	-- In-process subshell / `$()` native-int64 handling. An in-process fragment must share
	-- the SAME storage for a lifted var as any function it calls, or the two desync. Only
	-- UPVAL-lifted vars (funcTouched) are visible to both the fragment closure and an fn_x, so
	-- the fragment lifts exactly those (EF.lifted_set = upset) and the caller SWAP-saves them
	-- around the run for isolation — the emitted `local __sv = v_x … v_x = __sv` for `( … )`,
	-- and the __iso_cmdsub helper for `$()`; both driven by EF.lifted_names. A RUN-LOCAL lifted
	-- var is touched by no out-of-line function, so the fragment keeps it in sh (copy-isolated)
	-- and it stays register-allocated in run() — no hot-loop cost for lift-only programs.
	EF.lifted_set = upset
	EF.lifted_names = upvals
	EF.runlocal_set = {}
	for _, n in ipairs(runlocals) do
		EF.runlocal_set[n] = true
	end

	emit_frag_ctx = { funcflags = funcflags, inlinefns = inlinefns } -- context for compile_cmdsub's build_cfg

	local o = {
		'local rt = require("runtime")',
		'local I = require("interp")',
		'local bit = require("bit")',
		"local __noop = function() end",
		"local __pre = rt.preempt_flag",
	}
	if #upvals > 0 then
		local vs = {}
		for _, n in ipairs(upvals) do
			vs[#vs + 1] = lname(n)
		end
		o[#o + 1] = "local " .. table.concat(vs, ", ") -- module-level upvalues (shared with non-inlined functions)
		-- The swap game for `$()` — the expression form of an in-process subshell. `( … )`
		-- emits `local __sv = v_x; …; v_x = __sv` inline; a $() runs inside a word EXPRESSION,
		-- so it can't, and calls this instead: save every lifted upvalue, run the isolated
		-- capture, restore. One helper for the whole module (all lifted upvals every time).
		local sav = {}
		for i = 1, #upvals do
			sav[i] = "__is" .. i
		end
		local vlist, slist = table.concat(vs, ", "), table.concat(sav, ", ")
		o[#o + 1] = ("local function __iso_cmdsub(sh, cs, bt) local %s = %s; local __o = sh:capture_compiled_iso(cs, bt); %s = %s; return __o end"):format(
			slist, vlist, vlist, slist)
		-- ...and for the pipeline scheduler, which swaps them per stage at context switch.
		o[#o + 1] = ("local function __upv_get() return %s end"):format(vlist)
		o[#o + 1] = ("local function __upv_set(%s) %s = %s end"):format(slist, vlist, slist)
		-- The INTERPRETER's entry into a compiled function (what sh.functions holds). Lifted
		-- upvalues are authoritative only while compiled code runs; whenever the interpreter
		-- is running (a delegated loop/eval/dynamic call — compiled code flushed them to sh
		-- first), sh.vars is the live view. So a call FROM the interpreter seeds the upvalues
		-- from sh on entry and flushes them back on exit (errors too). Without this a stale
		-- upvalue clobbers the interp's live value — e.g. a delegated `for ((x=…; x++))` whose
		-- body calls a compiled function that flushes before an eval: x never advances.
		-- Compiled-to-compiled calls use fn_x directly (fast path, upvalues already live).
		local seed, flush = {}, {}
		for _, nm in ipairs(upvals) do
			seed[#seed + 1] = ("%s = sh:aget(%q)"):format(lname(nm), nm)
			flush[#flush + 1] = ("sh:aset(%q, %s)"):format(nm, lname(nm))
		end
		o[#o + 1] = ("local function __upv_wrap(f) return function(sh, ...) %s; local ok, e = pcall(f, sh, ...); %s; if not ok then error(e, 0) end end end"):format(
			table.concat(seed, "; "), table.concat(flush, "; "))
	end
	local decls = {}
	for name in spairs(funcflags) do
		decls[#decls + 1] = fnlname(name)
	end
	-- fn_x bodies (build_cfg may register compiled `$(…)` fragments as a side effect, so
	-- assemble them into a buffer and splice after the forward-declaration line below).
	local fndefs = {}
	local fnloop, fnsrc = {}, {} -- (for OSR into a call the interpreter is running: tier)
	-- A name defined more than once shares one fn_x (the last definition wins), so a
	-- switch could run a loop pc of one body in another's CFG — never matching a
	-- block, spinning forever. Only a name with ONE definition anywhere is resumable.
	local ndefs = {}
	local function count_defs(t, seen)
		if type(t) ~= "table" or seen[t] then
			return
		end
		seen[t] = true
		if t.t == "funcdef" and t.name then
			ndefs[t.name] = (ndefs[t.name] or 0) + 1
		end
		for k, v in pairs(t) do
			if type(v) == "table" and k ~= "_srcs" then
				count_defs(v, seen)
			end
		end
	end
	count_defs(ast.stmts, {})
	for _, st in ipairs(ast.stmts) do
		if st.t == "funcdef" then
			-- keep every fn_x (indirect/dynamic dispatch); it can't see run-locals, so
			-- it lifts only the shared upvalues and is sh-direct for the rest.
			-- its own `local` integers lift into registers of fn_x (func_locals)
			EF.ro_names = EF.ro_names or EF.readonly_names(ast.stmts)
			local fl = func_locals(st, funcflags)
			local ls = upset
			if #fl > 0 then
				ls = {}
				for k in pairs(upset) do
					ls[k] = true
				end
				for _, n in ipairs(fl) do
					ls[n] = true
				end
			end
			local sv_fl = EF.fn_locals
			EF.fn_locals = #fl > 0 and ls or nil
			local cfg = build_cfg(st.body, ls, funcflags, inlinefns)
			EF.fn_locals = sv_fl
			fndefs[#fndefs + 1] = assemble(cfg, fnlname(st.name) .. " = function(sh, pc)",
				{ shname = st.name, fnlocals = fl, fnresume = true })
			if next(cfg.loopPc) and not fnloop[st.name] and ndefs[st.name] == 1 then
				fnloop[st.name] = cfg.loopPc
				fnsrc[st.name] = require("interp").deparse_func(st.name, st)
			end
		end
	end
	local funcsrc, funcline = {}, {} -- name -> verbatim definition text / def line (top-level funcdefs)
	for _, st in ipairs(ast.stmts) do
		if st.t == "funcdef" and st.deftext then
			funcsrc[st.name] = require("interp").deparse_func(st.name, st)
		end
		if st.t == "funcdef" and st.line then
			funcline[st.name] = { st.line, st.bline or st.line }
		end -- declare -F under extdebug
	end
	local top = build_cfg(ast.stmts, lifted, funcflags, inlinefns, true)
	-- Every compiled `$(…)` fragment is now registered (from fn_x bodies + the top level).
	-- Forward-declare each cs_N alongside the fn_x names so run/fn_x/nested fragments can
	-- close over them, then emit the fn_x and fragment definitions (order-independent).
	for i = 1, emit_frag_n do
		decls[#decls + 1] = "cs_" .. i
	end
	if #decls > 0 then
		o[#o + 1] = "local " .. table.concat(decls, ", ")
	end
	for _, d in ipairs(fndefs) do
		o[#o + 1] = d
	end
	for _, d in ipairs(emit_frags) do
		o[#o + 1] = d
	end
	o[#o + 1] = "local loopPc = " .. serialize(top.loopPc)
	o[#o + 1] = "local stmtPc = " .. serialize(top.stmtPc)
	o[#o + 1] = assemble(
		top,
		"local function run(sh, pc)",
		{ runlocals = runlocals, upvals = upvals, toplevel = true, funcsrc = funcsrc, funcline = funcline }
	)
	local fl = {}
	for name, lp in spairs(fnloop) do
		fl[#fl + 1] = ("[%q] = { pcs = %s, src = %q, fn = %s }"):format(name, serialize(lp), fnsrc[name],
			EF.upv_wrapped(fnlname(name)))
	end
	o[#o + 1] = ("return { run = run, loopPc = loopPc, stmtPc = stmtPc%s%s }"):format(
		EF.alias_static and ", alias_static = true" or "",
		#fl > 0 and (", fnLoop = { " .. table.concat(fl, ", ") .. " }") or ""
	)
	return table.concat(o, "\n") .. "\n"
end

M.EF = EF
return M
