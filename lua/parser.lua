-- Minimal bash parser for curse's initial subset: assignments,
-- simple commands (echo …), `for (( init; cond; step ))`, `while (( cond ))`,
-- and arithmetic expressions. Produces an AST consumed by BOTH interp.lua and
-- emit.lua. The full bash grammar is the target; this parser grows toward it.
-- Loops get a stable numeric `id` so the tier layer can name a
-- resume safepoint.
local M = {}
-- The STATIC alias state (sh-less compile parse) in effect for the line being parsed:
-- { tab = name->value } while expand_aliases is on, else nil. Stamped onto every
-- $(…)/`…` part (`aenv`) so the compiler's later parse of that body expands the same
-- aliases the enclosing line saw — the body is re-parsed from text, detached from here.
local ALIAS_ENV = nil
-- True while parsing a line whose $(…) bodies were alias-expanded AS READ (bash's posix-mode
-- parse_comsub): their parts carry `noalias`, so the body's later re-parse doesn't expand
-- the already-substituted text a second time.
local COMSUB_PREX = false
-- Posix mode for the line being parsed: inside a double-quoted ${…}, a `'` is an ordinary
-- character (bash: `set -o posix; echo "${IFS+'bar} baz"` prints 'bar baz).
local POSIX_DQ = false

-- ---- arithmetic expression parser (precedence climbing over a string) ----
-- AST: {k="num",v}, {k="var",name}, {k="bin",op,l,r}, {k="un",op,e},
--      {k="asgn",name,op,e}, {k="post",name,d}, {k="pre",name,d}
local function arith(src, nodefer)
	-- Line continuations are removed before arithmetic parsing, like bash's tokenizer:
	-- a `\<newline>` inside `$(( ))` / `(( ))` joins the lines (`\` has no meaning in
	-- arithmetic, so this is unambiguous). Bare newlines are already skipped as space.
	src = src:gsub("\\\n", "")
	-- An empty (or all-whitespace) arithmetic expression is 0 in bash: `$(( ))` -> 0,
	-- `(( ))` -> value 0 -> status 1.
	if src:match("^%s*$") then
		return { k = "num", v = "0" }
	end
	-- Arith bodies may embed expansions the arith grammar can't parse: ${x:-5},
	-- $(cmd), $((..)), `cmd`. Defer the whole thing — at eval the raw string is
	-- word-expanded and then re-parsed as pure arithmetic (nodefer). Plain $name and
	-- $digit ARE handled natively (as var/param nodes), so they aren't deferred —
	-- this keeps function inlining (which substitutes those params) working.
	-- Also defer when a `$` abuts a name character (`f$x`, `x$foo[5]`, `$x$y`):
	-- there the expansion forms part of a compound variable NAME, which bash builds
	-- by expanding first — the arith grammar can't parse the raw `$` mid-token.
	-- Also defer a `$` followed by a non-name char (`$*`, `$@`, `$?`, `$$`, `$-`…):
	-- the arith grammar handles $name/$digit/${..} natively but not these specials,
	-- so word-expand first (`$*` -> the joined params) then re-parse.
	-- bash IGNORES a `$` that immediately prefixes a quote inside arithmetic (the
	-- locale/ANSI-C quote prefix has no meaning there): `$"3"` -> `"3"` (a strippable
	-- pair below), `$'3'` -> `'3'` (single quotes kept -> the tokenizer errors, as
	-- bash does). Only when the expression has no ${…}/$(…)/`…` to expand as a whole.
	if not (src:find("%${") or src:find("%$%(") or src:find("`")) then
		src = src:gsub("%$([\"'])", "%1")
	end
	-- `${…}` no longer forces a whole-expression defer — primary() consumes it as an
	-- opaque operand leaf. A GLUED `${…}` (part of a compound name, `x${y}`) is still
	-- caught by `[%w_]%$` below and deferred whole, as are $(…), `…`, and $*/$@/$?/…
	-- specials — none of which primary can split into a clean operand.
	if
		not nodefer
		and (
			src:find("%$%(")
			or src:find("`")
			or src:find("[%w_]%$")
			or src:find("%$[^%w_{]")
			or src:find("}[%w_#]")
			or src:find("%$[%a_{]")
		)
	then
		-- `}[%w_#]`: a `${…}` GLUED to following chars (`${base}#a` -> 16#a, `${z}11`,
		-- `${z}xAB`) forms one compound token that must expand-then-parse whole.
		-- `%$[%a_{]` — $name / ${…}: bash substitutes the VALUE as TEXT and re-parses. The
		-- xpand eval fast-paths this (parse once, eval native) and only re-parses textually
		-- when a value isn't a plain number, so hot `(( $i < n ))` stays native. ($digit
		-- stays a native param node so function inlining keeps substituting positionals.)
		return { k = "xpand", raw = src }
	end
	-- bash strips matched double-quote PAIRS inside arithmetic (`$(( "1+2" * 3 ))`
	-- -> 1+2*3), keeping the content; a lone unmatched `"` is left in place so the
	-- tokenizer reports the error bash does. (Single quotes are never stripped.)
	-- (`let`'s arguments were already expanded and quote-removed: bash strips nothing
	-- more — `let 'x="1"+2'` is an error and an assoc_expand_once key keeps its quotes)
	if nodefer == "let" then
		nodefer = "strict"
	elseif src:find('"', 1, true) then
		local o, open = {}, false
		for k = 1, #src do
			local ch = src:sub(k, k)
			if ch == '"' then
				if open then
					open = false -- close of a pair: drop it
				elseif src:find('"', k + 1, true) then
					open = true -- open of a pair: drop it
				else
					o[#o + 1] = ch
				end -- unmatched: keep (-> tokenizer errors)
			else
				o[#o + 1] = ch
			end
		end
		src = table.concat(o)
		if src:match("^%s*$") then -- (`$(( "" ))`, a quoted blank subscript: 0 too)
			return { k = "num", v = "0" }
		end
	end
	local i, n = 1, #src
	-- bash's lasttp: where the most recently read token starts (bash reads one token
	-- ahead, and each check here looks at the next token after skip()). An error names
	-- the text from there on: `4+` -> operand expected (error token is "+").
	local lasttp
	local etxt = src:gsub("^%s+", "") -- (the expression as bash's errors print it)
	local function skip()
		while i <= n and src:sub(i, i):match("%s") do
			i = i + 1
		end
		if i <= n then
			lasttp = i
		end
	end
	local function peek()
		skip()
		return src:sub(i, i)
	end
	local function starts(s)
		skip()
		return src:sub(i, i + #s - 1) == s
	end
	local function eat(s)
		if starts(s) then
			i = i + #s
			return true
		end
		return false
	end
	local parseExpr
	-- raise one of bash's expr.c errors (a structured error; M.arith_errmsg renders it)
	local function aerr(msg)
		error({ __curse_arith = true, msg = msg, tok = lasttp and src:sub(lasttp) or "" }, 0)
	end
	local ARITHOP = "[%+%-%*/%%<>=!&|%^~%?:,%(%)]"

	local function ident()
		skip()
		local s, e = src:find("^[%a_][%w_]*", i)
		if not s then
			-- a stray non-operator char where an operand belongs, or nothing at all
			aerr("syntax error: operand expected")
		end
		i = e + 1
		return src:sub(s, e)
	end

	local parseComma
	-- read `name` then an optional `[subscript]`; returns (name, idxAST or nil,
	-- raw subscript text or nil). The raw text is captured by balancing brackets
	-- (so a quoted or non-arith key like A['x'] doesn't break the parse) and is
	-- used verbatim for ASSOCIATIVE arrays, whose (( )) subscript is a literal
	-- string key. It's also parsed as arith (best-effort) for the indexed case.
	local function nameSub()
		skip()
		local ns = i
		local nm = ident()
		if nodefer == "expanded" and starts("[") then
			-- already-expanded text (bash's EXP_EXPANDED): the subscript runs to the LAST `]`
			-- (`assoc[]]`, `assoc[x],b[$(…)]` take the key literally, nothing re-expands)
			local close = src:match(".*()%]")
			if close and close > i then
				local raw = src:sub(i + 1, close - 1)
				i = close + 1
				local ok, idx = pcall(arith, raw, "expanded")
				return nm, (ok and idx) or nil, raw
			end
		end
		if starts("[") then
			local rs = i + 1
			local depth, j = 1, i + 1
			while j <= n and depth > 0 do
				local ch = src:sub(j, j)
				if ch == "\\" then
					j = j + 1 -- (an escaped char, e.g. a quoted `\]` in an expanded key)
				elseif ch == "[" then
					depth = depth + 1
				elseif ch == "]" then
					depth = depth - 1
					if depth == 0 then
						break
					end
				end
				j = j + 1
			end
			if depth ~= 0 then
				error({ __curse_arith = true, msg = "bad array subscript", tok = src:sub(ns) }, 0)
			end
			local raw = src:sub(rs, j - 1)
			i = j + 1 -- past the ]
			local ok, idx = pcall(arith, raw) -- may fail for a quoted/non-arith key
			return nm, (ok and idx) or nil, raw
		end
		return nm, nil, nil
	end

	-- `asgn`: an assignment may start here — only at the head of a lowest-precedence
	-- expression (bash: assignment binds loosest, so `0 && B=42` is an error)
	local function primary(asgn)
		skip()
		local c = src:sub(i, i)
		if c == "(" then
			i = i + 1
			local e = parseComma()
			if not eat(")") then
				aerr("missing `)'")
			end
			return e
		end
		if (starts("++") or starts("--")) and not src:find("^[%+%-][%+%-]%s*[%a_]", i) then
			-- not a pre-increment (no name follows): two unary signs (bash: `++5` is 5)
			local sign = src:sub(i, i)
			i = i + 1
			if sign == "+" then
				return primary()
			end
			return { k = "un", op = "-", e = primary() }
		end
		if eat("++") then
			local nm, idx, ir = nameSub()
			return { k = "pre", name = nm, idx = idx, idxraw = ir, d = 1 }
		end
		if eat("--") then
			local nm, idx, ir = nameSub()
			return { k = "pre", name = nm, idx = idx, idxraw = ir, d = -1 }
		end
		if c == "-" then
			i = i + 1
			return { k = "un", op = "-", e = primary() }
		end
		if c == "+" then
			i = i + 1
			return primary()
		end
		if c == "!" then
			i = i + 1
			return { k = "un", op = "!", e = primary() }
		end
		if c == "~" then
			i = i + 1
			return { k = "un", op = "~", e = primary() }
		end
		if c == "$" then
			if nodefer == "strict" or nodefer == "expanded" then -- already-expanded text: a `$` left in it is just bad
				aerr("syntax error: operand expected")
			end
			i = i + 1
			local d = src:sub(i, i)
			if d:match("%d") then
				i = i + 1
				return { k = "param", n = tonumber(d) }
			end
			if d == "{" then
				-- ${…}: an opaque parameter-expansion OPERAND (${x:-0}, ${arr[k]}, ${#x}…).
				-- Consume the balanced braces and defer JUST this leaf — at eval it is
				-- word-expanded and arith-resolved, so the surrounding arithmetic is parsed
				-- once (and memoized) instead of re-parsing the expanded string each pass.
				local depth, j = 1, i + 1
				while j <= n and depth > 0 do
					local ch = src:sub(j, j)
					if ch == "{" then
						depth = depth + 1
					elseif ch == "}" then
						depth = depth - 1
					end
					j = j + 1
				end
				local raw = src:sub(i - 1, j - 1) -- "$" … "}"
				i = j
				return { k = "xpandleaf", raw = raw }
			end
			return { k = "var", name = ident(), dollar = true } -- $name: value substituted textually (eval checks)
		end
		if c:match("%d") then
			-- a number token is bash's: a digit then [alnum # @ _]* (base#digits, 0xHEX,
			-- octal, decimal), validated like bash's strlong so its errors match
			local s0, e = src:find("^%d[%w#@_]*", i)
			local v = src:sub(s0, e)
			local function nerr(m)
				error({ __curse_arith = true, msg = m, tok = v, expr = v }, 0)
			end
			local base, foundbase, val, k = 10, false, 0, 1
			if v:sub(1, 1) == "0" and #v > 1 then
				k = 2
				if v:sub(2, 2) == "x" or v:sub(2, 2) == "X" then
					base, k = 16, 3
				else
					base = 8
				end
				foundbase = true
			end
			while k <= #v do
				local ch = v:sub(k, k)
				if ch == "#" then
					if foundbase then
						nerr("invalid number")
					end
					if val < 2 or val > 64 then
						nerr("invalid arithmetic base")
					end
					base, val, foundbase = val, 0, true
					if not v:sub(k + 1, k + 1):match("^[%w@_]$") then
						nerr("invalid integer constant")
					end
				else
					local d
					if ch:match("%d") then
						d = tonumber(ch)
					elseif ch:match("%l") then
						d = ch:byte() - 87
					elseif ch:match("%u") then
						d = ch:byte() - (base <= 36 and 55 or 29)
					elseif ch == "@" then
						d = 62
					else
						d = 63
					end
					if d >= base then
						nerr("value too great for base")
					end
					val = val * base + d
				end
				k = k + 1
			end
			i = e + 1
			return { k = "num", v = v }
		end
		-- a name (optionally subscripted): a var, an assignment, or ++/--
		local name, idx, ir = nameSub()
		-- post ++/--
		if starts("++") then
			i = i + 2
			return { k = "post", name = name, idx = idx, idxraw = ir, d = 1 }
		end
		if starts("--") then
			i = i + 2
			return { k = "post", name = name, idx = idx, idxraw = ir, d = -1 }
		end
		-- assignment operators (3-char shifts before their 2-char prefixes)
		for _, op in ipairs(asgn and { "<<=", ">>=", "+=", "-=", "*=", "/=", "%=", "&=", "^=", "|=" } or {}) do
			if starts(op) then
				i = i + #op
				local node = { k = "asgn", name = name, idx = idx, idxraw = ir, op = op, e = parseExpr(0) }
				if op == "/=" or op == "%=" then
					skip()
					node.etxt, node.etok = etxt, lasttp and src:sub(lasttp) or ""
				end
				return node
			end
		end
		if asgn and starts("=") and src:sub(i + 1, i + 1) ~= "=" then
			i = i + 1
			return { k = "asgn", name = name, idx = idx, idxraw = ir, op = "=", e = parseExpr(0) }
		end
		return { k = "var", name = name, idx = idx, idxraw = ir }
	end

	-- binary operators by precedence (higher binds tighter), matching bash
	local BIN = {
		["||"] = 1,
		["&&"] = 2,
		["|"] = 3,
		["^"] = 4,
		["&"] = 5,
		["=="] = 6,
		["!="] = 6,
		["<"] = 7,
		["<="] = 7,
		[">"] = 7,
		[">="] = 7,
		["<<"] = 8,
		[">>"] = 8,
		["+"] = 9,
		["-"] = 9,
		["*"] = 10,
		["/"] = 10,
		["%"] = 10,
		["**"] = 11,
	}
	-- longest-match order: multi-char ops before the single-char ones they prefix
	local OPS =
		{ "**", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||", "<", ">", "+", "-", "*", "/", "%", "&", "^", "|" }

	local function nextOp()
		skip()
		-- `+=`, `<<=`, …: one assignment token (bash's tokenizer), never a binary op
		if src:find("^[%+%-%*/%%&|%^]=", i) or src:find("^<<=", i) or src:find("^>>=", i) then
			return nil
		end
		for _, op in ipairs(OPS) do
			if src:sub(i, i + #op - 1) == op then
				-- don't consume assignment "=" as comparison; "=" alone handled in primary
				return op
			end
		end
		return nil
	end

	parseExpr = function(minprec, noasgn)
		local left = primary(minprec == 0 and not noasgn)
		while true do
			local op = nextOp()
			if op == nil then
				break
			end
			local prec = BIN[op]
			if prec == nil or prec < minprec then
				break
			end
			i = i + #op
			local right = parseExpr(op == "**" and prec or prec + 1) -- ** is right-assoc
			left = { k = "bin", op = op, l = left, r = right }
			if op == "/" or op == "%" or op == "**" then
				-- (for bash's eval-time error text: the expression, and the lookahead token
				-- after the right operand — `4 / 0 ` -> error token "0 ")
				skip()
				left.etxt, left.etok = etxt, lasttp and src:sub(lasttp) or ""
			end
		end
		-- ternary c ? a : b (lowest precedence, right-assoc) — only at the top level
		if minprec == 0 and peek() == "?" then
			i = i + 1
			if peek() == ":" or i > n then
				aerr("expression expected")
			end
			local a = parseExpr(0)
			if not eat(":") then
				aerr("`:' expected for conditional expression")
			end
			if peek() == "" then
				aerr("expression expected")
			end
			local b = parseExpr(0, true) -- (the else-branch is a conditional, not an assignment)
			left = { k = "tern", c = left, a = a, b = b }
		end
		return left
	end

	-- comma operator: evaluate left-to-right, value is the last (bash/C semantics)
	parseComma = function()
		local e = parseExpr(0)
		while peek() == "," do
			i = i + 1
			e = { k = "comma", l = e, r = parseExpr(0) }
		end
		return e
	end

	local e = parseComma()
	skip()
	if i <= n then
		local c = src:sub(i, i)
		if (c == "=" and src:sub(i + 1, i + 1) ~= "=") or src:find("^[%+%-%*/%%&|%^]=", i) or src:find("^<<=", i)
			or src:find("^>>=", i) then
			aerr("attempted assignment to non-variable")
		elseif not c:match(ARITHOP) and not c:match("[%w_$]") then
			aerr("syntax error: invalid arithmetic operator") -- (after an operand: `1 @ 2`)
		end
		aerr("syntax error in expression")
	end
	return e
end
M.arith = arith
-- bash's evalerror text for an arithmetic error `err` (a structured parse error from
-- arith(), or anything else = a generic syntax error) in expression `expr`:
-- `[CMD: ]EXPR: MSG (error token is "TOK")` — EXPR loses only its leading blanks. CMD is
-- bash's this_command_name: `((`, `let`, `[[` while those evaluate (M.arith_cmd).
M.arith_cmd = nil
-- `subscript`: the text is a subscript's quoted expansion — bash shows only its \[ \] escapes
-- (the rest it protects invisibly), so drop ours before `$ ` " ' ~`
local function shown(s, subscript)
	return subscript and (s:gsub("\\([$`\"'~])", "%1")) or s
end
function M.arith_errmsg(expr, err, subscript)
	local t = shown(tostring(type(err) == "table" and err.expr or expr or ""):gsub("^%s+", ""), subscript)
	local pre = M.arith_cmd and (M.arith_cmd .. ": ") or ""
	if type(err) == "table" and err.msg then
		return pre .. t .. ": " .. err.msg .. ' (error token is "' .. shown(err.tok or "", subscript) .. '")'
	end
	return pre .. t .. ": syntax error in expression"
end

-- ---- statement parser ----
-- Captures a balanced `((` … `))` starting just after the opening `((`.
-- Grab the body of `$((…))` / `((…))` starting just after the opening `((`.
-- Counts single parens: the closing `))` is the first `)` seen at content-paren
-- depth 0 (its partner is the next char). This correctly handles nested `$( )`
-- command subs and `$(( ))` inside the arithmetic (their inner parens balance).
local function grab_dparen(src, i)
	local start, d = i, 0
	while i <= #src do
		local c = src:sub(i, i)
		if c == "(" then
			d = d + 1
			i = i + 1
		elseif c == ")" then
			if d == 0 then
				return src:sub(start, i - 1), i + 2
			end -- the closing `))`
			d = d - 1
			i = i + 1
		else
			i = i + 1
		end
	end
	error("unterminated ((")
end

-- Parse the inside of ${ … } into a word part. Plain forms stay {var}/{param}/
-- {special}; anything with an operator becomes {pexp={name, op, arg, arg2}} which
-- Shell:expand_param interprets. `arg`/`arg2` are raw text (the caller expands
-- them before applying the operator, so ${v:-$x} and pattern vars work).
-- Split ${v/pat/repl} into pat, repl. The separator is the first `/` that is
-- NOT at position 1 (bash treats a `/` right after the operator as pattern text,
-- so ${x////c} is pat=`/` repl=`c`), NOT backslash-escaped, and NOT inside
-- single/double quotes. No separator -> the whole thing is the pattern.
local function split_subst(s)
	local i, n, q = 1, #s, nil
	while i <= n do
		local c = s:sub(i, i)
		if c == "\\" then
			i = i + 2
		elseif q then
			if c == q then
				q = nil
			end
			i = i + 1
		elseif c == "'" or c == '"' then
			q = c
			i = i + 1
		elseif c == "/" and i > 1 then
			return s:sub(1, i - 1), s:sub(i + 1)
		else
			i = i + 1
		end
	end
	return s, ""
end
-- Scan a ${…} starting at the `{` (index `bi`) in `s`, returning the index just
-- past the matching `}`. Respects backslash escapes, '…'/"…" quoting (so a `}`
-- inside quotes doesn't close), and nested `{…}` — unlike a naive find("}").
local scan_cmdsub -- forward (defined below; scan_braces skips $(…) bodies with it)
-- an unclosed $( … ) is reported at the END of the input (bash); an unclosed $(( … )),
-- (( … )) or NAME=( … ) at the line it began on — this flags the former
local comsub_eof = false
-- bash 5.2 parses a $( … ) body as it reads the word, so a syntax error in it fails the
-- whole enclosing line, reported with the OUTER line: the body's first real syntax error
-- (a premature end means its `)` came too soon), or nil. Cached by body text.
local comsub_err_cache, comsub_err_n = {}, 0
local function comsub_syntax(body)
	local hit = comsub_err_cache[body]
	if hit ~= nil then
		return hit or nil
	end
	local err = false
	local ok, ast = pcall(M.parse, body)
	if not ok then
		err = type(ast) == "table" and (ast.msg or "syntax error") or tostring(ast)
	elseif ast and ast.stmts then
		for _, st in ipairs(ast.stmts) do
			if st.t == "parse_error" and not st.recoverable then
				err = tostring(st.msg or "syntax error")
				break
			end
		end
	end
	if err then
		err = err:gsub("^[%w%._/%-]+:%d+: ", "") -- (a Lua error position isn't part of it)
		if err:find("unexpected end of file", 1, true) or err:find("unexpected EOF", 1, true) then
			err = "syntax error near `)'"
		end
	end
	if comsub_err_n >= 512 then
		comsub_err_cache, comsub_err_n = {}, 0
	end
	comsub_err_cache[body] = err
	comsub_err_n = comsub_err_n + 1
	return err or nil
end
local dparen_is_arith -- forward (defined below)
-- (scan_braces: skip to just past the closing quote `q`, honoring \ when `esc`; running off
-- the end inside a quote names that quote)
local function skip_to(s, i, ns, q, esc)
	while i <= ns and s:sub(i, i) ~= q do
		i = i + ((esc and s:sub(i, i) == "\\") and 2 or 1)
	end
	if i > ns then
		error("unexpected EOF while looking for matching `" .. q .. "'")
	end
	return i + 1
end
local function scan_braces(s, bi, dq)
	local i, ns, depth = bi + 1, #s, 1
	local sq_lit = dq and POSIX_DQ
	while i <= ns and depth > 0 do
		local c = s:sub(i, i)
		if c == "\\" then
			i = i + 2
		elseif c == "$" and s:sub(i + 1, i + 1) == "'" then -- $'…': a \' inside doesn't close it
			i = i + 2
			i = skip_to(s, i, ns, "'", true)
		elseif c == "'" and not sq_lit then
			i = i + 1
			i = skip_to(s, i, ns, "'", false)
		elseif c == '"' then
			i = i + 1
			i = skip_to(s, i, ns, '"', true)
		elseif c == "{" then
			-- only a nested `${` opens a level; a bare `{` is an ordinary char, so
			-- `${X//a/{x,y,z}}` ends at the FIRST `}` (bash: replacement `{x,y,z`, then `}`)
			if s:sub(i - 1, i - 1) == "$" then
				depth = depth + 1
			end
			i = i + 1
		elseif c == "$" and s:sub(i + 1, i + 1) == "(" then
			i = scan_cmdsub(s, i + 2) -- a `}` inside $(…) doesn't close (unclosed: its error)
		elseif c == "`" then -- …nor one inside `…`
			i = i + 1
			i = skip_to(s, i, ns, "`", true)
		elseif c == "}" then
			depth = depth - 1
			i = i + 1
		else
			i = i + 1
		end
	end
	if depth > 0 then
		error("unexpected EOF while looking for matching `}'")
	end
	return i
end

local parse_paramexp
parse_paramexp = function(inner)
	if inner == "" then
		return { lit = "" }
	end
	-- ${ …}/${\t…}/${|…}/${(…}: whitespace, `|`, or `(` right after `{` is a bad
	-- substitution in bash 5.2 (ksh93 funsub `${ cmd;}`/`${|cmd;}` and zsh flag
	-- `${(m)x}`/`${(@k)a}` syntax, none of which this bash supports). Non-fatal
	-- (status 1), matching bash. (A `(` in a default VALUE like ${x:-(a)} is fine —
	-- only a `(` as the very first inner char is rejected.)
	do
		local c1 = inner:sub(1, 1)
		if c1 == " " or c1 == "\t" or c1 == "\n" or c1 == "|" or c1 == "(" or c1 == "'" then
			-- (bash has already translated any $'…' in the text it reports)
			local raw = inner:gsub("%$'([^'\\]*)'", "'%1'")
			return { pexp = { op = "badsubst", raw = raw } }
		end
		-- a $'…' name is quote-removed first (bash: `${$'x1'%t}` is `${x1%t}`)
		if inner:sub(1, 2) == "$'" then
			local k = 3
			while k <= #inner and inner:sub(k, k) ~= "'" do
				k = k + (inner:sub(k, k) == "\\" and 2 or 1)
			end
			if k <= #inner then
				return parse_paramexp(require("runtime").ansi_unescape(inner:sub(3, k - 1), true) .. inner:sub(k + 1))
			end
		end
	end
	if inner == "#" then
		return { special = "#" }
	end
	-- ${-} ${?} ${$} ${!}: the special one-char parameters (like their bare $-, $?,
	-- $$, $! forms). Handled here so `!` isn't mistaken for the indirect prefix.
	if inner == "-" or inner == "?" or inner == "$" or inner == "!" then
		return { special = inner, braced = true }
	end
	local indices, lenpfx, sharp_op = false, false, nil
	-- ${?:-x} ${$:+y} ${-+z} ${!:-w}: a one-char SPECIAL parameter followed by an operator
	-- (`${!` + an operator char is $!, not the indirect prefix). Parsed like a named param.
	local special_op = nil
	do
		local c1, c2 = inner:sub(1, 1), inner:sub(2, 2)
		-- (`$ ? -` take the other operators too; `${!#}`/`${!@}` keep `!` as the indirect
		-- prefix; bash rejects case modification on `?`/`-` but not on `$`)
		if
			(c1 == "?" or c1 == "$" or c1 == "-" or c1 == "!") and c2 ~= "" and c2:match("[:%-+=?]")
			or (c1 == "?" or c1 == "$" or c1 == "-") and c2 ~= "" and c2:match("[#%%/@]")
			or c1 == "$" and c2 ~= "" and c2:match("[%^,]")
		then
			special_op = c1
		elseif (c1 == "?" or c1 == "-") and c2 ~= "" and c2:match("[%^,]") then
			return { pexp = { op = "badsubst", raw = inner } }
		end
	end
	if special_op then
		sharp_op = nil
	elseif inner:sub(1, 1) == "!" then
		indices = true
		inner = inner:sub(2) -- ${!a[@]}
		-- after `!` (indirect/keys) another prefix operator is a bad substitution
		-- (`${!!x}`, `${!#x}` are not valid — bash errors).
		if inner == "#" then
			return { pexp = { name = "#", op = "indirect" } } -- ${!#}: the last positional
		end
		if inner:sub(1, 1) == "!" or inner:sub(1, 1) == "#" then
			return { pexp = { op = "badsubst", raw = "!" .. inner } }
		end
	elseif inner:match("^#[:%-=?+%%/^,@]") and (#inner > 2 or inner == "#:") then
		-- ${#-x} ${#:+y} ${#%0} ${#:}: `$#` with an operator (the one-char `${#-}` / `${#?}`
		-- are LENGTHS of $- / $?, below)
		sharp_op = inner:sub(2)
	elseif inner:sub(1, 2) == "##" and #inner > 2 then
		-- ${##X…}: two leading #, then more → the parameter is `#` ($#) and the rest
		-- is an operator (strip etc.) applied to its value (`${##2}` = ${#} with `#2`
		-- prefix-strip = 5). ${##} alone is length-of-$# (the `#`-prefix branch below).
		sharp_op = inner:sub(2)
	elseif inner:sub(1, 1) == "#" then
		lenpfx = true
		inner = inner:sub(2) -- ${#v} / ${#a[@]}
		-- ${#@}/${#*} are the positional-parameter COUNT, same as ${#}/$#.
		if inner == "@" or inner == "*" then
			return { special = "#" }
		end
		-- ${##} ${#?} ${#-} ${#$} ${#!}: the LENGTH of a special one-char parameter.
		if inner == "#" or inner == "?" or inner == "-" or inner == "$" or inner == "!" then
			return { special = inner, lenof = true }
		end
	end
	local name, rest
	if special_op then
		name, rest = special_op, inner:sub(2)
	elseif sharp_op then
		name, rest = "#", sharp_op
	else
		name, rest = inner:match("^([%a_][%w_]*)(.*)$")
	end
	if not name then
		name, rest = inner:match("^(%d+)(.*)$")
	end
	if not name then
		name, rest = inner:match("^([@*])(.*)$")
	end
	if not name then
		-- a lone invalid parameter char (${%}, ${.}, ${+}) is a bad substitution in
		-- bash (fails the command, status 1). Multi-char inners are left to the
		-- lenient var fallback (ksh funsubs `${ …}`/`${| …}`, special-param-plus-op
		-- like ${?@a} tolerated as empty), to match curse's prior behavior.
		-- A special `$ ? -` followed by a non-operator (`${$(…)}`, `${?x}`) is one too.
		if #inner == 1 or inner:match("^[%$?%-]") then
			return { pexp = { op = "badsubst", raw = (lenpfx and "#" or "") .. inner } } -- (${#/} as written)
		end
		return { var = inner }
	end
	-- optional [subscript]
	local index = nil
	if rest:sub(1, 1) == "[" then
		-- balance nested brackets so `${a[a[0]]}` takes `a[0]` as the subscript, not `a[0`;
		-- a quoted or escaped `]` doesn't close it (`${m["a]a"]}`, `${m[\]]}`)
		local depth, close, k = 0, nil, 1
		while k <= #rest do
			local ch = rest:sub(k, k)
			if ch == "\\" then
				k = k + 1
			elseif (ch == "'" or ch == '"') and depth > 0 then
				local e = rest:find(ch, k + 1, true)
				while e and ch == '"' and rest:sub(e - 1, e - 1) == "\\" do
					e = rest:find(ch, e + 1, true)
				end
				k = e or #rest
			elseif ch == "[" then
				depth = depth + 1
			elseif ch == "]" then
				depth = depth - 1
				if depth == 0 then
					close = k
					break
				end
			end
			k = k + 1
		end
		if close then
			index = rest:sub(2, close - 1)
			rest = rest:sub(close + 1)
		end
		if index == "" then
			return { pexp = { op = "badsubst", raw = name .. "[]" } }
		end -- ${a[]} is invalid (bash)
	end
	if indices then
		-- ${!a[@]}/${!a[*]} = keys; ${!pfx@}/${!pfx*} = var names with that prefix;
		-- ${!name} = indirect (value of the var named by name)
		-- ${!a[@]OP}: a suffix operator flips this from "keys" to INDIRECT — bash uses
		-- ${a[@]} (space-joined) as the reference name, derefs it, then applies OP.
		if index == "@" or index == "*" then
			if rest ~= "" then
				return { pexp = { name = name, op = "indirect", index = index, iop = rest } }
			end
			return { pexp = { name = name, op = "indices", index = index } }
		end
		if rest == "*" or rest == "@" then
			if not name:match("^[%a_]") then -- ${!1*} ${!@*}: prefix forms need a NAME
				return { pexp = { op = "badsubst", raw = "!" .. inner } }
			end
			return { pexp = { name = name, op = "prefix", star = (rest == "*") } }
		end
		if rest ~= "" and not rest:match("^[:%-=?+#%%/^,@]") then -- ${!_Q* } ${!a x}
			return { pexp = { op = "badsubst", raw = "!" .. inner } }
		end
		-- ${!ref OP arg}: capture the trailing operator to apply to the resolved target
		return { pexp = { name = name, op = "indirect", index = index, iop = (rest ~= "" and rest or nil) } }
	end
	if lenpfx then
		-- ${#x} / ${#a[@]} only; a trailing operator (${#a[0]/1/x}) can't combine with
		-- the length prefix — bash rejects it as a bad substitution.
		if rest ~= "" then -- (`${#@x}` is the fatal kind: bash reads it as a bad ${@…} transform)
			return { pexp = { name = name, op = "badsubst", raw = "#" .. inner, fatal = name == "@" or nil } }
		end
		return { pexp = { name = name, op = "len", index = index } }
	end
	if rest == "" then
		if index then
			return { pexp = { name = name, index = index } }
		end -- ${a[i]}
		if name:match("^%d+$") then
			return { param = tonumber(name), braced = true } -- (set -u names it `9`, not `$9`)
		end
		if name == "@" or name == "*" then
			return { special = name }
		end
		return { var = name }
	end
	local two, one = rest:sub(1, 2), rest:sub(1, 1)
	local function P(t)
		t.name = name
		t.index = index
		return { pexp = t }
	end
	if two == ":-" or two == ":=" or two == ":+" or two == ":?" then
		return P({ op = two, arg = rest:sub(3) })
	elseif one == "-" or one == "=" or one == "+" or one == "?" then
		return P({ op = one, arg = rest:sub(2) })
	elseif two == "##" then
		return P({ op = "##", arg = rest:sub(3) })
	elseif one == "#" then
		return P({ op = "#", arg = rest:sub(2) })
	elseif two == "%%" then
		return P({ op = "%%", arg = rest:sub(3) })
	elseif one == "%" then
		return P({ op = "%", arg = rest:sub(2) })
	elseif two == "//" then
		local p, r = split_subst(rest:sub(3))
		return P({ op = "//", arg = p, arg2 = r })
	elseif one == "/" then
		local p, r = split_subst(rest:sub(2))
		return P({ op = "/", arg = p, arg2 = r })
	elseif two == "^^" then
		return P({ op = "^^", arg = rest:sub(3) }) -- optional fold pattern
	elseif one == "^" then
		return P({ op = "^", arg = rest:sub(2) })
	elseif two == ",," then
		return P({ op = ",,", arg = rest:sub(3) })
	elseif one == "," then
		return P({ op = ",", arg = rest:sub(2) })
	elseif one == "@" then -- ${x@Q/U/u/L/E/…}: exactly one operator letter, else bad
		if not rest:match("^@[QEPAKaUuLk]$") then -- (checked only on a set value: `xform`)
			return P({ op = "badsubst", xform = true, raw = name .. (index and "[" .. index .. "]" or "") .. rest })
		end
		return P({ op = "@", arg = rest:sub(2) })
	elseif one == ":" then
		local body = rest:sub(2)
		if body == "" then
			return P({ op = "badsubst", raw = name .. rest })
		end -- ${x:} empty offset
		-- ${x:off:len}: split off from len at the `:` that is NOT a ternary colon.
		-- The offset is arithmetic and may contain `? :` ternaries (`${s: a?2:0 :1}`),
		-- so track the ternary depth as bash does (subst.c skip_to_delim SD_ARITHEXP:
		-- each `?` raises the skip count, each `:` while it is positive belongs to
		-- that ternary). `${x::}` -> off="" (0), len="" (0). `\` escapes the next char.
		local colon, skipcol, k = nil, 0, 1
		while k <= #body do
			local ch = body:sub(k, k)
			if ch == "\\" then
				k = k + 2
			elseif ch == "$" and body:sub(k + 1, k + 1) == "{" then
				k = scan_braces(body, k + 1) -- a nested ${…}'s `:` isn't the separator
			elseif ch == "$" and body:sub(k + 1, k + 1) == "(" then
				local ok, nk = pcall(scan_cmdsub, body, k + 2)
				k = ok and nk or k + 1
			elseif ch == "?" then
				skipcol = skipcol + 1
				k = k + 1
			elseif ch == ":" and skipcol > 0 then
				skipcol = skipcol - 1
				k = k + 1
			elseif ch == ":" then
				colon = k
				break
			else
				k = k + 1
			end
		end
		if colon then
			return P({ op = "sub", arg = body:sub(1, colon - 1), arg2 = body:sub(colon + 1) })
		end
		return P({ op = "sub", arg = body })
	end
	-- Any trailing text that is not a recognized modifier is a bad substitution
	-- (e.g. `${x|html}`, `${1abc}`, `${a b}`) — bash aborts with status 1.
	return P({ op = "badsubst", raw = name .. rest })
end
M.parse_paramexp = parse_paramexp

-- Find the `)` that closes a `$( … )` command substitution. `j` is the index of
-- the first char INSIDE the parens (just past "$("); returns the index just PAST
-- the closing `)`. Understands single/double/ANSI-C quotes, backslash escapes,
-- nested $()/${ }/$(( ))/backticks, and — crucially — `case … esac`, whose
-- pattern-terminating `)` does NOT close the substitution (`$(case x in x) …;; esac)`).
-- `onwarn(rpos, dpos, delim)` (optional): a heredoc in the body was ended by the `DELIM)`
-- form — bash warns "delimited by end-of-file"; rpos = the newline where its body reading
-- began, dpos = the closing `)` (the caller turns them into line numbers).
scan_cmdsub = function(src, j, onwarn)
	local n = #src
	local pdepth = 0 -- nested subshell / group / extglob paren depth
	local cst = {} -- stack of enclosing `case` phases: "in"|"pat"|"body"
	local patp = 0 -- paren depth WITHIN the current case pattern
	local patstart = false -- at the very start of a pattern (a leading `(` is optional)
	local wstart = true -- next char begins a word (for `#` comments and keywords)
	local hdp = {} -- heredocs opened on the current line: { delim, strip }
	local i = j
	local function skipq(close) -- skip from a quote at i to just past `close`, honoring `\`
		local k = i + 1
		while k <= n and src:sub(k, k) ~= close do
			if src:sub(k, k) == "\\" then
				k = k + 2
			else
				k = k + 1
			end
		end
		return k + 1
	end
	while i <= n do
		local c = src:sub(i, i)
		if c == "\n" and #hdp > 0 then
			local rpos = i
			-- heredoc bodies follow this line: they're text, not syntax. bash (parse_comsub):
			-- a body line that starts with the delimiter then `)` also ends it (`EOF)`), the
			-- `)` then closing the $(; a missing delimiter swallows the rest (unclosed $().
			i = i + 1
			local closed = false
			for _, hd in ipairs(hdp) do
				while true do
					if i > n then -- (bash warns about the heredoc first, at the last line)
						if onwarn then
							onwarn(rpos, n, hd.delim)
						end
						comsub_eof = true
						error("unexpected EOF while looking for matching `)'")
					end
					local le = src:find("\n", i, true) or (n + 1)
					local lstr = src:sub(i, le - 1)
					local lead = hd.strip and #lstr:match("^\t*") or 0
					local body = lstr:sub(lead + 1)
					if body == hd.delim then
						i = le + 1
						break
					end
					local rest = body:sub(1, #hd.delim) == hd.delim and body:sub(#hd.delim + 1)
					local pb = rest and rest:match("^[ \t]*()%)")
					if pb then
						i = i + lead + #hd.delim + pb - 1 -- at the `)`
						closed = true
						if onwarn then
							onwarn(rpos, i, hd.delim)
						end
						break
					end
					i = le + 1
				end
				if closed then
					break
				end
			end
			hdp = {}
			wstart = true
		elseif c == " " or c == "\t" or c == "\n" then
			i = i + 1
			wstart = true
		elseif c == "\\" then
			i = i + 2
			wstart = false
		elseif c == "(" and wstart and src:sub(i + 1, i + 1) == "(" and cst[#cst] ~= "pat"
			and dparen_is_arith(src, i + 2) then
			local _, ni = grab_dparen(src, i + 2) -- ((…)) arithmetic: its `<<` is a shift
			i = ni
			wstart = false
		elseif c == ";" then
			if src:sub(i, i + 1) == ";;" then
				if cst[#cst] == "body" then
					cst[#cst] = "pat"
					patstart = true
				end
				i = i + 2
			else
				i = i + 1
			end
			wstart = true
		elseif c == "&" then
			i = i + (src:sub(i, i + 1) == "&&" and 2 or 1)
			wstart = true
		elseif c == "|" then
			if cst[#cst] == "pat" then
				i = i + 1 -- `|` is pattern alternation, not a pipe
			else
				i = i + (src:sub(i, i + 1) == "|&" and 2 or 1)
				wstart = true
			end
		elseif c == "'" then
			i = skipq("'")
			wstart = false
			patstart = false
		elseif c == "$" and src:sub(i + 1, i + 1) == "'" then
			i = i + 1
			i = skipq("'")
			wstart = false
			patstart = false
		elseif c == '"' then
			i = i + 1
			while i <= n and src:sub(i, i) ~= '"' do
				local d = src:sub(i, i)
				if d == "\\" then
					i = i + 2
				elseif d == "$" and src:sub(i + 1, i + 2) == "((" then
					local _, ni = grab_dparen(src, i + 3)
					i = ni
				elseif d == "$" and src:sub(i + 1, i + 1) == "(" then
					i = scan_cmdsub(src, i + 2, onwarn)
				elseif d == "$" and src:sub(i + 1, i + 1) == "{" then
					i = scan_braces(src, i + 1, true)
				elseif d == "`" then
					i = i + 1
					while i <= n and src:sub(i, i) ~= "`" do
						i = i + (src:sub(i, i) == "\\" and 2 or 1)
					end
					i = i + 1
				else
					i = i + 1
				end
			end
			i = i + 1
			wstart = false
			patstart = false
		elseif c == "`" then
			i = i + 1
			while i <= n and src:sub(i, i) ~= "`" do
				i = i + (src:sub(i, i) == "\\" and 2 or 1)
			end
			i = i + 1
			wstart = false
			patstart = false
		elseif c == "$" and src:sub(i + 1, i + 2) == "((" then
			local _, ni = grab_dparen(src, i + 3)
			i = ni
			wstart = false
			patstart = false
		elseif c == "$" and src:sub(i + 1, i + 1) == "(" then
			i = scan_cmdsub(src, i + 2, onwarn)
			wstart = false
			patstart = false
		elseif c == "$" and src:sub(i + 1, i + 1) == "{" then
			i = scan_braces(src, i + 1)
			wstart = false
			patstart = false
		elseif c == "#" and wstart then
			while i <= n and src:sub(i, i) ~= "\n" do
				i = i + 1
			end -- comment to end of line
		elseif c == "(" then
			if cst[#cst] == "pat" then
				if patstart then
					patstart = false
				else
					patp = patp + 1
				end -- leading `(` is optional; else extglob/group
				wstart = false
			else
				pdepth = pdepth + 1
				wstart = true
			end
			i = i + 1
		elseif c == ")" then
			if cst[#cst] == "pat" then
				if patp > 0 then
					patp = patp - 1
					i = i + 1
				else
					cst[#cst] = "body"
					patstart = false
					i = i + 1
					wstart = true
				end -- pattern terminator
			elseif pdepth > 0 then
				pdepth = pdepth - 1
				i = i + 1
				wstart = false
			else
				-- (heredocs opened on this last line read their bodies from the lines
				-- AFTER it — the caller splices them in; see word())
				return i + 1, (#hdp > 0 and hdp or nil)
			end -- the `)` that closes the $(
		elseif c == "<" and src:sub(i + 1, i + 1) == "<" and src:sub(i + 2, i + 2) ~= "<" then
			-- `<<[-]WORD`: note the (quote-removed) delimiter; its body follows the line
			local k = i + 2
			local strip = src:sub(k, k) == "-"
			if strip then
				k = k + 1
			end
			while src:sub(k, k):match("^[ \t]$") do
				k = k + 1
			end
			local d = {}
			while k <= n do
				local ch = src:sub(k, k)
				if ch == "\\" then
					if src:sub(k + 1, k + 1) ~= "\n" then -- (`\<newline>` is a continuation)
						d[#d + 1] = src:sub(k + 1, k + 1)
					end
					k = k + 2
				elseif ch == "'" or ch == '"' then
					local e = src:find(ch, k + 1, true) or n
					d[#d + 1] = src:sub(k + 1, e - 1)
					k = e + 1
				elseif ch:match("^[ \t\n;&|()<>]$") then
					break
				else
					d[#d + 1] = ch
					k = k + 1
				end
			end
			if #d > 0 then
				hdp[#hdp + 1] = { delim = table.concat(d), strip = strip }
			end
			i = k
			wstart = false
		elseif c == "<" or c == ">" then
			i = i + (src:sub(i, i + 2) == "<<<" and 3 or 1) -- (a here-string isn't a heredoc)
			wstart = false
		else
			local a, b = src:find("^[^ \t\n;&|()<>'\"`$#\\]+", i)
			if not a then
				i = i + 1
				wstart = false -- (`$#`: a `#` inside a word isn't a comment)
			else
				local wd, was = src:sub(a, b), wstart
				wstart = false
				if cst[#cst] == "pat" then
					patstart = false
				end
				if was and wd == "case" then
					cst[#cst + 1] = "in"
				elseif wd == "in" and cst[#cst] == "in" then
					cst[#cst] = "pat"
					patstart = true
				elseif was and wd == "esac" and #cst > 0 then
					table.remove(cst)
				end
				i = b + 1
			end
		end
	end
	comsub_eof = src:sub(j, j) ~= "(" -- (`$((` unclosed: arithmetic, reported where it began)
	error("unexpected EOF while looking for matching `)'") -- unclosed $(
end

-- `$((` is arithmetic ONLY when it's a balanced `$(( expr ))` — the paren balance
-- first returns to 0 at a `)` immediately followed by another `)`. Otherwise the
-- first `(` opened a subshell (`$( (…) )`, #2337). Quote-aware.
dparen_is_arith = function(w, j0)
	local depth, j, n = 0, j0, #w
	while j <= n do
		local c = w:sub(j, j)
		if c == "\\" then
			j = j + 2
		elseif c == "'" or c == '"' then
			local q = c
			j = j + 1
			while j <= n and w:sub(j, j) ~= q do
				if w:sub(j, j) == "\\" and q == '"' then
					j = j + 2
				else
					j = j + 1
				end
			end
			j = j + 1
		elseif c == "(" then
			depth = depth + 1
			j = j + 1
		elseif c == ")" then
			if depth == 0 then
				return w:sub(j + 1, j + 1) == ")"
			end
			depth = depth - 1
			j = j + 1
		else
			j = j + 1
		end
	end
	return false
end

-- Parse a $… expansion at position i of string w; add(part) tagging it with the
-- quoted flag q; returns the next index. (q drives word-splitting downstream.)
-- ${x:-$'…'} inside "…": bash 5.2 DOES expand ANSI-C quoting in a quoted default word
-- (parse_default_quoted sets this while parsing it); elsewhere in "…" `$'` is literal.
local DQ_ANSI = false
local function parse_dollar(w, i, add, q)
	local nx = w:sub(i + 1, i + 1)
	if w:sub(i + 1, i + 2) == "((" and dparen_is_arith(w, i + 3) then
		local body, ni = grab_dparen(w, i + 3)
		add({ arith = body, q = q })
		return ni
	elseif nx == "[" then -- $[expr]: deprecated arithmetic, an alias of $(( ))
		local depth, j = 1, i + 2
		while j <= #w do
			local c2 = w:sub(j, j)
			if c2 == "[" then
				depth = depth + 1
			elseif c2 == "]" then
				depth = depth - 1
				if depth == 0 then
					break
				end
			end
			j = j + 1
		end
		add({ arith = w:sub(i + 2, j - 1), q = q })
		return j + 1
	elseif nx == "(" then
		local je = scan_cmdsub(w, i + 2) -- index just past the closing `)` (case/quote/nesting aware)
		add({ cmdsub = w:sub(i + 2, je - 2), q = q, aenv = ALIAS_ENV, noalias = COMSUB_PREX or nil, posix = POSIX_DQ or nil })
		return je
	elseif nx == '"' then
		-- $"…" locale translation: with no catalog it's just the double-quoted string.
		return i + 1 -- skip the `$`; the caller parses the following "…" normally
	elseif nx == "'" and q and not DQ_ANSI then
		-- inside "…" (or a heredoc body) `$'` is just a literal `$` followed by text
		add({ lit = "$", q = true })
		return i + 1
	elseif nx == "'" then
		-- $'…' ANSI-C quoting: a literal string with backslash escapes, no expansion.
		local j, buf = i + 2, {}
		while j <= #w do
			local c2 = w:sub(j, j)
			if c2 == "\\" then
				buf[#buf + 1] = w:sub(j, j + 1)
				j = j + 2
			elseif c2 == "'" then
				break
			else
				buf[#buf + 1] = c2
				j = j + 1
			end
		end
		add({ lit = require("runtime").ansi_unescape(table.concat(buf), true), q = true })
		return j + 1
	elseif nx == "{" then
		-- find the MATCHING } — honoring \-escapes, '…'/"…" quoting, and nested ${…}
		-- so `${var#\}}`, `${var-'}'}`, `${a:-${b}}` take the right inner text.
		local endp = scan_braces(w, i + 1, q) -- index just past the closing }
		local part = parse_paramexp(w:sub(i + 2, endp - 2))
		part.q = q
		add(part)
		return endp
	elseif nx:match("%d") then
		add({ param = tonumber(nx), q = q })
		return i + 2
	elseif nx == "#" or nx == "@" or nx == "*" or nx == "?" or nx == "$" or nx == "!" or nx == "-" then
		add({ special = nx, q = q })
		return i + 2
	else
		local s, e = w:find("^%$([%a_][%w_]*)", i)
		if s then
			add({ var = w:sub(s + 1, e), q = q })
			return e + 1
		else
			add({ lit = "$", q = q })
			return i + 1
		end
	end
end

-- Parse the inside of a "…" (everything is quoted): $ expansions + literals,
-- honoring \$ \" \\ \` escapes.
-- heredoc: a heredoc body (`"` is ordinary, `\"` stays). bt_keep: a `\"` inside a
-- `…` stays too — true for a heredoc body AND for a prompt string (bash expands both
-- with Q_DOUBLE_QUOTES, which unwraps `\"` only in a real "…" word's backquotes).
local function parse_dquote(inner, add, heredoc, bt_keep)
	bt_keep = bt_keep or heredoc
	local i = 1
	while i <= #inner do
		local c = inner:sub(i, i)
		if c == "\\" then
			-- `\` escapes $ ` \ (and " in a real "…", but NOT in a heredoc body where
			-- " is an ordinary char, so `\"` stays literal there).
			local nx = inner:sub(i + 1, i + 1)
			if nx == "\n" and not heredoc then
				i = i + 2 -- backslash-newline: line continuation (removed)
			elseif nx == "$" or (nx == '"' and not heredoc) or nx == "\\" or nx == "`" then
				add({ lit = nx, q = true })
				i = i + 2
			else
				add({ lit = "\\", q = true })
				i = i + 1
			end
		elseif c == "$" then
			-- (a heredoc body's ${x-word} keeps a $'…' in word literal — bash)
			i = parse_dollar(inner, i, heredoc and function(p)
				if p.pexp then
					p.pexp.hd = true
				end
				add(p)
			end or add, true)
		elseif c == "`" then -- `cmd` command substitution inside "…"
			-- within a backtick INSIDE double quotes, `\` also escapes `"` (unlike the
			-- `$()` form) — bash unwraps `\"`→`"`, so `"`echo \"hi\"`"` runs `echo "hi"`
			-- (not in a heredoc body or a prompt: `\"` reaches the command as is).
			local j, buf = i + 1, {}
			while j <= #inner and inner:sub(j, j) ~= "`" do
				if inner:sub(j, j) == "\\" and inner:sub(j + 1, j + 1) == "\n" then
					j = j + 2 -- (backquotes drop a \<newline> too, even inside its '…' — POSIX)
				elseif inner:sub(j, j) == "\\" and inner:sub(j + 1, j + 1):match(bt_keep and "[`$\\]" or '[`$\\"]') then
					buf[#buf + 1] = inner:sub(j + 1, j + 1)
					j = j + 2
				else
					buf[#buf + 1] = inner:sub(j, j)
					j = j + 1
				end
			end
			add({ cmdsub = table.concat(buf), q = true, backtick = true, aenv = ALIAS_ENV })
			i = j + 1
		else
			local s, e = inner:find("^[^$\\`]+", i)
			add({ lit = inner:sub(s, e), q = true })
			i = e + 1
		end
	end
end

-- A word is a list of parts, each carrying q (came from inside quotes -> not
-- word-split):  {lit=s} | {var} | {arith} | {param} | {special} | {pexp} | {cmdsub}
-- bash removes a backslash-newline (line continuation) during tokenization,
-- EVERYWHERE except inside single quotes — so a continuation splitting any token
-- vanishes (`$\<nl>?` -> `$?`, `ab\<nl>cd` -> `abcd`). Do it up front (guarded to a
-- no-op when the word has none) so parse_dollar/parse_dquote see the joined token.
local function strip_contin(w)
	if not w:find("\\\n", 1, true) then
		return w
	end
	local o, i, n = {}, 1, #w
	while i <= n do
		local c = w:sub(i, i)
		if c == "'" then -- single quotes: literal, keep verbatim (incl. any \<nl>)
			local e = w:find("'", i + 1, true) or n
			o[#o + 1] = w:sub(i, e)
			i = e + 1
		elseif c == "$" and w:sub(i + 1, i + 1) == "(" and w:sub(i + 2, i + 2) ~= "(" then
			-- a $(…) body is its own program: the inner parse handles its continuations
			-- (a quoted heredoc in it keeps a literal \<newline>)
			local ok, e = pcall(scan_cmdsub, w, i + 2)
			if ok and e then
				o[#o + 1] = w:sub(i, e - 1)
				i = e
			else
				o[#o + 1] = c
				i = i + 1
			end
		elseif c == "\\" then
			if w:sub(i + 1, i + 1) == "\n" then
				i = i + 2 -- continuation: drop both
			else
				o[#o + 1] = w:sub(i, i + 1)
				i = i + 2
			end -- escaped char: keep the pair
		else
			o[#o + 1] = c
			i = i + 1
		end
	end
	return table.concat(o)
end

local function parse_word(w)
	local src = w -- as written (`declare -f` prints words so)
	w = strip_contin(w)
	local parts = {}
	local function add(p)
		parts[#parts + 1] = p
	end
	local i = 1
	while i <= #w do
		local c = w:sub(i, i)
		if c == "'" then -- single quotes: literal, no expansion
			local e = w:find("'", i + 1, true) or #w + 1
			parts[#parts + 1] = { lit = w:sub(i + 1, e - 1), q = true }
			i = e + 1
		elseif c == '"' then -- double quotes: expand inside; skip $(..)/$((..))/${..}/`..`
			local j = i + 1 -- so their inner " isn't the close
			while j <= #w and w:sub(j, j) ~= '"' do
				local d = w:sub(j, j)
				if d == "\\" then
					j = j + 2
				elseif d == "$" and w:sub(j + 1, j + 2) == "((" then
					local _, nj = grab_dparen(w, j + 3)
					j = nj
				elseif d == "$" and w:sub(j + 1, j + 1) == "(" then
					-- the $(…) body has its OWN quoting (`"$(echo ")")"`): use the quote/case-
					-- aware scanner; an unterminated body falls back to plain paren counting
					local ok, nj = pcall(scan_cmdsub, w, j + 2)
					if ok and nj then
						j = nj
					else
						j = j + 2
						local dep = 1
						while j <= #w and dep > 0 do
							local cc = w:sub(j, j)
							if cc == "(" then
								dep = dep + 1
							elseif cc == ")" then
								dep = dep - 1
							end
							j = j + 1
						end
					end
				elseif d == "$" and w:sub(j + 1, j + 1) == "{" then -- ${...}: inner \ ' " and {} nesting
					j = scan_braces(w, j + 1, true)
				elseif d == "`" then
					j = j + 1
					while j <= #w and w:sub(j, j) ~= "`" do
						if w:sub(j, j) == "\\" then
							j = j + 2
						else
							j = j + 1
						end
					end
					j = j + 1
				else
					j = j + 1
				end
			end
			local before = #parts
			parse_dquote(w:sub(i + 1, j - 1), add)
			if #parts == before then
				parts[#parts + 1] = { lit = "", q = true }
			end -- empty "" is still a field
			i = j + 1
		elseif c == "$" then
			i = parse_dollar(w, i, add, false)
		elseif c == "`" then -- `cmd` command substitution
			local j, buf = i + 1, {}
			while j <= #w and w:sub(j, j) ~= "`" do
				if w:sub(j, j) == "\\" and w:sub(j + 1, j + 1) == "\n" then
					j = j + 2 -- (backquotes drop a \<newline> too, even inside its '…' — POSIX)
				elseif w:sub(j, j) == "\\" and w:sub(j + 1, j + 1):match("[`$\\]") then
					buf[#buf + 1] = w:sub(j + 1, j + 1)
					j = j + 2
				else
					buf[#buf + 1] = w:sub(j, j)
					j = j + 1
				end
			end
			parts[#parts + 1] = { cmdsub = table.concat(buf), q = false, backtick = true, aenv = ALIAS_ENV }
			i = j + 1
		elseif (c == "<" or c == ">") and w:sub(i + 1, i + 1) == "(" then
			-- <(cmd) / >(cmd) process substitution: capture the inner command — its body has
			-- its own quoting/case syntax, so use the $(…) scanner (plain counting if unclosed)
			local j
			local ok, nj = pcall(scan_cmdsub, w, i + 2)
			if ok and nj then
				j = nj - 1 -- index of the closing `)`
			else
				local d
				j, d = i + 2, 1
				while j <= #w and d > 0 do
					local cc = w:sub(j, j)
					if cc == "(" then
						d = d + 1
					elseif cc == ")" then
						d = d - 1
						if d == 0 then
							break
						end
					end
					j = j + 1
				end
			end
			parts[#parts + 1] = { procsub = w:sub(i + 2, j - 1), dir = c, q = false }
			i = j + 1
		elseif c == "\\" then -- backslash escape: literal next char (newline = continuation)
			local nx = w:sub(i + 1, i + 1)
			if nx == "\n" then -- line continuation: drop
			elseif nx == "" then -- a backslash ending the input is itself literal (bash: `a\`)
				parts[#parts + 1] = { lit = "\\", q = true }
			else
				parts[#parts + 1] = { lit = nx, q = true }
			end
			i = i + 2
		else
			local s, e = w:find("^[^$'\"`\\<>]+", i)
			if not s then
				parts[#parts + 1] = { lit = w:sub(i, i), q = false }
				i = i + 1
			else
				parts[#parts + 1] = { lit = w:sub(s, e), q = false }
				i = e + 1
			end
		end
	end
	return { k = "word", parts = parts, src = src }
end
M.parse_word = parse_word
M.scan_cmdsub = scan_cmdsub
M.scan_braces = scan_braces
M.grab_dparen = grab_dparen

-- Memoize the runtime-facing parsers. The interpreter re-parses the SAME arith
-- expressions and words on every loop iteration — $(( … )), array subscripts,
-- ${x:-word}, ${x#pat}, redirect targets — via P.arith / P.parse_word. Both are
-- pure functions of their source string (the returned AST is used read-only by
-- the evaluator/expander), so cache them. Measured: an assoc-array/arith loop was
-- ~5x slower than bash because it re-lexed the subscript + arith text every pass.
-- Bounded so a script with unboundedly many distinct expressions can't leak.
local MEMO_CAP = 8192
do
	local acache, an = {}, 0
	local aimpl = arith
	arith = function(src, nodefer)
		if type(src) == "string" then
			local key = (nodefer == "expanded" and "\3" or nodefer == "strict" and "\2" or nodefer == "let" and "\4" or nodefer and "\1" or "\0") .. src
			local hit = acache[key]
			if hit ~= nil then
				return hit
			end
			local ast = aimpl(src, nodefer)
			if an >= MEMO_CAP then
				acache = {}
				an = 0
			end
			acache[key] = ast
			an = an + 1
			return ast
		end
		return aimpl(src, nodefer)
	end
	M.arith = arith

	local wcache, wn = {}, 0
	local wimpl = parse_word
	parse_word = function(src)
		-- (a $(…)/`…` part records the static alias state it was parsed under: memoize only
		-- where that can't differ — no alias state, or no substitution in the word)
		if type(src) == "string" and not COMSUB_PREX and not POSIX_DQ
			and (ALIAS_ENV == nil or not src:find("[$`]")) then
			local hit = wcache[src]
			if hit ~= nil then
				return hit
			end
			local w = wimpl(src)
			local p1 = #w.parts == 1 and w.parts[1]
			if p1 and p1.lit and not p1.q and not p1.lit:find("[\\$`'\"~*?%[+@!%z]") then
				w.plain = true -- (one unquoted literal: nothing to expand, split or glob)
			end
			if wn >= MEMO_CAP then
				wcache = {}
				wn = 0
			end
			wcache[src] = w
			wn = wn + 1
			return w
		end
		return wimpl(src)
	end
	M.parse_word = parse_word
end

-- Parse a heredoc body as double-quote content: $… expands, but quotes are
-- literal (a heredoc doesn't treat ' or " specially). Used when the delimiter
-- was unquoted; a quoted delimiter means no expansion (raw body).
-- `is_body` true for a real heredoc body (where " is an ordinary char, so `\"`
-- stays literal); false/omitted for a double-quoted-context reuse (a quoted
-- ${x-default} word), where `\"` escapes to " like inside "…".
function M.parse_heredoc(body, is_body, aenv, prompt)
	local parts = {}
	local saved, sprex = ALIAS_ENV, COMSUB_PREX
	ALIAS_ENV = aenv -- its $(…) parts carry the heredoc line's static alias state
	COMSUB_PREX = false
	local ok, err = pcall(parse_dquote, body, function(p)
		parts[#parts + 1] = p
	end, is_body, prompt)
	ALIAS_ENV, COMSUB_PREX = saved, sprex
	if not ok then
		error(err, 0)
	end
	return { k = "word", parts = parts }
end

-- The default/alternate word of a ${x-word} / ${x:-word} / … that sits INSIDE DOUBLE
-- QUOTES follows double-quoted rules: single quotes are literal, a backslash is kept
-- except before $ ` " \ (and \} -> a literal }, \<newline> is a line continuation), and
-- a syntactic inner " is dropped (`"${x:-"a b"}"` -> `a b`). Shared by the interpreter's
-- pexp default expansion and the compiled tier so both render such a default identically.
function M.parse_default_quoted(txt, heredoc)
	local out, k, m = {}, 1, #txt
	while k <= m do
		local ch = txt:sub(k, k)
		if ch == "\\" then
			local nx2 = txt:sub(k + 1, k + 1)
			if nx2 == "\n" then
				k = k + 2 -- backslash-newline: line continuation (removed)
			elseif nx2 == "}" then
				out[#out + 1] = "}"
				k = k + 2 -- \} in a ${…} word is a literal }
			else
				out[#out + 1] = txt:sub(k, k + 1)
				k = k + 2
			end
		elseif ch == '"' then
			k = k + 1 -- drop the syntactic inner quote
		elseif ch == "$" and (txt:sub(k + 1, k + 1) == "(" or txt:sub(k + 1, k + 1) == "{") then
			-- a nested $(…)/$((…))/${…} keeps its OWN quoting (`${u:-$(echo "p)q")}`): copy it
			-- verbatim rather than dropping the quotes inside it
			local ok, nj
			if txt:sub(k + 1, k + 1) == "(" then
				ok, nj = pcall(scan_cmdsub, txt, k + 2)
			else
				ok, nj = pcall(scan_braces, txt, k + 1)
			end
			if ok and nj and nj > k then
				out[#out + 1] = txt:sub(k, nj - 1)
				k = nj
			else
				out[#out + 1] = ch
				k = k + 1
			end
		elseif ch == "`" then
			local e = k + 1
			while e <= m and txt:sub(e, e) ~= "`" do
				e = e + (txt:sub(e, e) == "\\" and 2 or 1)
			end
			out[#out + 1] = txt:sub(k, e)
			k = e + 1
		else
			out[#out + 1] = ch
			k = k + 1
		end
	end
	local saved = DQ_ANSI
	DQ_ANSI = not heredoc
	local ok, r = pcall(M.parse_heredoc, table.concat(out))
	DQ_ANSI = saved
	if not ok then
		error(r, 0)
	end
	return r
end

-- Parse a [[ … ]] token list into a boolean-expression AST:
--   {kind="and"/"or", l, r} | {kind="not", e} | {kind="str", word}
--   {kind="unary", op, word} | {kind="binary", op, l, r, rq}
-- `rq` marks the RHS of ==/!= as fully-quoted (literal, not a glob).
local function parse_dbracket(toks, quoted)
	local pos, serr = 1, false
	local function peek()
		return toks[pos]
	end
	-- `<` `>` `&&` `||` can't stand where an operand is expected (`[[ -f < ]]` is a
	-- parse error). Note `=`/`==`/`!=`/`=~` ARE accepted there as literal strings.
	local function is_op(tok)
		return tok == "<" or tok == ">" or tok == "&&" or tok == "||"
	end
	local parse_or
	local function primary()
		local t = peek()
		if t == nil then
			serr = true
			return { kind = "str", word = parse_word("") }
		end -- expected an operand
		if t == "&&" or t == "||" then
			serr = true
			pos = pos + 1
			return { kind = "str", word = parse_word("") }
		end -- operator with no left operand
		if t == ")" then
			serr = true
			pos = pos + 1
			return { kind = "str", word = parse_word("") }
		end -- unmatched `)` (a matched one is consumed after `(`)
		if t == "!" then
			pos = pos + 1
			return { kind = "not", e = primary() }
		end
		if t == "(" then
			pos = pos + 1
			local e = parse_or()
			if peek() == ")" then
				pos = pos + 1
			else
				serr = true
			end
			e.paren = (e.paren or 0) + 1 -- (for `declare -f`, which prints the grouping)
			return e
		end
		if t and t:match("^%-[a-zA-Z]$") then -- unary file/string test
			if toks[pos + 1] == nil or is_op(toks[pos + 1]) then
				serr = true
			end -- needs a (non-operator) operand
			pos = pos + 2
			return { kind = "unary", op = t, word = parse_word(toks[pos - 1] or "") }
		end
		pos = pos + 1 -- consume lhs
		local op = peek()
		if
			op == "=="
			or op == "!="
			or op == "=~"
			or op == "="
			or op == "<"
			or op == ">"
			or (op and op:match("^%-[a-z][a-z]$"))
		then
			if toks[pos + 1] == nil then
				serr = true
			end -- a binary op needs a rhs
			pos = pos + 1
			local r = toks[pos]
			pos = pos + 1
			return { kind = "binary", op = op, l = parse_word(t), r = parse_word(r or ""), rq = quoted[pos - 1] }
		end
		return { kind = "str", word = parse_word(t or "") }
	end
	local function parse_and()
		local l = primary()
		while peek() == "&&" do
			pos = pos + 1
			l = { kind = "and", l = l, r = primary() }
		end
		return l
	end
	parse_or = function()
		local l = parse_and()
		while peek() == "||" do
			pos = pos + 1
			l = { kind = "or", l = l, r = parse_and() }
		end
		return l
	end
	local ast = parse_or()
	-- empty `[[ ]]`, a dangling/extra operand, or a leftover token is a syntax error
	if serr or #toks == 0 or pos <= #toks then
		return { kind = "syntaxerr" }
	end
	return ast
end
M.parse_dbracket = parse_dbracket

-- ---- brace expansion ({a,b,c}, {m..n}, {m..n..step}, {a..z}) ----
-- Textual, before any other expansion; applies to command words and for-in
-- lists (NOT assignment RHS). Quoted regions are skipped.
--
-- Anti-"billion laughs": a word is parsed ONCE into factors (literal chunks and
-- brace groups); ranges stay symbolic (a,b,step), never materialized. Combinations
-- are produced by an odometer that STREAMS each result to a callback — so a huge
-- expansion never builds a giant intermediate. Consumers decide the policy:
-- for-in streams lazily (unbounded — `for i in {1..1e9}` runs in O(1) memory,
-- better than bash which OOMs); argv materialization caps at BRACE_CAP (an argv
-- can't be infinite). Nothing is a fatal error and nothing is silently dropped
-- to literal — the expansion always happens, just lazily when it's large.
local BRACE_CAP = 100000

-- Skip a quoted string or a backslash escape at `i` in `s` (brace syntax is inert inside
-- them: `{abc\,def}`, `{x,\{a}`, `{"a,b",c}`); returns the index after it, or nil.
local function brace_skip_quoted(s, i)
	local c = s:sub(i, i)
	if c == "\\" then
		return i + 2
	elseif c == "'" or c == '"' or c == "`" then
		local j = i + 1
		while j <= #s and s:sub(j, j) ~= c do
			j = j + ((c ~= "'" and s:sub(j, j) == "\\") and 2 or 1)
		end
		return j + 1
	end
	return nil
end
local function split_top_comma(inner)
	local parts, depth, start = {}, 0, 1
	local i = 1
	while i <= #inner do
		local c = inner:sub(i, i)
		local skip = brace_skip_quoted(inner, i)
		if skip then
			i = skip
		else
			if c == "{" then
				depth = depth + 1
			elseif c == "}" then
				depth = depth - 1
			elseif c == "," and depth == 0 then
				parts[#parts + 1] = inner:sub(start, i - 1)
				start = i + 1
			end
			i = i + 1
		end
	end
	parts[#parts + 1] = inner:sub(start)
	return parts
end
-- A character from a {x..y} range, as word TEXT (the expansion is re-parsed as a word):
-- shell-special characters must stay literal (`{Z..a}` yields ` literally), and a `\`
-- comes out as an empty argument (bash's quote removal of the lone backslash).
local function brace_char(v)
	local ch = string.char(v)
	if ch == "\\" then
		return "''"
	end
	if ch:match("[`'\"$;&|<>() \t]") then
		return "\\" .. ch
	end
	return ch
end

-- classify the inside of a {…}: a numeric/char range (symbolic) or a comma list
-- (raw alternatives, possibly themselves containing braces), or nil (not a brace).
-- bash zero-pads a numeric range to the widest endpoint iff either endpoint has
-- a leading zero (e.g. {01..3} -> 01 02 03, {01..003} -> 001 002 003).
local function num_pad_width(a, b)
	if a:match("^%-?0%d") or b:match("^%-?0%d") then
		return math.max(#(a:gsub("^%-", "")), #(b:gsub("^%-", "")))
	end
	return nil
end
-- a range endpoint: a Lua number when exact, else int64 (`{9223372036854775805..…}`)
local function range_num(d)
	if #d:gsub("^-", ""):gsub("^0+", "") <= 15 then
		return tonumber(d)
	end
	local f = loadstring("return " .. d .. "LL")
	return f and f() or tonumber(d)
end
local function classify_brace(inner)
	local a2, b2, s2 = inner:match("^(-?%d+)%.%.(-?%d+)%.%.(-?%d+)$")
	if a2 then
		return {
			range = {
				a = range_num(a2),
				b = range_num(b2),
				step = math.max(1, math.abs(tonumber(s2))),
				char = false,
				width = num_pad_width(a2, b2),
			},
		}
	end
	local a, b = inner:match("^(-?%d+)%.%.(-?%d+)$")
	if a then
		return { range = { a = range_num(a), b = range_num(b), step = 1, char = false, width = num_pad_width(a, b) } }
	end
	local ca3, cb3, cs3 = inner:match("^(%a)%.%.(%a)%.%.(-?%d+)$")
	if ca3 then
		return { range = { a = ca3:byte(), b = cb3:byte(), step = math.max(1, math.abs(tonumber(cs3))), char = true } }
	end
	local ca, cb = inner:match("^(%a)%.%.(%a)$")
	if ca then
		return { range = { a = ca:byte(), b = cb:byte(), step = 1, char = true } }
	end
	local parts = split_top_comma(inner)
	if #parts > 1 then
		return { list = parts }
	end
	return nil
end
-- Parse a raw word into factors, or nil if it has no expandable brace.
local function brace_factors(s)
	if not s:find("{", 1, true) or not s:gsub("%${", ""):find("{", 1, true) then
		return nil -- (the common word: no brace at all, or only ${…} ones)
	end
	local factors, litbuf, any = {}, {}, false
	local function flush()
		if #litbuf > 0 then
			factors[#factors + 1] = { lit = table.concat(litbuf) }
			litbuf = {}
		end
	end
	local i = 1
	while i <= #s do
		local c = s:sub(i, i)
		if c == "\\" then -- a backslash escapes the next char, so `\{` isn't a brace open
			litbuf[#litbuf + 1] = c
			if i + 1 <= #s then
				litbuf[#litbuf + 1] = s:sub(i + 1, i + 1)
			end
			i = i + 2
		elseif c == "'" or c == '"' then
			litbuf[#litbuf + 1] = c
			i = i + 1
			while i <= #s and s:sub(i, i) ~= c do
				litbuf[#litbuf + 1] = s:sub(i, i)
				i = i + 1
			end
			if i <= #s then
				litbuf[#litbuf + 1] = c
				i = i + 1
			end
		elseif c == "`" then -- a `…` command substitution is copied whole (its braces are its own)
			local j = i + 1
			while j <= #s and s:sub(j, j) ~= "`" do
				j = j + (s:sub(j, j) == "\\" and 2 or 1)
			end
			litbuf[#litbuf + 1] = s:sub(i, j)
			i = j + 1
		elseif c == "$" and s:sub(i + 1, i + 1) == "{" then
			-- ${…} is a parameter expansion, NOT brace expansion — copy it verbatim.
			local e = s:find("}", i + 2, true) or #s
			litbuf[#litbuf + 1] = s:sub(i, e)
			i = e + 1
		elseif c == "$" and s:sub(i + 1, i + 1) == "(" then
			-- $(…) / $((…)): copy verbatim (balancing parens).
			local d, j = 0, i + 1
			while j <= #s do
				local cc = s:sub(j, j)
				if cc == "(" then
					d = d + 1
				elseif cc == ")" then
					d = d - 1
					if d == 0 then
						break
					end
				end
				j = j + 1
			end
			litbuf[#litbuf + 1] = s:sub(i, j)
			i = j + 1
		elseif c == "{" then
			local d, j = 1, i + 1
			while j <= #s and d > 0 do
				local cc = s:sub(j, j)
				local skip = brace_skip_quoted(s, j)
				if skip then
					j = skip
				else
					if cc == "{" then
						d = d + 1
					elseif cc == "}" then
						d = d - 1
					end
					if d == 0 then
						break
					end
					j = j + 1
				end
			end
			if d == 0 then
				local f = classify_brace(s:sub(i + 1, j - 1))
				if f then
					flush()
					factors[#factors + 1] = f
					any = true
					i = j + 1
				else
					-- not an expansion itself: its `{` is literal, but braces INSIDE it still
					-- expand (`a-{b{d,e}}-c` -> a-{bd}-c a-{be}-c); its `}` is met as a plain char
					litbuf[#litbuf + 1] = "{"
					i = i + 1
				end
			else
				litbuf[#litbuf + 1] = c
				i = i + 1
			end
		else
			litbuf[#litbuf + 1] = c
			i = i + 1
		end
	end
	flush()
	return any and factors or nil
end
M.brace_factors = brace_factors

local brace_stream -- forward (mutually recursive with itself over nested alts)
local function range_count(r)
	if type(r.a) == "cdata" or type(r.b) == "cdata" then
		local d = r.b > r.a and r.b - r.a or r.a - r.b
		return tonumber(d / r.step) + 1
	end
	return math.floor(math.abs(r.b - r.a) / r.step) + 1
end
local function pad_num(v, w) -- zero-pad |v| to width w digits, keeping the sign
	if type(v) == "cdata" then
		return (tostring(v):gsub("LL$", ""))
	end
	local d = tostring(math.abs(v))
	if #d < w then
		d = string.rep("0", w - #d) .. d
	end
	return (v < 0 and "-" or "") .. d
end
-- Stream every expansion of `factors` to emit(str); ranges iterate symbolically
-- (never materialized). If emit returns true the stream STOPS — this is how a
-- consumer bounds a pathological expansion after N results without iterating the
-- rest (so a {1..1e9} range costs O(N), not O(1e9)).
local function stream_factors(factors, emit)
	local stopped = false
	local function go(idx, acc)
		if stopped then
			return
		end
		if idx > #factors then
			if emit(acc) then
				stopped = true
			end
			return
		end
		local f = factors[idx]
		if f.lit then
			go(idx + 1, acc .. f.lit)
		elseif f.range then
			local r = f.range
			for k = 0, range_count(r) - 1 do
				local v = (r.a <= r.b) and (r.a + k * r.step) or (r.a - k * r.step)
				go(idx + 1, acc .. (r.char and brace_char(v) or (r.width and pad_num(v, r.width)
					or (type(v) == "number" and tostring(v) or (tostring(v):gsub("LL$", ""))))))
				if stopped then
					return
				end
			end
		else -- list: each alt may itself contain braces -> stream recursively
			for _, alt in ipairs(f.list) do
				brace_stream(alt, function(x)
					go(idx + 1, acc .. x)
					return stopped
				end)
				if stopped then
					return
				end
			end
		end
	end
	go(1, "")
end
brace_stream = function(s, emit)
	local f = brace_factors(s)
	if not f then
		emit(s)
	else
		stream_factors(f, emit)
	end
end
M.brace_stream = brace_stream
M.stream_factors = stream_factors

-- Cheap count of a factor list's total expansions, capped (returns >BRACE_CAP as
-- soon as it's known to exceed, without building anything).
local function count_str(s)
	local f = brace_factors(s)
	if not f then
		return 1
	end
	local total = 1
	for _, fac in ipairs(f) do
		local c
		if fac.lit then
			c = 1
		elseif fac.range then
			c = range_count(fac.range)
		else
			c = 0
			for _, alt in ipairs(fac.list) do
				c = c + count_str(alt)
				if c > BRACE_CAP then
					break
				end
			end
		end
		total = total * c
		if total > BRACE_CAP then
			return total
		end
	end
	return total
end
M.brace_count = count_str
M.BRACE_CAP = BRACE_CAP

-- Append a raw word to a word-list, brace-expanding it. Streams combinations
-- (ranges symbolic) and STOPS after BRACE_CAP words — so a pathological
-- expansion costs O(cap), never blows up, and is neither a fatal error nor
-- silently dropped to literal: it expands, just bounded.
-- Declaration builtins: `NAME=(...)` in their argument position is an array
-- literal (like a prefix assignment), not a scalar word + subshell.
local DECL_BUILTINS = { declare = 1, typeset = 1, ["local"] = 1, readonly = 1, export = 1 }
-- compound commands, and the words that may directly follow one (see parse_pipeline)
local COMPOUND_T = {
	group = 1, subshell = 1, ["if"] = 1, whilec = 1, forin = 1, forc = 1, select = 1,
	case = 1, arithcmd = 1, dbracket = 1, funcdef = 1,
}
local AFTER_COMPOUND = {
	["}"] = 1, ["then"] = 1, ["else"] = 1, ["elif"] = 1, ["fi"] = 1, ["do"] = 1, ["done"] = 1,
	["esac"] = 1, [";;"] = 1,
}

local INTWORD = {} -- (integer -> its literal word: ranges repeat, and allocation dominates)
local function add_word(words, w)
	local factors = brace_factors(w)
	if not factors then
		words[#words + 1] = parse_word(w)
		return
	end
	local r = #factors == 1 and factors[1].range
	if r and not r.char and not r.width and type(r.a) == "number" and type(r.b) == "number"
		and math.abs(r.a) < 1e14 and math.abs(r.b) < 1e14 then
		-- a lone numeric range ({0..N}, {9..1..2}): its words straight from the loop
		local cnt = math.min(range_count(r), BRACE_CAP)
		local step = r.a <= r.b and r.step or -r.step
		local v = r.a
		local nw = #words
		for k = 1, cnt do
			local wd = INTWORD[v] -- (words are shared read-only, like the parse_word memo's)
			if not wd then
				wd = { k = "word", parts = { { lit = tostring(v), q = false } }, src = false, plain = true, fresh = true }
				if v > -1e6 and v < 1e6 then
					INTWORD[v] = wd
				end
			end
			if k == 1 then -- (the first carries the source text: `declare -f` shows `{0..N}`)
				wd = { k = "word", parts = wd.parts, src = w, plain = true, fresh = true }
			end
			nw = nw + 1
			words[nw] = wd
			v = v + step
		end
		return
	end
	local n = 0
	stream_factors(factors, function(x)
		-- (the source text belongs to the unexpanded word: the first expansion carries it,
		-- the rest print nothing — `declare -f` shows `{a,b}` as written. A COPY: parsed
		-- words are memoized and shared.)
		if x ~= "" and not x:find("[^%w_%-%.,/+:=@%%]") then -- plain text: the literal word as is
			words[#words + 1] = { k = "word", parts = { { lit = x, q = false } }, src = n == 0 and w or false }
		else
			local pw = parse_word(x)
			words[#words + 1] = { k = pw.k, parts = pw.parts, src = n == 0 and w or false }
		end
		n = n + 1
		return n >= BRACE_CAP -- true -> stop the stream
	end)
end

-- strip surrounding quotes from a raw shell word (subset: whole-word "…" or '…')
local function unquote(w)
	if #w >= 2 and ((w:sub(1, 1) == '"' and w:sub(-1) == '"') or (w:sub(1, 1) == "'" and w:sub(-1) == "'")) then
		return w:sub(2, -2)
	end
	return w
end

-- Remove ALL quoting from a word (every ' " and \ segment), concatenating the
-- literal content — bash's quote removal for a heredoc delimiter, so `'EOF'"2"`
-- and `E\OF` collapse to EOF2 / EOF.
local function dequote_word(w)
	local out, i, len = {}, 1, #w
	while i <= len do
		local c = w:sub(i, i)
		if c == "\\" then
			out[#out + 1] = w:sub(i + 1, i + 1)
			i = i + 2
		elseif c == "'" then
			i = i + 1
			while i <= len and w:sub(i, i) ~= "'" do
				out[#out + 1] = w:sub(i, i)
				i = i + 1
			end
			i = i + 1
		elseif c == '"' then
			i = i + 1
			while i <= len and w:sub(i, i) ~= '"' do
				if w:sub(i, i) == "\\" then
					out[#out + 1] = w:sub(i + 1, i + 1)
					i = i + 2
				else
					out[#out + 1] = w:sub(i, i)
					i = i + 1
				end
			end
			i = i + 1
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	return table.concat(out)
end

-- a space or tab (a plain compare: string patterns keep the tokenizer out of the JIT)
local function is_blank(ch)
	return ch == " " or ch == "\t"
end
-- the characters a word scan must look at (anything else just continues the word)
local WORD_SPECIAL = "[\\()\"'$<>|&`; \t\n?*+@!]"
local function make_parser(src, sh, aenv, noalias, posix, line0, lineabs)
	local i, n, line = 1, #src, lineabs or 1
	local firstline = lineabs or 1 -- (the text's first line: an EOF error counts from it)
	local orig_src = src -- (alias expansion splices into src; an error echoes the line as written)
	if line0 then -- a $(…) body numbers from its command's line; leading newlines don't count
		line = line0 - #(src:match("^[ \t\n]*"):gsub("[^\n]", ""))
	end
	local loopId = 0
	local heredocs_pending = {} -- heredoc redirs awaiting their body (filled at line end)
	local warns = {} -- parse-time warnings, run as `warn` statements ahead of their line
	-- Alias expansion, done here in the PARSER as a deterministic function of the
	-- source text (recognizing `shopt -s/-u expand_aliases`, `alias`, `unalias` as
	-- they are parsed), so the interpreter and the behind-the-scenes compiler both
	-- consume the identical expanded tree — an alias is a "baby source": its value
	-- is spliced into the token stream and re-tokenized IN CONTEXT, so a `{`/`(`
	-- pairs with a later `}`/`)`, `|` forms a real pipeline, and a trailing blank
	-- makes the following word alias-eligible too.
	local alias_on = false -- shopt expand_aliases state (from source)
	local posix_on = posix or false -- set -o posix state (from source; sh.opt_posix when interpreting)
	local extglob_on = false -- shopt extglob state (from source; the live sh.shopt when interpreting)
	local aliases = {} -- name -> value (from parsed `alias` commands)
	if aenv then -- a nested body ($(…)) starts from its enclosing line's static state
		alias_on = true
		for k, v in pairs(aenv.tab) do
			aliases[k] = v
		end
	end
	-- bash parses a whole line before running any of it, so an alias/unalias/shopt on a
	-- line takes effect from the NEXT line: queue them, apply at the next line's start.
	local alias_pending = {}
	local alias_seen -- names being expanded now (recursion guard)
	local alias_next = false -- next word is eligible (prev value ended blank)
	local alias_tail = nil -- byte position just past the current expansion
	-- The static (fully-literal, unquoted) text of a word, or nil if any part is an
	-- expansion/quoted-out — used to read alias/shopt/unalias operands from source.
	local function static_word(w)
		if not w or not w.parts then
			return nil
		end
		local out = {}
		for _, p in ipairs(w.parts) do
			if p.lit == nil then
				return nil
			end
			out[#out + 1] = p.lit
		end
		return table.concat(out)
	end
	-- The active alias table + on-flag. When interpreting, `sh` carries the LIVE
	-- runtime state (the lazy interp defines aliases by executing `alias`/`shopt`
	-- before parsing later commands, and eval/source/$() feed their text through
	-- the same sh-aware parse), so those are authoritative and cross parse
	-- boundaries. With no `sh` (the state-less background compile) the parser tracks
	-- the same state from source deterministically, so the static common case
	-- compiles to the identical tree.
	local function alias_state()
		if noalias then
			return false
		end
		if sh then
			return sh.shopt and sh.shopt.expand_aliases, sh.aliases
		end
		return alias_on, aliases
	end
	-- Record alias-affecting builtins as they are parsed so later words expand
	-- (source-tracking; only needed for the sh-less compile path).
	local function apply_alias_state(node)
		local w1 = node.words[1].parts
		local cmd = (#w1 == 1 and not w1[1].q and w1[1].lit) or nil
		if cmd == "shopt" then
			local set = nil
			for k = 2, #node.words do
				local a = static_word(node.words[k])
				if a == "-s" then
					set = true
				elseif a == "-u" then
					set = false
				elseif a == "-q" or a == "-p" or a == "-o" then -- flags, ignore
				elseif a == "expand_aliases" and set ~= nil then
					alias_on = set
				elseif a == "extglob" and set ~= nil then
					extglob_on = set
				end
			end
		elseif cmd == "alias" then
			for k = 2, #node.words do
				local w = node.words[k]
				-- name=value: the `=` is in the first literal part; the value is the rest
				-- of that part plus every following literal part (already quote-stripped).
				local first = w.parts[1]
				if first and first.lit and not first.lit:match("^%-") then
					local eq = first.lit:find("=", 1, true)
					if eq then
						local name = first.lit:sub(1, eq - 1)
						local rest, ok = { first.lit:sub(eq + 1) }, true
						for p = 2, #w.parts do
							if w.parts[p].lit == nil then
								ok = false
								break
							end
							rest[#rest + 1] = w.parts[p].lit
						end
						-- (legal_alias_name: no shellbreak/quote/`$`/`/` char — b_alias.lua)
						if ok and name ~= "" and not name:find("[ \t\n()<>;&|'\"`\\$/]") then
							aliases[name] = table.concat(rest)
						end
					end
				end
			end
		elseif cmd == "unalias" then
			for k = 2, #node.words do
				local a = static_word(node.words[k])
				if a == "-a" then
					aliases = {}
				elseif a and not a:match("^%-") then
					aliases[a] = nil
				end
			end
		elseif cmd == "set" then -- `set -o posix` / `set +o posix` (posix-mode $(…) parsing)
			for k = 2, #node.words - 1 do
				local a, b = static_word(node.words[k]), static_word(node.words[k + 1])
				if (a == "-o" or a == "+o") and b == "posix" then
					posix_on = a == "-o"
					alias_on = posix_on -- (posix_initialize: on sets expand_aliases, off resets it)
				end
			end
		end
	end
	local function record_alias_state(node)
		if sh then
			return
		end
		if not (node and node.t == "simple" and node.words and node.words[1]) then
			return
		end
		alias_pending[#alias_pending + 1] = node
	end
	-- Line boundary (sh-less): apply the previous line's alias changes, then publish the
	-- static state for this line's $(…) parts.
	local function alias_line_start()
		if sh then
			ALIAS_ENV = nil
			-- posix mode (live sh): a $(…) is parsed as it is read, expanding aliases in it
			local on, tab = alias_state()
			COMSUB_PREX = noalias or (sh.opt_posix and on and tab ~= nil and next(tab) ~= nil) or false
			POSIX_DQ = sh.opt_posix or false
			return
		end
		if #alias_pending > 0 then
			for _, node in ipairs(alias_pending) do
				apply_alias_state(node)
			end
			alias_pending = {}
		end
		if alias_on then
			local tab = {}
			for k, v in pairs(aliases) do
				tab[k] = v
			end
			ALIAS_ENV = { tab = tab }
		else
			ALIAS_ENV = nil
		end
		COMSUB_PREX = noalias or (posix_on and alias_on and next(aliases) ~= nil) or false
		POSIX_DQ = posix_on
	end
	-- Try to expand an alias at the current position. `cmdpos` = command position
	-- (always eligible); otherwise eligible only via trailing-blank chaining, and
	-- only once the parser has consumed past the value that set the flag.
	local function try_alias(cmdpos)
		local on, tab = alias_state()
		if not on then
			return
		end
		if not cmdpos then
			if not (alias_next and alias_tail and i >= alias_tail) then
				return
			end
			-- Now past the previous value: this is a fresh input word, so the guard
			-- resets (bash only blocks an alias WITHIN its own value's expansion, not a
			-- separate later occurrence — `echo-x echo-x` expands both). The word's own
			-- value recursion below still accumulates into the fresh guard.
			alias_seen = {}
		end
		-- a `\<newline>` continuation (plus blanks) before the word is just whitespace: skip
		-- it so a trailing-blank alias chain continues onto the next line
		while src:sub(i, i + 1) == "\\\n" do
			i = i + 2
			line = line + 1
			while is_blank(src:sub(i, i)) do
				i = i + 1
			end
		end
		local expanded = false
		while true do
			local rs, re = src:find("^[^ \t\n|&;()<>'\"`\\$]+", i)
			if not rs then
				break
			end
			local nextch = src:sub(re + 1, re + 1)
			if nextch ~= "" and nextch:match("['\"`\\$]") then
				break
			end -- not a pure literal word
			local cand = src:sub(rs, re)
			local val = tab and tab[cand]
			if val == nil or alias_seen[cand] then
				break
			end
			alias_seen[cand] = true
			local L = re - rs + 1
			-- the end of an expansion delimits the token (bash mk_alexpansion adds a space) —
			-- `alias foo='echo 0'; foo>&2` is `echo 0 >&2`, not `echo 0>&2` — except after a
			-- trailing backslash, which quotes the next input char (`alias a='… \'; a|cat`)
			local ins = val
			-- (shell_getc: none after a blank, newline or metachar — `alias s='echo 8 )'`)
			if ins ~= "" and not ins:match("[ \t\n\\|&;()<>]$") then
				-- …and not when the value ends INSIDE an open quote (`alias foo="echo 'Err:"`):
				-- the quoted string continues into the following input
				local q, k = nil, 1
				while k <= #ins do
					local ch = ins:sub(k, k)
					if q == "'" then
						if ch == "'" then q = nil end
					elseif q == '"' then
						if ch == "\\" then k = k + 1 elseif ch == '"' then q = nil end
					elseif ch == "\\" then
						k = k + 1
					elseif ch == "'" or ch == '"' then
						q = ch
					end
					k = k + 1
				end
				if not q then
					ins = ins .. " "
				end
			end
			src = src:sub(1, rs - 1) .. ins .. src:sub(re + 1)
			n = #src
			if alias_tail == nil then
				alias_tail = rs + #ins
			else
				alias_tail = alias_tail + (#ins - L)
			end
			alias_next = val:match("[ \t]$") ~= nil
			expanded = true
			-- recurse: the value's first word (now at i) is itself command-position
		end
		-- A chained (argument-position) word that turned out NOT to be an alias ends
		-- the chain. A command-position miss must NOT clear a chain a prior expansion
		-- set (the command word is re-checked here after being expanded at dispatch).
		if not expanded and not cmdpos then
			alias_next = false
		end
	end
	-- Collect the bodies of any heredocs opened on the just-parsed line. Called
	-- after a simple command AND after a compound command's redirs (group,
	-- subshell, etc.), since `{ ...; } <<EOF` also opens a heredoc.
	local function collect_heredocs()
		if #heredocs_pending == 0 then
			return
		end
		while i <= n and src:sub(i, i) ~= "\n" do
			i = i + 1
		end -- to end of command line
		local rline, nread = line, 0 -- (bash's warning lines: where reading began, + lines read)
		if i <= n then
			i = i + 1
			line = line + 1
		end
		for _, hd in ipairs(heredocs_pending) do
			local blines = {}
			local found = false
			while i <= n do
				local le = src:find("\n", i, true) or (n + 1)
				local lstr = src:sub(i, le - 1)
				if hd.strip then
					lstr = lstr:gsub("^\t+", "")
				end
				i = le + 1
				line = line + 1
				nread = nread + 1
				-- unquoted delimiter: `\<newline>` joins lines before the delimiter check (bash)
				while hd.expand and le <= n and #lstr:match("\\*$") % 2 == 1 do
					le = src:find("\n", i, true) or (n + 1)
					local nxt = src:sub(i, le - 1)
					if hd.strip then
						nxt = nxt:gsub("^\t+", "")
					end
					lstr = lstr:sub(1, -2) .. nxt
					i = le + 1
					line = line + 1
				end
				if lstr == hd.delim then
					found = true
					break
				end
				-- a $(…) body's final `DELIM )` line reached here as `DELIM ` (see scan_cmdsub)
				if le > n and lstr:match("^(.-)[ \t]+$") == hd.delim then
					found = true
					break
				end
				blines[#blines + 1] = lstr
			end
			if not found then
				warns[#warns + 1] = { t = "warn", line = rline + nread,
					msg = ("warning: here-document at line %d delimited by end-of-file (wanted `%s')"):format(rline, hd.delim) }
			end
			hd.body = #blines > 0 and (table.concat(blines, "\n") .. "\n") or ""
			hd.aenv = ALIAS_ENV -- the compiler re-parses an expanding body later (parse_heredoc)
		end
		heredocs_pending = {}
	end
	local function ws() -- skip spaces/tabs (not newlines) — and `\<newline>` continuations,
		-- which bash removes from the input before tokenizing (`a | \<nl>(cat)`)
		while i <= n do
			i = src:find("[^ \t]", i) or (n + 1) -- (a run of blanks at once)
			if i <= n and src:byte(i) == 92 and src:byte(i + 1) == 10 then -- `\<newline>`
				i = i + 2
				line = line + 1
			else
				break
			end
		end
	end
	local parse_redir -- forward (defined in make_parser body)
	-- Redirections trailing a compound command (loop/if/case): `done < f`,
	-- `done <<EOF … EOF`. Collect them and any heredoc bodies they open.
	local function tail_redirs()
		local redirs = {}
		while true do
			ws()
			local r = parse_redir()
			if r then
				redirs[#redirs + 1] = r
			else
				break
			end
		end
		return #redirs > 0 and redirs or nil
	end
	local function skipsep() -- skip separators: whitespace, newlines, ;, comments
		while i <= n do
			local c = src:sub(i, i)
			if c == "\n" then
				-- heredoc bodies opened earlier on this logical line follow this newline,
				-- in the order the `<<` operators appeared — collect them all here.
				if #heredocs_pending > 0 then
					collect_heredocs() -- consumes the newline + bodies
				else
					line = line + 1
					i = i + 1
				end
			elseif c:match("[ \t;]") then
				i = i + 1
			elseif c == "#" then
				while i <= n and src:sub(i, i) ~= "\n" do
					i = i + 1
				end
			else
				break
			end
		end
	end
	-- Like skipsep but STOPS at a statement separator (; & |) instead of eating it,
	-- so the statement loops can tell a *trailing* separator (fine) from one in
	-- command position (a syntax error — see bare_sep_tok).
	local function skipblank()
		while i <= n do
			local c = src:sub(i, i)
			if c == "\n" then
				if #heredocs_pending > 0 then
					collect_heredocs()
				else
					line = line + 1
					i = i + 1
				end
			elseif c == " " or c == "\t" then
				i = i + 1
			elseif c == "#" then
				while i <= n and src:sub(i, i) ~= "\n" do
					i = i + 1
				end
			else
				break
			end
		end
	end
	-- At a command-expected position a control operator means an empty command,
	-- which bash rejects as a syntax error (status 2): a leading/doubled `;`, `;;`,
	-- `&`, `&&`, `||`, `|`, or `|&`. Returns the offending token, or nil.
	local function bare_sep_tok()
		local c2 = src:sub(i, i + 1)
		if c2 == ";;" or c2 == "&&" or c2 == "||" or c2 == "|&" then
			return c2
		end
		local c = src:sub(i, i)
		if c == ";" or c == "&" or c == "|" then
			return c
		end
		return nil
	end
	local parse_stmts
	local cur_stopset -- (see parse_stmts)
	local operand_check -- (see parse_pipeline)
	local cmd_prex -- position whose command-word alias parse_stmts already expanded
	-- bash's posix-mode parse_comsub: read a $( … ) body with the real parser (from i just
	-- past `$(`), so an alias in it expands in context — its value can hold the closing `)`
	-- (or a `case` whose `pat)` must not close). The expanded text lands in src.
	local function prex_comsub()
		local _, term = parse_stmts({ [")"] = true })
		if term ~= ")" then
			error("syntax error: unexpected end of file")
		end
	end
	-- scan_cmdsub's onwarn for a word starting at `start` on line `line0` (built only where a
	-- $( ) needs it: a closure per word would keep the word scan out of the JIT)
	local function hdwarn_for(start, line0)
		return function(rp, dp, d)
			local function at(p)
				return line0 + select(2, src:sub(start, p - 1):gsub("\n", ""))
			end
			warns[#warns + 1] = { t = "warn", line = at(dp),
				msg = ("warning: here-document at line %d delimited by end-of-file (wanted `%s')"):format(at(rp), d) }
		end
	end
	local function word(stop_paren, stop_cmp) -- read one shell word, keeping quotes and $(( )) / ${ } / $( ) balanced
		ws()
		local start, line0, lfix = i, line, 0
		while i <= n do
			-- (a run of ordinary characters is part of the word: jump to the next one that
			-- could matter — one find instead of a per-character pattern test)
			local j = src:find(WORD_SPECIAL, i)
			if not j then
				i = n + 1
				break
			end
			i = j
			local c = src:sub(i, i)
			if c == "\\" then -- backslash escapes the next char (incl. metachars/space)
				if src:sub(i + 1, i + 1) == "\n" then
					line = line + 1
				end -- `\<newline>` line continuation
				i = i + 2
			elseif stop_paren and (c == ")" or c == "(") then
				break
			elseif c == '"' then -- double quotes: honor \" and skip $(..)/$((..))/`..`
				i = i + 1 -- (their inner " are not the close)
				while i <= n and src:sub(i, i) ~= '"' do
					local d = src:sub(i, i)
					if d == "\\" then
						i = i + 2
					elseif d == "$" and src:sub(i + 1, i + 2) == "((" then
						local _, ni = grab_dparen(src, i + 3)
						i = ni
					elseif d == "$" and src:sub(i + 1, i + 1) == "(" then
						if COMSUB_PREX and not noalias then
							i = i + 2
							prex_comsub()
						else
							i = scan_cmdsub(src, i + 2, hdwarn_for(start, line0)) -- case/quote/nesting-aware boundary
						end
					elseif d == "$" and src:sub(i + 1, i + 1) == "{" then
						i = scan_braces(src, i + 1, true) -- ${…}: inner \ ' " and nested {} don't close it
					elseif d == "`" then
						i = i + 1
						while i <= n and src:sub(i, i) ~= "`" do
							if src:sub(i, i) == "\\" then
								i = i + 2
							else
								i = i + 1
							end
						end
						i = i + 1
					else
						i = i + 1
					end
				end
				if i > n then
					error("unexpected EOF while looking for matching `\"'")
				end -- unterminated "
				i = i + 1 -- past closing quote
			elseif c == "'" then -- single quotes: everything literal, no escapes
				i = i + 1
				while i <= n and src:sub(i, i) ~= "'" do
					i = i + 1
				end
				if i > n then
					error("unexpected EOF while looking for matching `''")
				end -- unterminated '
				i = i + 1 -- past closing quote
			elseif c == "$" and src:sub(i + 1, i + 1) == "'" then
				-- $'…' ANSI-C quote: scan to the close honoring \' \\
				i = i + 2
				while i <= n and src:sub(i, i) ~= "'" do
					if src:sub(i, i) == "\\" then
						i = i + 2
					else
						i = i + 1
					end
				end
				if i > n then
					error("unexpected EOF while looking for matching `''")
				end -- unterminated $'
				i = i + 1
			elseif c == "$" and src:sub(i + 1, i + 2) == "((" and dparen_is_arith(src, i + 3) then
				local _, ni = grab_dparen(src, i + 3)
				i = ni
			elseif c == "$" and src:sub(i + 1, i + 1) == "[" then -- $[expr]: keep whole (spaces inside)
				i = i + 2
				local d = 1
				while i <= n and d > 0 do
					local cc = src:sub(i, i)
					if cc == "[" then
						d = d + 1
					elseif cc == "]" then
						d = d - 1
					end
					i = i + 1
				end
			elseif c == "$" and src:sub(i + 1, i + 1) == "(" then
				if COMSUB_PREX and not noalias then
					i = i + 2
					prex_comsub()
				else
					local je, hdp = scan_cmdsub(src, i + 2, hdwarn_for(start, line0)) -- case/quote/nesting-aware boundary (errors if unclosed)
					local cbody = src:sub(i + 2, je - 2)
					-- (not when the static parse could be wrong: aliases in play, extglob
					-- patterns, here-documents)
					if not hdp and not alias_on and src:sub(i + 2, i + 2) ~= "(" and not cbody:find("[@!+*?]%(")
						and not cbody:find("<<", 1, true)
						and not (sh and sh.shopt and sh.shopt.expand_aliases and sh.aliases and next(sh.aliases)) then
						local cerr = comsub_syntax(cbody)
						if cerr then
							error(cerr)
						end
					end
					if hdp then
						-- `$(cat <<EOF)` then the body on the following lines (bash): move those
						-- lines (through each delimiter) inside the $( … ) text
						local nl = src:find("\n", je, true)
						if nl then
							local k = nl + 1
							for _, hd in ipairs(hdp) do
								while k <= n do
									local le = src:find("\n", k, true) or (n + 1)
									local l = src:sub(k, le - 1)
									if hd.strip then
										l = l:gsub("^\t+", "")
									end
									k = le + 1
									if l == hd.delim then
										break
									end
								end
							end
							local body = src:sub(nl + 1, k - 1)
							if body:sub(-1) ~= "\n" then
								body = body .. "\n"
							end
							src = src:sub(1, je - 2) .. "\n" .. body .. src:sub(je - 1, nl) .. src:sub(k)
							n = #src
							je = je + 1 + #body
							lfix = lfix - 1 -- (that inserted newline isn't a source line)
							warns[#warns + 1] = { t = "warn", line = line,
								msg = ("warning: command substitution: %d unterminated here-document"):format(#hdp) }
						end
					end
					i = je
				end
			elseif (c == "<" or c == ">") and src:sub(i + 1, i + 1) == "(" then
				-- <(cmd) / >(cmd) process substitution: part of the word — scanned like $(…)
				-- (its body has its own quoting / case syntax)
				i = scan_cmdsub(src, i + 2)
			elseif (c == "?" or c == "*" or c == "+" or c == "@" or c == "!") and src:sub(i + 1, i + 1) == "(" then
				-- extglob ?(..) *(..) +(..) @(..) !(..): part of the word, not a subshell
				i = i + 2
				local d = 1
				while i <= n and d > 0 do
					local cc = src:sub(i, i)
					if cc == "(" then
						d = d + 1
					elseif cc == ")" then
						d = d - 1
					end
					i = i + 1
				end
			elseif c == "<" or c == ">" or c == "|" or c == "&" then
				break -- metacharacters end a word: redirs (procsub <(/>( handled above), `|`/`&` pipelines/lists & `&&`/`||`/`>&` need no surrounding space
			elseif c == "$" and src:sub(i + 1, i + 1) == "{" then
				i = scan_braces(src, i + 1) -- ${…}: match the close, honoring \ ' " and nesting
			elseif c == "`" then -- `…` command sub: keep it whole (spaces inside included)
				i = i + 1
				while i <= n and src:sub(i, i) ~= "`" do
					if src:sub(i, i) == "\\" then
						i = i + 2
					else
						i = i + 1
					end
				end
				if i > n then
					error("unexpected EOF while looking for matching ``'")
				end -- unclosed backtick
				i = i + 1
			elseif c == " " or c == "\t" or c == "\n" or c == ";" then
				break
			else
				i = i + 1
			end
		end
		-- every newline the word spans ($(…) bodies, quotes, continuations) advances the line
		local w = src:sub(start, i - 1)
		line = line0 + (w:find("\n", 1, true) and select(2, w:gsub("\n", "")) or 0) + lfix
		return w
	end

	-- (memoized by position: the parser peeks the same spot again and again for keywords;
	-- a hit re-applies ws's line effect so nothing observable changes)
	local pk_i, pk_src, pk_w, pk_dl
	local function peekword()
		if pk_i == i and pk_src == src then
			line = line + pk_dl
			return pk_w
		end
		local save, l0 = i, line
		ws()
		local s, e = src:find("^[%a_][%w_]*", i)
		local w = s and src:sub(s, e) or nil
		i = save
		pk_i, pk_src, pk_w, pk_dl = save, src, w, line - l0
		return w
	end

	local brace_group
	-- A for/select body: `do … done`, or bash's `{ … }` alternative
	-- (`for ((i=0; i<3; i++)) { echo $i; }`, `for x in a b; { …; }`).
	local function loop_body()
		skipsep()
		if src:sub(i, i) == "{" then
			return brace_group()
		end
		if peekword() == "do" then
			i = i + 2
		end
		local body, term = parse_stmts({ done = true })
		if term ~= "done" then
			error("syntax error: unexpected end of file") -- (no done)
		end
		return body, term
	end
	brace_group = function() -- parse `{ stmts }` (a function body / group)
		ws()
		if src:sub(i, i) ~= "{" then -- (bash: the token found instead)
			local tok = peekword() or src:sub(i, i)
			error("syntax error near `" .. (tok ~= "" and tok or "newline") .. "'")
		end
		i = i + 1
		local stmts, term = parse_stmts({ ["}"] = true })
		-- a function body that never closes (e.g. an unterminated heredoc ate the `}`)
		-- is a syntax error in bash ("unexpected end of file"), not a lenient no-op.
		if term ~= "}" then
			error("syntax error: unexpected end of file")
		end
		if #stmts == 0 then
			error("syntax error near `}'") -- (`f() { }`: bash)
		end
		return stmts
	end

	-- A function body is usually a `{ … }` group but may be a `( … )` subshell
	-- (bash: `f() ( ... )`). Return a stmt list either way — the subshell form
	-- yields a one-statement list holding a subshell node, so it runs isolated.
	local function func_body()
		ws()
		while src:sub(i, i) == "\n" do
			line = line + 1
			i = i + 1
			ws()
		end -- bash allows newlines before the body
		local bline = line -- the body's first line (a traced call's entry DEBUG reports it)
		if src:sub(i, i) == "(" then
			i = i + 1
			local body, pterm = parse_stmts({ [")"] = true })
			if pterm ~= ")" then
				error("syntax error: unexpected end of file") -- unclosed ( )
			end
			return { { t = "subshell", line = bline, body = body } }, bline, true
		end
		return brace_group(), bline
	end
	-- A function definition, with any trailing redirects (`f() { … } >&2`) that apply
	-- to the whole body on every call.
	local function funcdef_node(nm, dstart, dline)
		local body, bline, subbody = func_body()
		-- capture the definition's exact source text (name/`function` through the
		-- closing `}`) so `declare -f`/`type`/`command -V` can recover it verbatim,
		-- no deparser needed. `src` here is the whole script or the -c/stdin string.
		local deftext = dstart and src:sub(dstart, i - 1) or nil
		local redirs = {}
		while true do
			ws()
			local r = parse_redir()
			if r then
				redirs[#redirs + 1] = r
			else
				break
			end
		end
		return {
			t = "funcdef",
			name = nm,
			body = body,
			deftext = deftext,
			line = dline,
			bline = bline,
			eline = line, -- (where it ends: a readonly function's redefinition is reported there)
			subbody = subbody, -- `f() ( … )`: redirections belong to that subshell (declare -f)
			redirs = (#redirs > 0 and redirs or nil),
		}
	end

	local parse_stmt -- forward: the and-or wrapper (used by case bodies below)

	-- Try to read a redirection at the current position; returns a redir table and
	-- advances i, or nil (leaving i put) if there isn't one. Handles
	-- [N]> [N]>> [N]< >&M N>&M &> [N]>&- ; heredocs (<<) are left to parse_command.
	parse_redir = function()
		local p = i
		local b0 = src:byte(p) -- (only a digit, `{`, `<`, `>` or `&` can start one)
		if not b0 or not ((b0 >= 48 and b0 <= 57) or b0 == 123 or b0 == 60 or b0 == 62 or b0 == 38) then
			return nil
		end
		-- `<(…)` / `>(…)` are process substitutions (word parts), not redirections.
		if src:sub(p, p + 1) == "<(" or src:sub(p, p + 1) == ">(" then
			return nil
		end
		-- `{var}>…` names a fd: bash allocates a fd (>=10) and stores it in `var`.
		-- Only when `{var}` is immediately followed by a redirection operator.
		local fdvar = src:match("^{([%a_][%w_]*)}[<>]", p) or src:match("^{([%a_][%w_]*%b[])}[<>]", p)
		local fd = not fdvar and src:match("^%d+", p) or nil
		-- a digit prefix that doesn't fit an int isn't an fd: `111…111<f` is a command WORD
		-- followed by `<f` (bash's read_token_word legal_number/INT_MAX test)
		if fd and (#fd > 10 or tonumber(fd) > 2147483647) then
			return nil
		end
		local q = fdvar and (p + #fdvar + 2) or (fd and (p + #fd) or p)
		local c = src:sub(q, q)
		local op, tfd
		if c == ">" then
			if src:sub(q, q + 1) == ">&" then
				op = "dup"
				tfd = fd and tonumber(fd) or 1
				q = q + 2
			elseif src:sub(q, q + 1) == ">>" then
				op = "app"
				tfd = fd and tonumber(fd) or 1
				q = q + 2
			elseif src:sub(q, q + 1) == ">|" then
				op = "clobber"
				tfd = fd and tonumber(fd) or 1
				q = q + 2
			else
				op = "out"
				tfd = fd and tonumber(fd) or 1
				q = q + 1
			end
		elseif c == "<" then
			if src:sub(q, q + 2) == "<<<" then -- herestring: [N]<<< word
				i = q + 3
				ws()
				return { op = "herestring", fd = fd and tonumber(fd) or 0, word = word(), fdvar = fdvar } -- raw word (expanded at runtime)
			end
			if src:sub(q, q + 1) == "<<" then -- heredoc: [N]<<[-] DELIM  (body collected after the line)
				local strip = false
				q = q + 2
				if src:sub(q, q) == "-" then
					strip = true
					q = q + 1
				end
				i = q
				ws()
				local draw = strip_contin(word()) -- (`<<\EOT\<newline>4` is EOT4)
				if draw == "" then -- (no delimiter word: bash's token after `<<`)
					local tok = i > n and "newline" or (src:match("^[;&|<>]+", i) or src:sub(i, i))
					error("syntax error near `" .. (tok == "\n" and "newline" or tok) .. "'")
				end
				-- ANY quoting anywhere in the delimiter word makes the body literal (bash);
				-- the delimiter itself is the word with all quotes removed.
				local quoted = draw:find("['\"\\]") ~= nil
				local r = {
					op = "heredoc",
					fd = fd and tonumber(fd) or 0,
					-- (`<<-`: the delimiter's own leading tabs go too, like each line's)
					delim = strip and (dequote_word(draw):gsub("^\t+", "")) or dequote_word(draw),
					rawdelim = draw, -- as written (`declare -f` prints it so)
					expand = not quoted,
					strip = strip,
					fdvar = fdvar,
				}
				if #heredocs_pending >= 16 then -- (bash's HEREDOC_MAX: a fatal syntax error)
					error("maximum here-document count exceeded")
				end
				heredocs_pending[#heredocs_pending + 1] = r
				return r
			end
			if src:sub(q, q + 1) == "<>" then
				op = "rw"
				tfd = fd and tonumber(fd) or 0
				q = q + 2 -- open for read+write
			elseif src:sub(q, q + 1) == "<&" then
				op = "dupin"
				tfd = fd and tonumber(fd) or 0
				q = q + 2
			else
				op = "in"
				tfd = fd and tonumber(fd) or 0
				q = q + 1
			end
		-- `&>`/`&>>` (redirect both stdout+stderr) take NO fd prefix: a digit before
		-- them (`2&>1`) is a command word, not an fd, so leave it (parse_redir re-runs
		-- on the `&>` after the word is read).
		elseif c == "&" and not fd and src:sub(q, q + 2) == "&>>" then
			op = "appboth"
			tfd = 1
			q = q + 3
		elseif c == "&" and not fd and src:sub(q, q + 1) == "&>" then
			op = "outboth"
			tfd = 1
			q = q + 2
		else
			return nil
		end
		i = q
		ws()
		-- stop_paren: a redirect target is a metacharacter-terminated word, so `)` ends it
		-- — `(cmd >&7)` / `(cmd >f)` must read `7`/`f` and leave `)` to close the subshell,
		-- not swallow it into the target (which unbalanced the parse and dropped the pipe).
		local raw = word(true)
		-- a redirection with NO word (`echo >`, `cmd <;`) is a syntax error in bash
		-- (status 2). A quoted empty target (`> ''`) is a real, empty filename — that's
		-- a runtime failure, not a parse error — so key on the raw word being absent.
		if raw == "" then
			error("syntax error near `" .. (src:sub(i, i) == "" and "newline" or src:sub(i, i)) .. "'")
		end
		return { fd = tfd, op = op, target = unquote(raw), src = raw, fdvar = fdvar, line = line } -- (src: `declare -f`)
	end

	-- Parse ONE assignment at the cursor (NAME=… / NAME[i]=… / NAME+=… /
	-- NAME=(array)); returns an assign node, or nil (cursor unchanged) if there
	-- isn't one. Used for both statements and leading prefix assignments.
	-- Parse an array literal `( elem elem … )` with `i` positioned ON the `(`.
	-- Each element is `value` or `[sub]=value` / `[sub]+=value`; the subscript may
	-- nest brackets (`[a[0]]=x`). Consumes through the closing `)`.
	local function parse_array_elems()
		i = i + 1
		local elems = {}
		local line0, closed = line, false
		while i <= n do
			ws()
			local c = src:sub(i, i)
			if c == ")" then
				i = i + 1
				closed = true
				break
			end
			if c == "\n" then
				line = line + 1
				i = i + 1
			elseif c == "#" then
				-- a comment runs to end of line (words never start here: ws() just ran)
				while i <= n and src:sub(i, i) ~= "\n" do
					i = i + 1
				end
			elseif c == "" then
				break
			elseif c == "&" or c == ";" or c == "|" or ((c == "<" or c == ">") and src:sub(i + 1, i + 1) ~= "(") then
				-- a control operator inside the list (`a=(x & y)`): bash's recoverable
				-- syntax error at that token, which discards the rest of the LINE — later
				-- lines of a multi-line literal then parse as ordinary commands (bash)
				-- (the token is the whole operator: `<>`, `>>`, `&&`, …)
				local tok = src:match("^[<>]+", i) or src:match("^[&|;][&|;]?", i) or c
				while i <= n and src:sub(i, i) ~= "\n" do
					i = i + 1
				end
				error({ __curse_arraylit = true, tok = tok })
			elseif c == "(" then
				-- an ELEMENT can't be `(` (a nested `()`, as in `a=( inside=() )`): bash
				-- reports a syntax error but the assignment is NON-fatal (the var stays
				-- unset, the script CONTINUES). Resync past the outer `)` that closes the
				-- array, then raise a RECOVERABLE error the line-parser marks as such.
				local depth = 0
				while i <= n do
					local ch = src:sub(i, i)
					if ch == "(" then
						depth = depth + 1
					elseif ch == ")" then
						depth = depth - 1
						if depth < 0 then
							i = i + 1
							break
						end
					end
					i = i + 1
				end
				error({ __curse_arraylit = true })
			else
				-- `[foo bar]=v`: a subscript is read as one unit, blanks and all, when a
				-- `=`/`+=` follows its closing `]` (bash's compound-assignment reader)
				local pre = ""
				if c == "[" then
					local depth, k = 0, i
					while k <= n do
						local ch = src:sub(k, k)
						if ch == "\\" then
							k = k + 2
						elseif ch == "'" then
							k = (src:find("'", k + 1, true) or n) + 1
						elseif ch == '"' then -- (a \" inside doesn't close it)
							k = k + 1
							while k <= n and src:sub(k, k) ~= '"' do
								k = k + (src:sub(k, k) == "\\" and 2 or 1)
							end
							k = k + 1
						elseif ch == "\n" then
							break
						else
							if ch == "[" then
								depth = depth + 1
							elseif ch == "]" then
								depth = depth - 1
								if depth == 0 then
									break
								end
							end
							k = k + 1
						end
					end
					if src:sub(k, k) == "]" and (src:sub(k + 1, k + 1) == "=" or src:sub(k + 1, k + 2) == "+=") then
						pre = src:sub(i, k)
						i = k + 1
					end
				end
				local w = pre .. word(true)
				if w == "" then
					break
				end
				local keyraw, eop, rhs = nil, "=", w
				if w:sub(1, 1) == "[" then
					local depth, close, j = 0, nil, 1 -- (brackets inside quotes don't count)
					while j <= #w do
						local ch = w:sub(j, j)
						if ch == "\\" then
							j = j + 1
						elseif ch == "'" then
							j = w:find("'", j + 1, true) or #w
						elseif ch == '"' then
							j = j + 1
							while j <= #w and w:sub(j, j) ~= '"' do
								j = j + (w:sub(j, j) == "\\" and 2 or 1)
							end
						elseif ch == "[" then
							depth = depth + 1
						elseif ch == "]" then
							depth = depth - 1
							if depth == 0 then
								close = j
								break
							end
						end
						j = j + 1
					end
					if close then
						local after = w:sub(close + 1)
						if after:sub(1, 2) == "+=" then
							keyraw = w:sub(2, close - 1)
							eop = "+="
							rhs = after:sub(3)
						elseif after:sub(1, 1) == "=" then
							keyraw = w:sub(2, close - 1)
							eop = "="
							rhs = after:sub(2)
						end
					end
				end
				if keyraw == nil then
					-- bare element: brace-expand into multiple elements ({1..9}, {a,b})
					local factors = brace_factors(rhs)
					if factors then
						stream_factors(factors, function(x)
							elems[#elems + 1] = { key = nil, op = "=", word = parse_word(x) }
							return #elems >= BRACE_CAP
						end)
					else
						elems[#elems + 1] = { key = nil, op = "=", word = parse_word(rhs) }
					end
				else
					-- KEYED element. bash brace-expands the value only for an INDEXED array,
					-- where a multi-word expansion also DE-KEYS it (`a=([k]=-{a,b}-)` ->
					-- [0]="[k]=-a-" [1]="[k]=-b-"); an ASSOCIATIVE array keeps it keyed and
					-- literal (`declare -A a; a=([k]=-{a,b}-)` -> a[k]="-{a,b}-"). The array
					-- type isn't known until runtime, so precompute the brace-expanded BARE
					-- words of the whole token and let do_arrayassign pick (indexed -> bare).
					local elem = { key = keyraw, op = eop, word = parse_word(rhs) }
					local factors = brace_factors(w)
					if factors then
						elem.brace_bare = {}
						stream_factors(factors, function(x)
							elem.brace_bare[#elem.brace_bare + 1] = parse_word(x)
							return #elem.brace_bare >= BRACE_CAP
						end)
					end
					elems[#elems + 1] = elem
				end
			end
		end
		if not closed then -- (never closed: bash's error, at the line it began on)
			line = line0
			comsub_eof = false
			error("unexpected EOF while looking for matching `)'")
		end
		return elems
	end

	local function try_assign()
		local name = src:match("^([%a_][%w_]*)", i)
		if not name then
			return nil
		end
		local p = i + #name
		local subidx = nil
		if src:sub(p, p) == "[" then
			-- find the MATCHING ] (subscript may contain nested [ ] via ${a[i]}); quoted
			-- text and escapes don't count (`A[']']=10` has the key `]`)
			local depth, q = 1, p + 1
			while q <= n and depth > 0 do
				local ch = src:sub(q, q)
				if ch == "\\" then
					q = q + 1
				elseif ch == "'" then
					q = (src:find("'", q + 1, true) or n)
				elseif ch == '"' then
					local e = q + 1
					while e <= n and src:sub(e, e) ~= '"' do
						e = e + (src:sub(e, e) == "\\" and 2 or 1)
					end
					q = e
				elseif ch == "$" and src:sub(q + 1, q + 1) == "(" then
					local ok, nq = pcall(scan_cmdsub, src, q + 2)
					q = ok and nq - 1 or q
				elseif ch == "$" and src:sub(q + 1, q + 1) == "{" then
					q = scan_braces(src, q + 1) - 1
				elseif ch == "[" then
					depth = depth + 1
				elseif ch == "]" then
					depth = depth - 1
				end
				if depth == 0 then
					break
				end
				q = q + 1
			end
			if depth == 0 and src:sub(q + 1, q + 1):match("[+=]") then
				subidx = src:sub(p + 1, q - 1)
				p = q + 1
			end
		end
		local op = nil
		if src:sub(p, p + 1) == "+=" then
			op = "+="
			p = p + 2
		elseif src:sub(p, p) == "=" then
			op = "="
			p = p + 1
		end
		if not op then
			return nil
		end
		i = p
		if src:sub(i, i) == "(" then -- array literal
			local pstart = i
			local elems = parse_array_elems()
			local nx = src:sub(i, i)
			if nx ~= "" and not nx:match("[%s;&|)<>]") then
				-- `a=(4*3)/2`: text goes on past the `)` — then it's one ORDINARY word
				-- (bash), assigned as a string (an integer var evaluates it)
				local head = src:sub(pstart, i - 1)
				local raw = head .. word(true)
				return { t = "assign", name = name, index = subidx, append = (op == "+="), rhs = parse_word(raw) }
			end
			-- raw parenthesized text: a NAME=(…) used as a command PREFIX is a literal
			-- string in bash (arrays can't be env bindings), decided at exec time.
			return {
				t = "arrayassign",
				name = name,
				elems = elems,
				append = (op == "+="),
				raw = src:sub(pstart, i - 1),
				index = subidx,
			}
		end
		-- The value is read from right after `=` with NO leading-whitespace skip: an
		-- empty value (`X= cmd`) must stay empty, not absorb the next word as `word()`
		-- (which skips blanks) would. Only read when a value actually follows.
		local c0 = src:sub(i, i)
		-- (`#` right after `=` is part of the value — `D=#abcd` — not a comment)
		if c0 == "" or c0:match("[ \t\n;&|)]") then
			return { t = "assign", name = name, index = subidx, append = (op == "+="), rhs = parse_word("") }
		end
		local raw = word(true) -- stop at unquoted ) so `(x=2)` closes the subshell
		if not subidx and op == "=" and raw:sub(1, 3) == "$((" and raw:sub(-2) == "))" then
			-- (a bad expression — or `$((1))$((2))` — takes the word path: its error is a
			-- runtime one, reported when the assignment runs)
			local aok, ae = pcall(arith, raw:sub(4, -3))
			if aok then
				return { t = "assign", name = name, arith = ae, rhssrc = raw } -- (rhssrc: declare -f)
			end
		end
		return { t = "assign", name = name, index = subidx, append = (op == "+="), rhs = parse_word(raw) }
	end

	local function parse_command()
		ws()
		-- reset the per-command alias recursion guard, then expand a leading alias in
		-- place (handles a compound-command alias like LEFT='{' before dispatch; the
		-- command-word case with leading assignments/redirects re-runs in the simple
		-- loop, sharing this guard so a self-referential alias can't loop).
		if cmd_prex == i then
			cmd_prex = nil -- parse_stmts already expanded this command word
		else
			alias_seen = {}
			alias_next = false
			alias_tail = nil
			try_alias(true)
		end
		-- an alias that expanded to a comment (`alias c=#`): the rest of the line is a comment
		-- and there is NO command ($? unchanged)
		if src:sub(i, i) == "#" then
			while i <= n and src:sub(i, i) ~= "\n" do
				i = i + 1
			end
			return { t = "noop", line = line }
		end
		local dstart, dline = i, line -- byte offset + line where this command (hence a funcdef) begins
		-- coproc [NAME] compound-command | coproc simple-command: an async command wired to
		-- the shell by two pipes. A NAME (default COPROC) is only allowed before a COMPOUND
		-- command — before a simple one, that word is the command (bash).
		if peekword() == "coproc" and is_blank(src:sub(i + 6, i + 6)) then
			ws()
			i = i + 6
			ws()
			local function compound_at(p)
				local c = src:sub(p, p)
				if c == "{" or c == "(" or src:sub(p, p + 1) == "[[" then
					return true
				end
				local w = src:match("^[%a_][%w_]*", p)
				return w == "while" or w == "until" or w == "for" or w == "if" or w == "case" or w == "select"
			end
			local name = "COPROC"
			if not compound_at(i) then
				-- (any word: an invalid NAME — `coproc @ {…}` — is a runtime error, bash)
				local s, e = src:find("^[^%s;&|()<>]+", i)
				if s then
					local k = e + 1
					while is_blank(src:sub(k, k)) do
						k = k + 1
					end
					if k > e + 1 and compound_at(k) then
						name, i = src:sub(s, e), k
					end
				end
			end
			return { t = "coproc", name = name, cmd = parse_command(), line = dline }
		end
		-- function NAME [()] { … }   or   NAME() { … }
		-- Function names may contain far more than identifier chars (bash: `show-len`,
		-- `git-foo`, `a.b`), so match a run of non-metacharacter word bytes here.
		if peekword() == "function" then
			ws()
			i = i + 8
			ws()
			local s, e = src:find("^[%w_:%.+@/%%%^~,!][%w_%.%-:+@/!#=%%%^~,]*", i)
			if not s then
				if i > n then
					error("syntax error: unexpected end of file")
				end
				local tok = src:match("^[;&|]+", i) or src:sub(i, i)
				error("syntax error near `" .. (tok == "\n" and "newline" or tok) .. "'")
			end
			local nm = src:sub(s, e)
			i = e + 1
			ws()
			-- optional `( )` (bash: `function f () { … }`, spaces allowed between parens)
			if src:sub(i, i) == "(" then
				local k = i + 1
				while is_blank(src:sub(k, k)) do
					k = k + 1
				end
				if src:sub(k, k) == ")" then
					i = k + 1
				end
			end
			return funcdef_node(nm, dstart, dline)
		end
		do
			-- bash is lenient about funcdef names: `=` is allowed in the middle
			-- (`func-name=ext () { … }`), as long as the name doesn't END in `=` — that
			-- is an array/scalar assignment (`a=()`, `x=`), which the assignment path
			-- handles instead (and `a=(` is caught there before we get here anyway).
			local s, e = src:find("^[%w_:%.+@/%%%^~,][%w_%.%-:+@/!#=%%%^~,]*", i)
			if s and src:sub(e, e) ~= "=" then
				local j = e + 1
				while is_blank(src:sub(j, j)) do
					j = j + 1
				end
				-- NAME ( ) — a space is allowed between the parens (bash: `fun ( ) { … }`)
				if src:sub(j, j) == "(" then
					local k = j + 1
					while is_blank(src:sub(k, k)) do
						k = k + 1
					end
					if src:sub(k, k) == ")" then
						local nm = src:sub(s, e)
						-- (a reserved word can't be a NAME() function name: bash stops at the
						-- token its grammar didn't expect there)
						local RW = { ["for"] = "(", ["select"] = "(", ["if"] = ")", ["while"] = ")",
							["until"] = ")", ["do"] = "do", ["done"] = "done", ["then"] = "then",
							["else"] = "else", ["elif"] = "elif", ["fi"] = "fi", ["esac"] = "esac" }
						if RW[nm] then
							error("syntax error near `" .. RW[nm] .. "'")
						end
						i = k + 1
						return funcdef_node(nm, dstart, dline)
					end
				end
			end
		end
		-- A funcdef whose "name" is an EXPANSION (`$foo-bar()`, `foo-$(x)()`): bash
		-- parses it and reports "not a valid identifier" at RUNTIME (status 1), not a
		-- parse error. Scan the word (balancing $()); if it's `$`-bearing and followed
		-- by `()`, treat it as a funcdef with that (invalid) name.
		local d1 = src:find("[$ \t\n(;&|<>]", i) -- (no `$` before the word ends: can't be one)
		if d1 and src:sub(d1, d1) == "$" then
			local j, depth = i, 0
			while j <= n do
				local c = src:sub(j, j)
				if c == "$" and src:sub(j + 1, j + 1) == "(" then
					depth = depth + 1
					j = j + 2
				elseif c == "(" and depth > 0 then
					depth = depth + 1
					j = j + 1
				elseif c == ")" and depth > 0 then
					depth = depth - 1
					j = j + 1
				elseif depth == 0 and (c == "" or c:match("[ \t\n(;&|<>]")) then
					break
				else
					j = j + 1
				end
			end
			if j > i and src:sub(i, j - 1):find("$", 1, true) then
				local k = j
				while is_blank(src:sub(k, k)) do
					k = k + 1
				end
				if src:sub(k, k) == "(" then
					local m = k + 1
					while is_blank(src:sub(m, m)) do
						m = m + 1
					end
					if src:sub(m, m) == ")" then
						local nm = src:sub(i, j - 1)
						i = m + 1
						return funcdef_node(nm, dstart, dline)
					end
				end
			end
		end
		-- for (( init; cond; step )) ; do BODY done   OR   for NAME in WORDS; do … done
		-- `select NAME [in WORDS]; do …; done` shares the for-in header/body grammar
		if peekword() == "for" or peekword() == "select" then
			local issel = peekword() == "select"
			local ln = line
			ws()
			local s0 = i -- (the loop's source span: see the whilec node)
			i = i + (issel and 6 or 3)
			ws()
			if not issel and src:sub(i, i + 1) == "((" then
				local body, ni = grab_dparen(src, i + 2)
				i = ni
				-- split the header at its top-level `;`s — not inside quotes, $(…), ${…}
				local slots, k0, k, bn = {}, 1, 1, #body
				while k <= bn do
					local ch = body:sub(k, k)
					if ch == "\\" then
						k = k + 2
					elseif ch == "'" or ch == '"' or ch == "`" then
						local e = body:find(ch, k + 1, true)
						k = (e or bn) + 1
					elseif ch == "$" and body:sub(k + 1, k + 1) == "(" then
						k = scan_cmdsub(body, k + 2)
					elseif ch == "$" and body:sub(k + 1, k + 1) == "{" then
						k = scan_braces(body, k + 1)
					elseif ch == ";" then
						slots[#slots + 1] = body:sub(k0, k - 1)
						k0 = k + 1
						k = k + 1
					else
						k = k + 1
					end
				end
				slots[#slots + 1] = body:sub(k0)
				if #slots ~= 3 then -- (bash then shows the whole `(( … ))')
					error({
						__curse_perr = true,
						msg = #slots < 3 and "syntax error: arithmetic expression required" or "syntax error: `;' unexpected",
						text = "((" .. body .. "))",
					})
				end
				local a, b, c = slots[1], slots[2], slots[3]
				loopId = loopId + 1
				local id = loopId
				local h1 = i -- (past the header: a hot loop's fragment re-states it without init)
				local body_stmts = loop_body()
				local s1 = i - 1
				-- Parse each arith slot eagerly, but a SYNTAX ERROR in a slot (`i='3'`,
				-- `++'i'`) is deferred to runtime — bash reports such an error when the loop
				-- executes and runs zero iterations non-fatally, rather than failing to parse
				-- the whole script (same rule as `$((…))`). A clean parse is unchanged.
				local function parith(s)
					if not s:match("%S") then
						return nil
					end
					local ok, ast = pcall(arith, s)
					if ok then
						return ast
					end
					return { k = "arith_perr", raw = s }
				end
				return {
					t = "forc",
					id = id,
					line = ln,
					init = parith(a),
					cond = parith(b),
					step = parith(c),
					src = { a, b, c }, -- the slots as written (`declare -f` prints them)
					body = body_stmts,
					redirs = tail_redirs(),
					_srcs = src,
					_h1 = h1,
					_s1 = s1,
				}
			end
			-- for NAME in WORDS. Capture NAME as a whole token (not just a valid
			-- identifier): bash accepts `for i.j`/`for -` at PARSE time and reports the
			-- invalid name as a non-fatal RUNTIME error (status 1), so the interp checks.
			-- (each header word can come from a trailing-blank alias chain: `FOR eye IN …`)
			try_alias(false)
			local s, e = src:find("^[^%s;#()]+", i)
			if not s then -- (bash: the token found instead of a name)
				if i > n then
					error("syntax error: unexpected end of file")
				end
				local tok = src:match("^[;&|]+", i) or src:sub(i, i)
				error("syntax error near `" .. (tok == "\n" and "newline" or tok) .. "'")
			end
			local name = src:sub(s, e)
			i = e + 1
			-- bash allows blank lines / comments between the loop var and `in` (but a
			-- `;` terminates the header — `for i;` iterates "$@").
			while true do
				ws()
				local c = src:sub(i, i)
				if c == "\n" then
					line = line + 1
					i = i + 1
				elseif c == "#" then
					while i <= n and src:sub(i, i) ~= "\n" do
						i = i + 1
					end
				else
					break
				end
			end
			local words = {}
			try_alias(false)
			do -- (after the name: `in`, `do`, or a separator — `for x y` is an error)
				local pw, c = peekword(), src:sub(i, i)
				if pw and pw ~= "" and pw ~= "in" and pw ~= "do" and not c:match("[;\n&|()]") and i <= n then
					error("syntax error near `" .. pw .. "'")
				end
			end
			if peekword() == "in" then
				i = i + 2
				while true do
					ws()
					try_alias(false)
					local c = src:sub(i, i)
					if c == ";" or c == "\n" or c == "" or c == "#" then
						break
					end
					if peekword() == "do" then
						break
					end
					-- an unquoted bare `(` in word position is a syntax error (`for x in a=()`,
					-- `for x in (`); extglob/$()/<() are consumed inside word(true).
					if c == "(" or c == ")" then
						error("syntax error near `" .. c .. "'")
					end
					local w = word(true)
					if w == "" then
						break
					end
					add_word(words, w)
				end
			else
				words = { parse_word('"$@"') } -- `for NAME; do …` iterates the positional params
			end
			loopId = loopId + 1
			local id = loopId
			local body_stmts = loop_body()
			if #body_stmts == 0 then
				error("syntax error near `done'")
			end -- bash: empty do/done is invalid
			local s1 = i - 1
			return {
				t = issel and "select" or "forin",
				id = id,
				line = ln,
				name = name,
				words = words,
				body = body_stmts,
				redirs = tail_redirs(),
				_srcs = src,
				_s0 = s0,
				_s1 = s1,
			}
		end
		-- while/until COND; do BODY; done  — COND is a command list; the loop runs
		-- while its exit status is 0 (until: while it's non-zero). `while (( expr ))`
		-- works because (( )) parses as an arithcmd statement inside COND.
		if peekword() == "while" or peekword() == "until" then
			local kind = peekword()
			local ln = line
			local s0 = i -- (the loop's source span: a hot loop is compiled from its own text)
			i = i + #kind
			loopId = loopId + 1
			local id = loopId
			local cond, t1 = parse_stmts({ ["do"] = true })
			if t1 ~= "do" then
				error(t1 == nil and "syntax error: unexpected end of file" or ("syntax error: `" .. kind .. "' expected `do'"))
			end
			if #cond == 0 then
				error("syntax error near `do'") -- (an empty condition: bash)
			end
			local body_stmts, t2 = parse_stmts({ done = true })
			if t2 ~= "done" then
				error(t2 == nil and "syntax error: unexpected end of file" or ("syntax error: `" .. kind .. "' expected `done'"))
			end
			if #body_stmts == 0 then
				error("syntax error near `done'")
			end -- bash: empty do/done is invalid
			local s1 = i - 1
			return {
				t = "whilec",
				id = id,
				line = ln,
				cond = cond,
				body = body_stmts,
				negate = (kind == "until"),
				redirs = tail_redirs(),
				_srcs = src,
				_s0 = s0,
				_s1 = s1,
			}
		end
		-- if COND; then BODY [elif COND; then BODY]* [else BODY] fi — COND is a
		-- command list; the branch is taken when its exit status is 0.
		if peekword() == "if" then
			local ln = line
			i = i + 2
			local clauses = {}
			while true do
				local cond, ct = parse_stmts({ ["then"] = true })
				if #cond == 0 and ct == "then" then
					error("syntax error near `then'") -- (an empty condition: bash)
				end
				local body, term = parse_stmts({ elif = true, ["else"] = true, fi = true })
				if #body == 0 then
					error(term and ("syntax error near `" .. term .. "'") or "syntax error: unexpected end of file")
				end -- bash: empty then/elif body
				clauses[#clauses + 1] = { cond = cond, body = body }
				if term == "else" then
					local eb = parse_stmts({ fi = true })
					if #eb == 0 then
						error("syntax error near `fi'")
					end -- bash: empty else body
					clauses[#clauses + 1] = { cond = nil, body = eb }
					break
				elseif term == "fi" then
					break
				elseif term ~= "elif" then
					error("syntax error: unexpected end of file") -- (no fi)
				end
			end
			return { t = "if", line = ln, clauses = clauses, redirs = tail_redirs() }
		end
		-- (( expr )) arithmetic command: exit status 0 if expr != 0, else 1. But `((`
		-- is arith ONLY when it's a balanced `(( expr ))`; `((cmd) …)` is nested
		-- subshells (#2337). Disambiguate by scanning (quote-aware): if the paren
		-- balance first returns to 0 at a `)` that is NOT followed by another `)`, the
		-- `(` closed a subshell, not the arith — fall through to the subshell parser.
		if src:sub(i, i + 1) == "((" then
			local j, d, isarith = i + 2, 0, false
			while j <= n do
				local c = src:sub(j, j)
				if c == "\\" then
					j = j + 2
				elseif c == "'" or c == '"' then
					local q = c
					j = j + 1
					while j <= n and src:sub(j, j) ~= q do
						if src:sub(j, j) == "\\" and q == '"' then
							j = j + 2
						else
							j = j + 1
						end
					end
					j = j + 1
				elseif c == "(" then
					d = d + 1
					j = j + 1
				elseif c == ")" then
					if d == 0 then
						isarith = (src:sub(j + 1, j + 1) == ")")
						break
					end
					d = d - 1
					j = j + 1
				else
					j = j + 1
				end
			end
			if j > n and d == 0 then -- (`(( 1 +` never closed: bash's arithmetic EOF error)
				comsub_eof = false
				error("unexpected EOF while looking for matching `)'")
			end
			if isarith then
				local body, ni = grab_dparen(src, i + 2)
				i = ni
				-- a malformed `(( expr ))` (bad lvalue) is a NON-fatal runtime error in bash,
				-- so defer the parse failure to eval (caught by the arithcmd handler) rather
				-- than aborting the whole parse.
				local ok, e = pcall(arith, body)
				return {
					t = "arithcmd",
					line = line,
					expr = ok and e or { k = "matherr", err = e, raw = body },
					src = body, -- as written (`declare -f` prints it)
					redirs = tail_redirs(),
				}
			end
			-- not arith: fall through to the subshell parser below (i still at the first `(`)
		end
		-- [[ EXPR ]] conditional (no word-splitting; == is glob, =~ is regex)
		if src:sub(i, i + 1) == "[[" and is_blank(src:sub(i + 2, i + 2)) then
			i = i + 2
			local toks, quoted = {}, {}
			while true do
				ws()
				if src:sub(i, i) == "\n" then
					line = line + 1
					i = i + 1 -- continuation inside [[ ]]
				elseif i > n or src:sub(i, i + 1) == "]]" then
					if src:sub(i, i + 1) == "]]" then
						i = i + 2
					end
					break
				elseif toks[#toks] == "=~" then
					-- the =~ operand is ONE regex word. TWO nesting counters, because bash
					-- treats `()` and `[]` differently here: a `( … )` group SHIELDS inner
					-- spaces (`([a b])` stays whole) but a `[ … ]` bracket class does NOT —
					-- bash splits `[[ a =~ [a b] ]]` at the space into two words (a syntax
					-- error). Yet a `]]` INSIDE a bracket class is not the terminator, so
					-- `[[:space:]]` reads whole. So: `pd` (parens) gates space/`)` breaks;
					-- `depth` (parens+brackets) gates the `]]` terminator. Operator metachars
					-- `;` `&` `<` `>` end the operand outside any group (`|` does not — it is
					-- an ordinary regex char).
					local rs, pd, depth = i, 0, 0
					while i <= n do
						local c0 = src:sub(i, i)
						if depth == 0 and src:sub(i, i + 1) == "]]" then
							break
						end
						if pd == 0 and (c0 == "\n" or c0 == " " or c0 == "\t" or c0 == ")") then
							break
						end
						if pd == 0 and depth == 0 and (c0 == ";" or c0 == "&" or c0 == "<" or c0 == ">") then
							break
						end
						if c0 == "\\" then
							i = i + 2
						elseif c0 == "'" then
							i = i + 1
							while i <= n and src:sub(i, i) ~= "'" do
								i = i + 1
							end
							i = i + 1
						elseif c0 == '"' then
							i = i + 1
							while i <= n and src:sub(i, i) ~= '"' do
								i = i + (src:sub(i, i) == "\\" and 2 or 1)
							end
							i = i + 1
						elseif c0 == "(" then
							pd = pd + 1
							depth = depth + 1
							i = i + 1
						elseif c0 == ")" then
							if pd > 0 then
								pd = pd - 1
							end
							if depth > 0 then
								depth = depth - 1
							end
							i = i + 1
						elseif c0 == "[" then
							depth = depth + 1
							i = i + 1
						elseif c0 == "]" then
							if depth > 0 then
								depth = depth - 1
							end
							i = i + 1
						else
							i = i + 1
						end
					end
					toks[#toks + 1] = src:sub(rs, i - 1)
					quoted[#toks] = false
				elseif src:sub(i, i + 1) == "!(" and not (sh and sh.shopt and sh.shopt.extglob or (not sh and extglob_on))
					and (toks[#toks] == nil or toks[#toks] == "&&" or toks[#toks] == "||" or toks[#toks] == "!" or toks[#toks] == "(")
				then
					-- (only where `!` can be the negation operator: an operand after == etc. is a
					-- pattern, and bash matches extglob patterns in [[ ]] regardless)
					-- without extglob, `[[ !(…) ]]` is the `!` operator applied to a ( … ) group
					toks[#toks + 1] = "!"
					quoted[#toks] = false
					i = i + 1
				else
					local before = i
					local w = word(true, true) -- split on <,>,(,) operators (no spaces needed in [[ ]])
					if w == "" then
						-- word() stalled on a self-delimiting metacharacter. `&&`/`||` are
						-- two-char operator tokens; `(`, `)`, `<`, `>`, `;`, … are one char
						-- (each becomes its own token so the tokenizer makes progress).
						if i == before then
							local two = src:sub(i, i + 1)
							if two == "&&" or two == "||" then
								w = two
								i = i + 2
							else
								w = src:sub(i, i)
								i = i + 1
							end
						else
							break
						end
					end
					local c1 = w:sub(1, 1)
					toks[#toks + 1] = w
					quoted[#toks] = (c1 == '"' or c1 == "'")
				end
			end
			return { t = "dbracket", line = line, expr = parse_dbracket(toks, quoted), redirs = tail_redirs() }
		end
		-- brace group { list; }  and subshell ( list )  — optional trailing redirs
		if src:sub(i, i) == "{" and src:sub(i + 1, i + 1):match("[ \t\n]") then
			i = i + 1
			local body, term = parse_stmts({ ["}"] = true })
			if term ~= "}" then
				error("syntax error: unexpected end of file")
			end -- unclosed { }
			if #body == 0 then
				error("syntax error near `}'") -- (`{ }`: bash)
			end
			local redirs = {}
			while true do
				ws()
				local r = parse_redir()
				if r then
					redirs[#redirs + 1] = r
				else
					break
				end
			end
			return { t = "group", line = line, body = body, redirs = (#redirs > 0 and redirs or nil) }
		end
		if src:sub(i, i) == "(" then
			i = i + 1
			local body, pterm = parse_stmts({ [")"] = true })
			if pterm ~= ")" then
				error("syntax error: unexpected end of file") -- unclosed ( )
			end
			local redirs = {}
			while true do
				ws()
				local r = parse_redir()
				if r then
					redirs[#redirs + 1] = r
				else
					break
				end
			end
			return { t = "subshell", line = line, body = body, redirs = (#redirs > 0 and redirs or nil) }
		end
		-- case WORD in  PAT|PAT) BODY ;;  … esac
		if peekword() == "case" then
			local ln = line
			i = i + 4
			ws()
			-- bash requires the case subject on the same line as `case`; a newline or
			-- separator before any word (`case\nin esac`, `case;`) is a syntax error.
			-- word(true) also stops at a bare `(` so `case a=() in` errors (expected in).
			local subw = word(true)
			if subw == "" then
				local c = src:sub(i, i)
				error("syntax error near `" .. (c == "\n" and "newline" or (c == "" and "esac" or c)) .. "'")
			end
			local subject = parse_word(subw)
			while src:sub(i, i):match("[ \t\n]") do
				if src:sub(i, i) == "\n" then
					line = line + 1
				end
				i = i + 1
			end
			if peekword() == "in" then
				i = i + 2
			else -- (bash: the token that isn't `in`)
				error("syntax error near `" .. (peekword() or src:sub(i, i)) .. "'")
			end -- ysh `case (x) { }` etc. rejected
			-- separator skipper that STOPS at ;; (so a clause body ends there)
			local function skip_sep()
				while i <= n do
					if src:sub(i, i + 2) == ";;&" then
						return "dsemi_amp"
					end -- ;;& (test next patterns)
					if src:sub(i, i + 1) == ";;" then
						return "dsemi"
					end -- ;; (stop)
					if src:sub(i, i + 1) == ";&" then
						return "semi_amp"
					end -- ;& (fall through)
					local c = src:sub(i, i)
					if c == "\n" then
						-- a heredoc opened by a command in this arm has its body after the
						-- newline (like the shared skipsep) — collect it, else it leaks as
						-- commands (`x) cat <<EOF … EOF ;;`).
						if #heredocs_pending > 0 then
							collect_heredocs()
						else
							line = line + 1
							i = i + 1
						end
					elseif c:match("[ \t;]") then
						i = i + 1
					elseif c == "#" then
						while i <= n and src:sub(i, i) ~= "\n" do
							i = i + 1
						end
					else
						return nil
					end
				end
				return "eof"
			end
			local clauses = {}
			while true do
				skip_sep()
				if peekword() == "esac" then
					i = i + 4
					break
				end
				-- Reaching EOF without a closing `esac` is a syntax error (bash). This
				-- happens when a clause body swallowed `esac` as a command ARGUMENT — e.g.
				-- `case x in a) echo a esac` (no `;;`): `echo a esac` is one command, so the
				-- case is left unterminated, exactly as bash sees it.
				if i > n then
					error("syntax error: unexpected end of file")
				end
				if src:sub(i, i) == "(" then
					i = i + 1
				end -- optional leading (
				-- read to the clause-terminating ), balancing extglob parens @(a|b) and
				-- copying quoted sections verbatim (their ) / | are not structural).
				local patstr, depth = {}, 0
				while i <= n do
					local c = src:sub(i, i)
					if c == ")" and depth == 0 then
						break
					end
					if depth == 0 and is_blank(c) then -- (between words only `|` or `)`)
						local k = i
						while is_blank(src:sub(k, k)) do
							k = k + 1
						end
						local prev = table.concat(patstr):match("(%S)%s*$")
						local nx = src:sub(k, k)
						if prev and prev ~= "|" and nx ~= "" and nx ~= "|" and nx ~= ")" and nx ~= "\n" then
							error("syntax error near `" .. (src:match("^[^%s;&|()<>]+", k) or nx) .. "'")
						end
					end
					if c == "\\" then -- a backslash escapes the next char (incl. a quote or `)`):
						patstr[#patstr + 1] = src:sub(i, i + 1)
						i = i + 2 -- copy both, don't treat `\'` as a quote
					elseif c == "'" or c == '"' then
						patstr[#patstr + 1] = c
						i = i + 1
						while i <= n and src:sub(i, i) ~= c do
							patstr[#patstr + 1] = src:sub(i, i)
							i = i + 1
						end
						patstr[#patstr + 1] = src:sub(i, i)
						i = i + 1
					elseif c == "$" and src:sub(i + 1, i + 1) == "(" and src:sub(i + 2, i + 2) ~= "(" then
						-- a $( … ) in a pattern: its body is checked as it's read (bash's
						-- parse_comsub — which doesn't inherit the case-pattern state)
						local je = scan_cmdsub(src, i + 2)
						local cbody = src:sub(i + 2, je - 2)
						if not alias_on and not cbody:find("[@!+*?]%(") and not cbody:find("<<", 1, true) then
							local cerr = comsub_syntax(cbody)
							if cerr then
								error(cerr)
							end
						end
						patstr[#patstr + 1] = src:sub(i, je - 1)
						i = je
					else
						if c == "(" then
							depth = depth + 1
						elseif c == ")" then
							depth = depth - 1
						end
						patstr[#patstr + 1] = c
						i = i + 1
					end
				end
				i = i + 1 -- skip the terminating )
				-- split on top-level | (extglob's internal | is protected by parens)
				local pats, d2, cur = {}, 0, {}
				local full = table.concat(patstr)
				for k = 1, #full do
					local ch = full:sub(k, k)
					if ch == "(" then
						d2 = d2 + 1
						cur[#cur + 1] = ch
					elseif ch == ")" then
						d2 = d2 - 1
						cur[#cur + 1] = ch
					elseif ch == "|" and d2 == 0 then
						pats[#pats + 1] = table.concat(cur)
						cur = {}
					else
						cur[#cur + 1] = ch
					end
				end
				pats[#pats + 1] = table.concat(cur)
				for k = 1, #pats do
					pats[k] = (pats[k]:gsub("^%s+", ""):gsub("%s+$", ""))
				end
				local body, term = {}, "break"
				local svs = cur_stopset
				cur_stopset = { esac = true } -- (a clause body may run straight into `esac`)
				while true do
					local s = skip_sep()
					if s == "dsemi" then
						i = i + 2
						term = "break"
						break
					end
					if s == "dsemi_amp" then
						i = i + 3
						term = "test"
						break
					end -- ;;&
					if s == "semi_amp" then
						i = i + 2
						term = "fall"
						break
					end -- ;&
					if s == "eof" or peekword() == "esac" then
						break
					end
					local before = i
					local st = parse_stmt()
					if not st or i == before then
						-- a stray `)` here means a case clause had no `;;` before the next
						-- pattern (`a) b) …`) — bash rejects that as a syntax error.
						if src:sub(i, i) == ")" then
							error("syntax error near `)'")
						end
						break -- other no-progress (guard against spinning)
					end
					body[#body + 1] = st
				end
				cur_stopset = svs
				clauses[#clauses + 1] = { pats = pats, body = body, term = term }
			end
			return { t = "case", line = ln, subject = subject, clauses = clauses, redirs = tail_redirs() }
		end

		-- leading assignments AND redirects (bash allows them interleaved before the
		-- command: `FOO=1 >f BAR=2 cmd`), forming the prefix for a following command,
		-- else a bare assignment/redirection statement.
		local ln = line
		local assigns = {}
		local redirs = {}
		while true do
			ws()
			local r = parse_redir()
			if r then
				redirs[#redirs + 1] = r
			else
				local a = try_assign()
				if not a then
					break
				end
				a.line = ln
				assigns[#assigns + 1] = a
			end
		end

		-- At command position, `NAME[` with an UNCLOSED `[` is a syntax error in bash
		-- ("unexpected EOF looking for matching `]'") — it began an array-assignment LHS
		-- that never closed (try_assign already consumed real `NAME[..]=` assignments
		-- and closed `NAME[..]` commands are left to fall through to the word/glob path).
		do
			local bs = src:match("^[%a_][%w_]*()%[", i) -- offset of `[` if the word is NAME[
			if bs then
				local depth, j = 0, bs
				while j <= n do
					local ch = src:sub(j, j)
					if ch == "[" then
						depth = depth + 1
					elseif ch == "]" then
						depth = depth - 1
						if depth == 0 then
							break
						end
					elseif depth >= 1 and ch:match("[\n;&|]") then
						break
					end -- terminator before `]`
					j = j + 1
				end
				if depth ~= 0 then
					error("syntax error near `" .. (src:sub(i):match("^%S+") or "[") .. "'")
				end
			end
		end

		-- a keyword that only closes/continues a compound command, reaching command
		-- position on its own (or a bare `}`), is a misplaced-token syntax error.
		do
			local MISPLACED =
				{ ["then"] = 1, ["else"] = 1, ["elif"] = 1, ["fi"] = 1, ["do"] = 1, ["done"] = 1, ["esac"] = 1, ["in"] = 1 }
			local pwm = peekword()
			if MISPLACED[pwm] or (src:sub(i, i) == "}" and (i + 1 > n or src:sub(i + 1, i + 1):match("[ \t\n;)]"))) then
				error("syntax error near `" .. (pwm ~= "" and pwm or "}") .. "'")
			end
		end
		-- simple command: WORD WORD ...
		local words = {}
		local arrayargs = nil -- `NAME=(...)` args to a declaration builtin
		-- cline: the line once the SECOND element is read (bash's yacc lookahead: the line a
		-- simple command runs "at", which its $(…) bodies number from)
		local cline
		while i <= n do
			if not cline and #words + #assigns + #redirs >= 2 then
				cline = line
			end
			local c = src:sub(i, i)
			local r = parse_redir() -- also catches &> before the & break below
			if r then
				redirs[#redirs + 1] = r
			elseif c == "(" and src:sub(i + 1, i + 1) ~= "(" and (#words > 0 or #assigns > 0) then
				-- a bare single `(` after a command word isn't a subshell — `ls foo=(1 2)`,
				-- `builtin typeset a=(…)`, `echo a(b)` are syntax errors in bash. Likewise a
				-- `(` after an assignment prefix with a space: `a= (1 2)` is a syntax error
				-- (the `(` can't be a command word there; `a=(1 2)` with no space is an
				-- array assignment, parsed earlier). (extglob @(…), $(…), <(…) are consumed
				-- inside word(); `((` is left to break so `a (( … ))` reaches arith.)
				error("syntax error near `('")
			elseif c == "\n" or c == ";" or c == "#" or c == "&" or c == "|" or c == "(" or c == ")" then
				break -- ( ) are metacharacters (subshell bounds)
			elseif is_blank(c) then
				ws()
			else
				-- Expand the command word here too (it can follow leading assignments or
				-- redirects: `FOO=1 al`, `>f al`), else trailing-blank-chain an arg word.
				try_alias(#words == 0)
				-- `declare -A a=(...)` etc.: an array literal in argument position.
				local cmd1 = words[1] and words[1].parts and words[1].parts[1]
				local an, ap
				if cmd1 and cmd1.lit and DECL_BUILTINS[cmd1.lit] then
					an, ap = src:match("^([%a_][%w_]*)(%+?)=%(", i)
				end
				if an then
					local a0 = i
					i = i + #an + #ap + 1 -- past NAME (+) = ; now on `(`
					arrayargs = arrayargs or {}
					local elems = parse_array_elems()
					-- (src/pos: the arg as written and where it sat among the words, for `declare -f`)
					arrayargs[#arrayargs + 1] =
						{ name = an, elems = elems, append = (ap == "+"), src = src:sub(a0, i - 1), pos = #words + 1 }
				elseif
					cmd1
					and (cmd1.lit == "let" or cmd1.lit == "eval")
					and src:match("^[%a_][%w_]*%+?=%(", i)
				then
					-- `let x=( 1 )` / `eval a=( "$v" )`: bash reads a `NAME=( … )` arg to these
					-- as ONE word, parens and blanks included (not an array literal here):
					-- let evaluates `x = (1)`, eval re-parses the text. Capture NAME=( … )
					-- whole (balanced, quote-aware) and parse it as a single word.
					local st, depth = i, 0
					i = i + #src:match("^[%a_][%w_]*%+?=", i) -- past NAME(+)=; now on `(`
					if cmd1.lit == "eval" then
						-- eval: read it with the array-literal reader (it knows every quoting and
						-- `${…}` nesting), keeping just the raw text as the word
						parse_array_elems()
						depth = 0
					else
						repeat
							local ch = src:sub(i, i)
							if ch == "(" then
								depth = depth + 1
							elseif ch == ")" then
								depth = depth - 1
							elseif ch == "\\" then
								i = i + 1
							elseif ch == "'" or ch == '"' then
								local close = src:find(ch == "'" and "'" or '[\\"]', i + 1)
								while close and ch == '"' and src:sub(close, close) == "\\" do
									close = src:find('[\\"]', close + 2)
								end
								i = close or n
							end
							i = i + 1
						until depth == 0 or i > n
					end
					local head, nx = src:sub(st, i - 1), src:sub(i, i)
					-- (`let a=(4*3)/2`: the word goes on past the `)`)
					local more = (nx ~= "" and not nx:match("[%s;&|)<>]")) and word(true) or ""
					words[#words + 1] = parse_word(head .. more)
				else
					local w = word(true) -- stop at unquoted ( ) so `cmd)` ends at the subshell close
					if w == "" then
						break
					end
					add_word(words, w)
				end
			end
		end
		if #words == 0 and #redirs == 0 then
			-- no command: the leading assignments are plain (persistent) statements
			if #assigns == 0 then
				return nil
			end
			if #assigns == 1 then
				return assigns[1]
			end
			return { t = "assignlist", line = ln, list = assigns }
		end
		-- a command follows: any leading assignments are its temporary (exported) env.
		-- Arguments of a command that is NOT a declaration builtin are `plainarg`: in posix
		-- mode their `NAME=~` shape doesn't tilde-expand (only real assignment words do).
		local c1 = words[1] and words[1].parts and words[1].parts[1]
		if not (c1 and c1.lit and not c1.q and #words[1].parts == 1 and DECL_BUILTINS[c1.lit]) then
			for k = 2, #words do
				local w = words[k] -- (a copy: parsed words are memoized and shared)
				if w.fresh then
					w.plainarg = true
				else
					words[k] = { k = w.k, parts = w.parts, src = w.src, plainarg = true, plain = w.plain }
				end
			end
		end
		cline = cline or line
		local node = {
			t = "simple",
			line = ln,
			cline = cline ~= ln and cline or nil,
			words = words,
			redirs = (#redirs > 0 and redirs or nil),
			assigns = (#assigns > 0 and assigns or nil),
			arrayargs = arrayargs,
		}
		record_alias_state(node) -- note shopt/alias/unalias so later words expand
		return node
	end

	-- pipeline: cmd [ | cmd ]*   (optional leading `!` negates the exit status)
	-- after `|`, `&&`, `||` a command must follow (bash: `a && && b`, `a | | b`, `a &&` at
	-- the end, are syntax errors — before anything on the line runs)
	operand_check = function()
		if i > n then
			error("syntax error: unexpected end of file")
		end
		local t2 = src:sub(i, i + 1)
		if t2 == "&&" or t2 == "||" or t2 == ";;" or t2 == "|&" then
			error("syntax error near `" .. t2 .. "'")
		end
		local c = src:sub(i, i)
		if c == ";" or c == "|" or c == "&" or c == ")" then
			error("syntax error near `" .. c .. "'")
		end
	end
	local function bang_at(k) -- a `!` word: followed by a blank, a separator, or the end
		return src:sub(k, k) == "!" and (src:sub(k + 1, k + 1) == "" or src:sub(k + 1, k + 1):match("[ \t\n;&|)]"))
	end
	local function time_at(k) -- the `time` reserved word (a standalone word)
		return src:sub(k, k + 3) == "time" and (src:sub(k + 4, k + 4) == "" or src:sub(k + 4, k + 4):match("[ \t\n;&|]"))
	end
	local function parse_pipeline()
		ws()
		local ln = line
		local negate = false
		-- `time [-p]` reserved word may precede the (optionally `!`-negated) pipeline;
		-- it's a keyword only as a standalone word (followed by whitespace/newline).
		local timed, timed_p = false, false
		-- `time [-p]` and `!` may precede a pipeline in any order and repeat (bash's grammar:
		-- `! time cmd`, `time ! cmd`, `time time cmd`); each `!` toggles the inversion
		local sawbang = false
		while true do
			if time_at(i) then
				timed = true
				i = i + 4
				ws()
				while src:sub(i, i + 1) == "-p" and src:sub(i + 2, i + 2):match("[ \t\n]") do
					timed_p = true
					i = i + 2
					ws()
				end
				if timed_p and src:sub(i, i + 1) == "--" and src:sub(i + 2, i + 2):match("[ \t\n]") then
					i = i + 2 -- `time -p -- cmd`: the options end
					ws()
				end
			elseif bang_at(i) then
				negate = not negate
				sawbang = true
				i = i + 1
				ws()
			else
				break
			end
		end
		do
			local c = src:sub(i, i)
			if (sawbang or timed) and (c == "" or c:match("[\n;&|)]")) then
				-- a bare `!` / `time` applies to an EMPTY pipeline (`!` alone is status 1) — bash
				return { t = "pipeline", cmds = { { t = "noop", line = ln } }, negate = negate, line = ln,
					timed = timed or nil, timed_p = timed_p or nil }
			end
		end
		if src:sub(i, i + 1) == "!(" and not (sh and sh.shopt and sh.shopt.extglob or (not sh and extglob_on)) then
			-- without extglob, `!(cmds)` is `!` negating a ( … ) subshell, not a pattern word
			negate = not negate
			i = i + 1
		end
		local first = parse_command()
		local cmds = { first }
		while true do
			ws()
			-- a `\<newline>` line continuation may sit between a stage and the `|` (e.g.
			-- `{ …; } \<nl> | cat`); a simple command absorbs its own trailing one via
			-- word(), but a compound stage does not, so skip it here before the `|` test.
			while src:sub(i, i) == "\\" and src:sub(i + 1, i + 1) == "\n" do
				i = i + 2
				line = line + 1
				ws()
			end
			-- After a COMPOUND command (and its redirections) only an operator, a separator
			-- or a reserved word that continues the enclosing construct may follow: a word
			-- there is a syntax error (bash: `{ :; } echo`, `f() { :; } >x { echo; }`).
			local last = cmds[#cmds]
			if last and COMPOUND_T[last.t] and src:sub(i, i) ~= "#" then
				local w = src:match("^[^%s;&|()<>]+", i)
				-- (a closing keyword only when it closes what's being read — at the top
				-- level `while …; done done` is an error before anything runs)
				if w and (not AFTER_COMPOUND[w] or not (cur_stopset and cur_stopset[w])) then
					error("syntax error near unexpected token `" .. w .. "'")
				end
			end
			-- a single `|` (not `||`) chains another command into the pipeline
			if src:sub(i, i) == "|" and src:sub(i + 1, i + 1) ~= "|" then
				if src:sub(i, i + 1) == "|&" then
					-- `cmd |& next` == `cmd 2>&1 | next`: merge the previous stage's stderr
					-- into its stdout (which the pipe carries to the next stage).
					local prev = cmds[#cmds]
					prev.redirs = prev.redirs or {}
					prev.redirs[#prev.redirs + 1] = { fd = 2, op = "dup", target = "1" }
					i = i + 2
				else
					i = i + 1
				end
				-- bash allows spaces, a comment, and newlines after `|` before the next cmd
				while true do
					ws()
					if src:sub(i, i) == "#" then
						while i <= n and src:sub(i, i) ~= "\n" do
							i = i + 1
						end
					elseif src:sub(i, i) == "\n" then
						-- a heredoc opened by the stage before this `|` has its body on the
						-- following lines (`cat <<EOF |` <newline> body EOF <newline> next) —
						-- consume it here before the next stage, else the body parses as cmds.
						if #heredocs_pending > 0 then
							collect_heredocs()
						else
							line = line + 1
							i = i + 1
						end
					else
						break
					end
				end
				operand_check()
				cmds[#cmds + 1] = parse_command()
			else
				break
			end
		end
		local pipe = (#cmds == 1 and not negate) and first
			or { t = "pipeline", cmds = cmds, negate = negate, line = ln }
		if timed then
			pipe.timed = true
			pipe.timed_p = timed_p
		end -- `time` prefix: measure this pipeline
		return pipe
	end

	-- and-or list: pipeline [ (&& | ||) pipeline ]*  ; a lone `&` (background) is
	-- accepted and run in the foreground for now.
	parse_stmt = function()
		local cstart = i -- job text for `jobs`/`fg` (the command as written, sans `&`)
		local head = parse_pipeline()
		local items, bg = nil, false
		while true do
			ws()
			local two = src:sub(i, i + 1)
			if two == "&&" or two == "||" then
				i = i + 2
				-- `&&`/`||` at end of a line CONTINUE to the next line (bash), so skip any
				-- newlines / blank lines / comments before the right-hand pipeline.
				while true do
					ws()
					local c = src:sub(i, i)
					if c == "\n" then
						line = line + 1
						i = i + 1
					elseif c == "#" then
						while i <= n and src:sub(i, i) ~= "\n" do
							i = i + 1
						end
					else
						break
					end
				end
				items = items or { { op = nil, cmd = head } }
				operand_check()
				items[#items + 1] = { op = two, cmd = parse_pipeline() }
			elseif src:sub(i, i) == "&" and src:sub(i + 1, i + 1) ~= "&" then
				i = i + 1
				bg = true
				break -- background job
			else
				break
			end
		end
		local node = items and { t = "andor", items = items } or head
		if bg then
			local text = src:sub(cstart, i - 2):gsub("^%s+", ""):gsub("%s+$", "")
			return { t = "background", cmd = node, text = text }
		end
		return node
	end

	-- Parse statements until a terminator keyword in `stopset` (consumed and
	-- returned) or EOF. Returns (stmts, terminator-or-nil).
	local parse_stmts_in
	parse_stmts = function(stopset) -- (cur_stopset: what may close the list being read)
		local sv = cur_stopset
		cur_stopset = stopset or {}
		local a, b, c = parse_stmts_in(stopset)
		cur_stopset = sv
		return a, b, c
	end
	parse_stmts_in = function(stopset)
		stopset = stopset or {}
		local stmts = {}
		while true do
			skipblank()
			if i > n then
				return stmts, nil
			end
			if next(stopset) ~= nil and cmd_prex ~= i then
				-- the command word may be an alias for the terminator (`alias DONE='}'`):
				-- expand it before looking for one; parse_command then won't re-expand
				alias_seen = {}
				alias_next = false
				alias_tail = nil
				try_alias(true)
				cmd_prex = i
			end
			if stopset["}"] and src:sub(i, i) == "}" then
				i = i + 1
				return stmts, "}"
			end
			if stopset[")"] and src:sub(i, i) == ")" then
				i = i + 1
				return stmts, ")"
			end
			local pw = peekword()
			if pw and stopset[pw] then
				i = i + #pw
				return stmts, pw
			end
			-- a control operator in command position is an empty command (bash: error)
			local bs = bare_sep_tok()
			if bs then
				error("syntax error near `" .. bs .. "'")
			end
			local before = i
			local st = parse_stmt()
			if i == before then
				-- no progress: a stray metacharacter/keyword in command position (`)`, `}`,
				-- `do`, …) — a syntax error, and a guard against an infinite loop (even when
				-- an empty statement came back: `then ) fi` would spin forever)
				error("syntax error near `" .. src:sub(i, i) .. "'")
			end
			if st then
				stmts[#stmts + 1] = st
			end
			-- consume this statement's single trailing `;` (its terminator), so the next
			-- iteration lands on a genuine command position; `&`/newlines are handled by
			-- parse_stmt/skipblank. A following `;` is then a bare separator (error).
			ws()
			if src:sub(i, i) == ";" and src:sub(i + 1, i + 1) ~= ";" then
				i = i + 1
			end
		end
	end

	-- Return the next TOP-LEVEL statement, or nil at EOF. Error-tolerant (bash is
	-- lazy): if a top-level statement fails to parse — e.g. the appended binary
	-- payload of a self-extracting installer (makeself), which the shell part exits
	-- before ever reaching — yield a deferred `parse_error` node instead of
	-- throwing. Reaching it errors like bash (stderr + exit 2); the lazy
	-- interpreter simply never asks for it if an earlier `exit` fired. (Nested
	-- lists — function bodies, loops — stay strict: a broken body IS a real error.)
	local done = false
	-- Skip within-LINE whitespace: spaces/tabs and `\<newline>` line continuations
	-- (which bash removes at the lexer level, so they EXTEND the logical line), but
	-- NOT a real newline — that ends the line.
	local function skip_inline()
		while true do
			local c = src:sub(i, i)
			if c == " " or c == "\t" then
				i = i + 1
			elseif c == "\\" and src:sub(i + 1, i + 1) == "\n" then
				i = i + 2
				line = line + 1
			else
				break
			end
		end
	end
	-- Yield one LOGICAL LINE at a time: a complete `simple_list` — all the
	-- `;`/`&`/`&&`/`||`-joined and-or lists up to a top-level newline or EOF, as
	-- bash's `inputunit` does. Returns { stmts = {…}, perr = <parse_error>? } or nil.
	-- A `perr` means a syntax error was hit somewhere on the line, so the WHOLE line
	-- runs nothing (bash parses the entire line before executing any of it). The
	-- parser stays statement-lazy (parse_stmt consumes complete multi-line compounds
	-- and each stmt makes progress or errors), so there is no parse-ahead spin.
	local function next_line()
		if done then
			return nil
		end
		alias_line_start()
		skipblank() -- blank lines, comments, and pending heredocs
		if i > n then
			done = true
			return nil
		end
		local bs = bare_sep_tok() -- a leading control op (`;`, `&`, `||`, …) is an error
		if bs then
			done = true
			return { stmts = {}, perr = { t = "parse_error", line = line, msg = "syntax error near `" .. bs .. "'" } }
		end
		local stmts = {}
		while true do
			local start, startline = i, line
			local ok, st = pcall(parse_stmt)
			if not ok then
				-- A RECOVERABLE parse error (an invalid `NAME=( … )` array-literal element)
				-- fails only that assignment: bash reports it but the script continues, so
				-- flag it so the executor runs nothing on the line yet does NOT exit.
				local recover = type(st) == "table" and st.__curse_arraylit
				-- A real (non-recoverable) syntax error stops parsing (bash): mark done so a
				-- repeated caller (the eager M.parse) can't spin re-parsing the same bad
				-- token. A recoverable array-lit error continues (its resync advanced i).
				if not recover then
					done = true
				end
				return {
					stmts = stmts,
					perr = {
						t = "parse_error",
						-- (a recoverable one, or a `near TOKEN` one: the token's line)
						line = (recover or (type(st) == "string" and st:find("near `", 1, true))) and line or startline,
						msg = recover and ("syntax error near `" .. (st.tok or "(") .. "'")
							or (type(st) == "table" and st.__curse_perr and st.msg) or tostring(st),
						text = type(st) == "table" and st.__curse_perr and st.text or nil,
						showtext = type(st) == "table" and st.__curse_perr and st.text and true or nil,
						recoverable = recover or nil,
					},
				}
			end
			-- No progress: a stray metacharacter/keyword in command position (`)`, `}`,
			-- `done`, `fi`, …). Report a syntax error (and guard against spinning).
			if i <= start then
				local tok = peekword() or src:sub(i, i)
				done = true -- stray keyword/metachar in command position: stop (no-progress guard)
				return {
					stmts = stmts,
					perr = { t = "parse_error", line = line, msg = "syntax error near `" .. tok .. "'" },
				}
			end
			if st.t == "funcdef" or st.redirs then
				st.top = true -- (not nested in a compound: its errors report its END line)
			end
			stmts[#stmts + 1] = st
			skip_inline()
			local c = src:sub(i, i)
			if st.t ~= "background" then
				-- foreground: a single `;` continues the line; `\n`/EOF/`#` end it cleanly.
				-- A bare separator here (`;;`, `|`) is a syntax error ON the line — bash runs
				-- nothing on it (`echo 1 ;; echo 2`). Anything else (`(`, `((`, `)`, `}`, a
				-- stray keyword) is left to the existing statement-boundary handling.
				if c == ";" and src:sub(i + 1, i + 1) ~= ";" then
					i = i + 1
					skip_inline()
				elseif i > n or c == "\n" or c == "#" then
					break
				else
					-- a stray `)` ends nothing here: the whole line is a syntax error (bash
					-- runs none of `echo hi )`)
					local bsx = bare_sep_tok() or (c == ")" and ")") or nil
					if bsx then
						done = true
						return {
							stmts = stmts,
							perr = { t = "parse_error", line = line, msg = "syntax error near `" .. bsx .. "'" },
						}
					end
					break
				end
			elseif i > n or c == "\n" or c == "#" then
				break -- background & already separated; line may end
			end
			-- now at a command position for the next statement; a bare sep here is an error
			if i > n then
				break
			end
			c = src:sub(i, i)
			if c == "\n" or c == "#" then
				break
			end -- end of the logical line
			local bs2 = bare_sep_tok() -- `;;`, `&&`, `||`, bare `;`/`&` with no command before them
			if bs2 then
				done = true
				return {
					stmts = stmts,
					perr = { t = "parse_error", line = line, msg = "syntax error near `" .. bs2 .. "'" },
				}
			end
		end
		if #heredocs_pending > 0 then
			collect_heredocs()
		end -- read bodies after the line
		if #warns > 0 then
			for k = #warns, 1, -1 do
				table.insert(stmts, 1, warns[k])
			end
			warns = {}
		end
		-- (pos/pline: where reading stopped — a reader that takes over the rest of the
		-- input line by line, for command history, resumes there)
		return { stmts = stmts, pos = i, pline = line, src = src }
	end
	-- a syntax error also reports the offending input line (bash's second message line)
	return function()
		local lg = next_line()
		if lg and lg.perr and #warns > 0 then -- (warnings read before the error still show)
			lg.perr.warns = warns
			warns = {}
		end
		if lg and lg.perr then
			local m = tostring(lg.perr.msg or "")
			if m:find("unexpected end of file", 1, true) or (m:find("matching `)'", 1, true) and comsub_eof) then
				lg.perr.line = firstline - 1 + select(2, src:gsub("\n", "")) + (src:sub(-1) == "\n" and 1 or 2)
					+ (((src:match("(\\*)$") or ""):len() % 2 == 1) and 1 or 0) -- (a trailing `\` continues)
			end
		end
		-- (the line is shown for an unexpected token even when that token ended the input)
		if lg and lg.perr and lg.perr.text == nil and n > 0 and (i <= n
			or not tostring(lg.perr.msg or ""):find("unexpected end of file", 1, true)) then
			local p = math.min(i, n)
			p = src:sub(p, p) == "\n" and p - 1 or p
			local b = p
			while b > 1 and src:sub(b - 1, b - 1) ~= "\n" do
				b = b - 1
			end
			local e = src:find("\n", p, true) or (n + 1)
			lg.perr.text = src:sub(b, e - 1)
			if src ~= orig_src and lg.perr.line and not line0 then -- (the line before an alias
				local k = lg.perr.line - firstline + 1 -- was spliced into it: bash's `math1)')
				local ln = 0
				for l in (orig_src .. "\n"):gmatch("([^\n]*)\n") do
					ln = ln + 1
					if ln == k then
						lg.perr.text = l
						break
					end
				end
			end
		end
		return lg
	end
end

-- Eager full parse -> { stmts } (used by the compiler, which needs the whole
-- program, and by callers that want the AST). An optional `sh` makes alias
-- expansion consult the live runtime table (for eval/source/$() at runtime); the
-- compiler passes none, so it tracks aliases deterministically from source.
function M.parse(src, sh, aenv, noalias, posix, line0, line1)
	local saved_env, sprex, spdq = ALIAS_ENV, COMSUB_PREX, POSIX_DQ
	local nextf = make_parser(src, sh, aenv, noalias, posix, line0, line1) -- yields logical-line groups { stmts, perr }
	local stmts, lines = {}, {}
	while true do
		local lg = nextf()
		if not lg then
			break
		end
		lines[#lines + 1] = lg
		-- A syntax error on a line means the WHOLE line runs nothing (bash parses the
		-- line before executing any of it), so the parse_error goes BEFORE the line's
		-- own statements: a non-recoverable error then aborts (exit 2) before they run,
		-- and a recoverable one (bad array literal) reports + continues to them — the
		-- same order run_lazy uses, so the compiler and interpreter agree.
		if lg.perr then
			stmts[#stmts + 1] = lg.perr
		end
		for _, st in ipairs(lg.stmts) do
			stmts[#stmts + 1] = st
		end
	end
	ALIAS_ENV, COMSUB_PREX, POSIX_DQ = saved_env, sprex, spdq
	return { stmts = stmts, lines = lines }
end

-- Lazy/incremental parse: returns an iterator yielding one top-level statement
-- per call (nil at EOF). The interpreter uses this for instant start on large
-- scripts and to never tokenize past an `exit` (hybrid installers). `sh` (present
-- when interpreting) makes alias expansion use the live runtime alias table.
-- `line1`: the line the text's first line is (eval: the eval command's own line — bash
-- numbers eval'd code, and functions it defines, from there)
function M.open(src, sh, line1)
	return make_parser(src, sh, nil, nil, nil, nil, line1)
end

return M
