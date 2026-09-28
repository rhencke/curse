-- Minimal bash parser for curse's initial subset: assignments,
-- simple commands (echo …), `for (( init; cond; step ))`, `while (( cond ))`,
-- and arithmetic expressions. Produces an AST consumed by BOTH interp.lua and
-- emit.lua. The full bash grammar is the target; this parser grows toward it.
-- Loops get a stable numeric `id` so the tier layer can name a
-- resume safepoint.
local M = {}
-- A trap's control flow — exit/return/break/continue, or bash's DISCARD — raised by a
-- trap handler that ran at a safepoint inside a protected call must pass through every
-- pcall that classifies failures ("not an arith expression", "syntax error in
-- expression", "doesn't compile"): the one shared test, applied at each such pcall.
-- (Arith/parse/unbound errors carry their own tags: those stay the caller's to classify.)
function M.trap_flow(e)
	if type(e) == "table" and (e.__curse_exit or e.__curse_return or e.__curse_break
		or e.__curse_continue or e.__curse_discard or e.__curse_termsig_unwind)
		and not (e.__curse_matherr or e.__curse_experr or e.__curse_arith or e.__curse_perr
			or e.__curse_unbound or e.__curse_lineabort) then
		error(e, 0)
	end
end
local trap_flow = M.trap_flow
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
-- The live LC_CTYPE is a multibyte charset whose TRAIL bytes can be ASCII (Big5, GBK,
-- Shift-JIS: U+03B1 is Big5 a3 5c). bash's shell_getc marks each byte of a multibyte
-- character (shell_input_line_property) and its lexer's MBTEST only treats a lone byte
-- as `\`, `|`, `{`…, so a trail byte is never a metacharacter. The scanners here are
-- byte-based: in such a locale the text is parsed with those trail bytes swapped for
-- unused high bytes, and the tree gets them back (mb_hide / mb_restore). UTF-8 (every
-- byte of a multibyte char >= 0x80) and single-byte locales never pay for it.
local MBX = false -- (else the LC_CTYPE name: the text's lexing depends on its charset)
local MB_BSL = nil -- (mb_hide's placeholder for a trail byte `\`, handed to the next make_parser)

local dq_end, expansion_end, subscript_close -- forward (defined past scan_cmdsub)
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
	if src:match("^[ \t\n]*$") then -- (cr_whitespace: \f \v \r are not blank to bash)
		return { k = "num", v = "0" }
	end
	-- Arith bodies may embed expansions the arith grammar can't parse: ${x:-5},
	-- $(cmd), $((..)), `cmd`. Defer the whole thing — at eval the raw string is
	-- word-expanded and then re-parsed as pure arithmetic (nodefer). Plain $name and
	-- $digit defer too, but their xpand is fast-pathed (parsed once natively).
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
	-- (not in "let" mode — already-expanded text or a variable's value: `$"3"` stays bad)
	local dtxt -- (the text with those `$` dropped: what bash's errors show)
	-- (only in SOURCE text: expansion output — "strict", "expanded" — keeps a `$` before a quote,
	-- as bash's error shows it: `a[$\"]` evaluates `$"`)
	if nodefer ~= "let" and nodefer ~= "strict" and nodefer ~= "expanded"
		and not (src:find("%${") or src:find("%$%(") or src:find("`")) and src:find("$", 1, true) then
		-- (a `$` INSIDE "…" is just a character: `"$"@` is the text `$@`)
		local out, k, n, indq, qdollar = {}, 1, #src, false, false
		while k <= n do
			local c = src:sub(k, k)
			if c == "\\" then
				out[#out + 1] = src:sub(k, k + 1)
				k = k + 2
			else
				if c == '"' then
					indq = not indq
				end
				qdollar = qdollar or c == "$" and indq
				local ce -- (a $'…' in SOURCE arithmetic: its closing quote, past `\'` escapes)
				if c == "$" and not indq and src:byte(k + 1) == 39 and nodefer ~= "strict" and nodefer ~= "expanded" then
					local j = k + 2
					while j <= n and src:byte(j) ~= 39 do
						j = j + (src:byte(j) == 92 and 2 or 1)
					end
					ce = j <= n and j
				end
				if ce then
					-- bash's parse_matched_pair translates it and single-quotes the result:
					-- `(( $'\f' ))` reads `'<FF>'` (still a bad token, as bash's errors show)
					local t = require("runtime").ansi_unescape(src:sub(k + 2, ce - 1), true)
					out[#out + 1] = "'" .. t:gsub("'", "'\\''") .. "'"
					k = ce + 1
				else
					if not (c == "$" and not indq and src:sub(k + 1, k + 1):match("[\"']")) then
						out[#out + 1] = c
					end
					k = k + 1
				end
			end
		end
		if qdollar and not nodefer then -- (its text is bash's: expanded — the quotes removed,
			return { k = "xpand", raw = src } -- that `$` left as is — then parsed, where it's bad)
		end
		local s2 = table.concat(out)
		dtxt, src = s2 ~= src and s2 or nil, s2
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
			or src:find("%$%d")
		)
	then
		-- `}[%w_#]`: a `${…}` GLUED to following chars (`${base}#a` -> 16#a, `${z}11`,
		-- `${z}xAB`) forms one compound token that must expand-then-parse whole.
		-- `%$[%a_{]` — $name / ${…}: bash substitutes the VALUE as TEXT and re-parses. The
		-- xpand eval fast-paths this (parse once, eval native) and only re-parses textually
		-- when a value isn't a plain number, so hot `(( $i < n ))` stays native. `$digit`
		-- likewise: `set -- 1+2; $(( $1*3 ))` is 1+2*3 (its native tree's param nodes are
		-- what function inlining substitutes, when the call's argument is a plain number).
		return { k = "xpand", raw = src }
	end
	-- bash strips matched double-quote PAIRS inside arithmetic (`$(( "1+2" * 3 ))`
	-- -> 1+2*3), keeping the content; a lone unmatched `"` is left in place so the
	-- tokenizer reports the error bash does. (Single quotes are never stripped.)
	-- (`let`'s arguments were already expanded and quote-removed: bash strips nothing
	-- more — `let 'x="1"+2'` is an error and an assoc_expand_once key keeps its quotes)
	local qtxt = dtxt -- (the quote-stripped text: what bash's errors show, `1 + '2' `)
	local noexp = nodefer == "let" and M.let_noexpand -- (see nameSub)
	-- (nor does any text that is expansion OUTPUT — "strict", "expanded": the quotes a value
	-- holds are just characters, `e='2**"1"'; $(( $e ))` is an operand-expected error)
	if nodefer == "let" then
		nodefer = "strict"
	elseif nodefer == "strict" or nodefer == "expanded" then -- luacheck: ignore 542
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
		qtxt = src
		if src:match("^[ \t\n]*$") then -- (`$(( "" ))`, a quoted blank subscript: 0 too)
			return { k = "num", v = "0" }
		end
	end
	local i, n = 1, #src
	-- bash's lasttp: where the most recently read token starts (bash reads one token
	-- ahead, and each check here looks at the next token after skip()). An error names
	-- the text from there on: `4+` -> operand expected (error token is "+").
	local lasttp
	local etxt = src:gsub("^[ \t]+", "") -- (the expression as bash's errors print it)
	local function skip() -- (expr.c's cr_whitespace: blank, tab, newline — not \r, \f, \v)
		local c = src:byte(i)
		while c == 32 or c == 9 or c == 10 do
			i = i + 1
			c = src:byte(i)
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
	-- `pre`: what bash had already EVALUATED when it met the error — it evaluates while it
	-- parses (expr.c's recursive descent), so side effects before a syntax error stick:
	-- `let 'b=a++ +'` increments a. An AST of the completed operands, in order, under their
	-- short-circuit/ternary conditions; the reporter evaluates it before the message.
	local function aerr(msg, pre)
		error({ __curse_arith = true, msg = msg, tok = lasttp and src:sub(lasttp) or "", pre = pre, expr = qtxt }, 0)
	end
	local ZERO = { k = "num", v = "0" }
	local function seq(a, b)
		if a and b then
			return { k = "comma", l = a, r = b }
		end
		return a or b
	end
	-- What had run when bash's LEXER met a bad character: it reads one token ahead, so the
	-- operations along the right edge — waiting on that token — hadn't happened yet
	-- (`y = 3 @` assigns nothing, `x++, y=2 #c` increments x), but everything to their left,
	-- a completed parenthesis, and the last operand (a `x++` included) had.
	-- (nostr: the bad character is the token right after the last operand — a NAME, whose
	-- value readtok reads only after that lookahead: `A[] ]` never reads A[])
	local function spine(e, nostr)
		local k = e.k
		if e.paren then
			return e
		elseif k == "comma" then
			return seq(e.l, spine(e.r, nostr))
		elseif k == "bin" then
			if e.op == "&&" or e.op == "||" then
				return { k = "bin", op = e.op, l = e.l, r = spine(e.r, nostr) or ZERO }
			end
			return seq(e.l, spine(e.r, nostr))
		elseif k == "asgn" or k == "un" then
			return spine(e.e, nostr)
		elseif k == "tern" then
			return { k = "tern", c = e.c, a = e.a, b = spine(e.b, nostr) or ZERO }
		elseif nostr and k == "var" and not e.dollar then
			return nil
		end
		return e
	end
	-- run a sub-parse; a syntax error in it gets `wrap(its pre)` as its pre (the completed
	-- siblings to its left, in their evaluation context)
	local function withpre(wrap, f, x, y)
		local ok, r = pcall(f, x, y)
		if ok then
			return r
		end
		if type(r) == "table" and r.__curse_arith then
			r.pre = wrap(r.pre)
		end
		error(r, 0)
	end
	local ARITHOP = "[%+%-%*/%%<>=!&|%^~%?:,%(%)]"
	local npow = 0 -- `**` operators parsed so far (an untaken branch with one sets rpow)

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
			-- already-expanded text (bash's EXP_EXPANDED): the subscript runs to its `]` as
			-- skipsubscript reads it (`A[]]` is A[] then a stray `]`; `a[1]+b[2]` two
			-- elements) and nothing in it re-expands
			local close = subscript_close(src, i)
			if close then
				local raw = src:sub(i + 1, close - 1)
				i = close + 1
				local ok, idx = pcall(arith, raw, "expanded")
				if not ok then
					trap_flow(idx)
				end
				return nm, (ok and idx) or nil, raw
			end
		end
		if starts("[") then
			-- the `]` as bash's readtok finds it (expr_skipsubscript -> skipsubscript: quotes,
			-- `\`, nested `[ ]` and $( ) ${ } skipped); none -> "bad array subscript" naming the
			-- text from the name on (`p[++${'k]}]`: the unclosed quote runs past every `]`)
			local rs = i + 1
			local j
			if noexp and noexp(nm) then
				-- let's already-expanded text, assoc_expand_once on and NAME an associative
				-- array: expr_skipsubscript's VA_NOEXPAND — the first `]`, quotes and all
				-- (`let "++a[80's]"` keys `80's`)
				j = src:find("]", rs, true)
			else
				j = subscript_close(src, i)
			end
			if not j then
				error({ __curse_arith = true, msg = "bad array subscript", tok = src:sub(ns) }, 0)
			end
			local raw = src:sub(rs, j - 1)
			i = j + 1 -- past the ]
			local ok, idx = pcall(arith, raw) -- may fail for a quoted/non-arith key
			if not ok then
				trap_flow(idx)
			end
			return nm, (ok and idx) or nil, raw
		end
		return nm, nil, nil
	end

	-- an assignment operator next (after an operand that is no variable): in every place bash
	-- reads an expassign — the top level, inside ( ), a ternary's middle — that is "attempted
	-- assignment to non-variable" (`1 ? ~x *= 1 : 2`, `((b) ^ A /= 2)`)
	local function asgn_next()
		skip()
		return (src:sub(i, i) == "=" and src:sub(i + 1, i + 1) ~= "=") or src:find("^[%+%-%*/%%&|%^]=", i) ~= nil
			or src:find("^<<=", i) ~= nil or src:find("^>>=", i) ~= nil
	end
	local lookahead -- (below)
	-- `asgn`: an assignment may start here — only at the head of a lowest-precedence
	-- expression (bash: assignment binds loosest, so `0 && B=42` is an error)
	local function primary(asgn)
		skip()
		local c = src:sub(i, i)
		if (c == "+" or c == "-" or c == "!") and src:byte(i + 1) == 61 then
			-- `+=`, `-=`, `!=` are single tokens to bash's readtok (an assignment operator, NEQ),
			-- never a sign or `!` before `=`: where an operand belongs, the error names them whole
			aerr("syntax error: operand expected")
		end
		if c == "(" then
			i = i + 1
			local e = parseComma()
			if not eat(")") then
				if asgn_next() then
					aerr("attempted assignment to non-variable", e)
				end
				aerr("missing `)'", lookahead(e))
			end
			e.paren = true -- (complete once its `)` is read: see spine)
			return e
		end
		if (starts("++") or starts("--")) and not src:find("^[%+%-][%+%-][ \t\n]*[%a_]", i) then
			-- not a pre-increment (no name follows): two unary signs (bash: `++5` is 5)
			local sign = src:sub(i, i)
			i = i + 1
			if sign == "+" then
				return primary()
			end
			return { k = "un", op = "-", e = primary() }
		end
		if starts("++") or starts("--") then
			local d = src:sub(i, i) == "+" and 1 or -1
			i = i + 2
			local nm, idx, ir = nameSub()
			-- (readtok: a `++`/`--` right after `++x` is `--x++` — "++: assignment requires lvalue")
			local node = { k = "pre", name = nm, idx = idx, idxraw = ir, d = d }
			if starts("++") or starts("--") then
				aerr(src:sub(i, i + 1) .. ": assignment requires lvalue", node)
			end
			return node
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
				-- (its end as the reader finds it — quotes and nested expansions included; one
				-- the text never closes (`$[${]`) is no leaf: the textual path reports it)
				local ok, j = pcall(expansion_end, src, i - 1, false, true)
				if not ok then
					trap_flow(j)
					aerr("syntax error: operand expected")
				end
				local raw = src:sub(i - 1, j - 1) -- "$" … "}"
				i = j
				return { k = "xpandleaf", raw = raw, whole = src } -- (whole: a bad substitution names it)
			end
			return { k = "var", name = ident(), dollar = true } -- $name: value substituted textually (eval checks)
		end
		if c:match("%d") then
			-- a number token is bash's: a digit then [alnum # @ _]* (base#digits, 0xHEX,
			-- octal, decimal), validated like bash's strlong so its errors match
			local s0, e = src:find("^%d[%w#@_]*", i)
			local v = src:sub(s0, e)
			local function nerr(m) -- (bash's readtok NULs the text after the number: the
				-- expression shown ends there — `1 + 09: value too great for base`)
				error({ __curse_arith = true, msg = m, tok = v, expr = src:sub(1, e) }, 0)
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
		skip()
		local ns0 = i -- (where its token starts: a recursion error names the text from there)
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
		return { k = "var", name = name, idx = idx, idxraw = ir, esrc = src, ep = ns0 }
	end

	-- A syntax error where a NAME is the unexpected token: bash's readtok had read that name
	-- (its one-token lookahead) and — unless an `=` follows it — evaluated it right away
	-- (expr_streval), in the context of the operand before it (a short-circuited one: noeval),
	-- so its own error comes first (`p='*o*'; $(( 1 p ))`: operand expected at `*o*`).
	-- `e`: the pre-error AST; returns it with that read attached at its right edge.
	lookahead = function(e)
		skip()
		if not e or not src:find("^[%a_]", i) then
			return e
		end
		local i0, lt0 = i, lasttp
		local ok, v = pcall(function()
			local ns0 = i
			local name, idx, ir = nameSub()
			skip()
			if src:sub(i, i) == "=" and src:sub(i + 1, i + 1) ~= "=" then
				return nil
			end
			return { k = "var", name = name, idx = idx, idxraw = ir, esrc = src, ep = ns0 }
		end)
		i, lasttp = i0, lt0
		if not ok or not v then
			return e
		end
		local function attach(x)
			local k = x.k
			if x.paren then
			elseif k == "comma" or k == "bin" then
				return { k = k, op = x.op, l = x.l, r = attach(x.r) }
			elseif k == "tern" then
				return { k = "tern", c = x.c, a = x.a, b = attach(x.b) }
			elseif k == "asgn" then
				local c = {}
				for f, fv in pairs(x) do
					c[f] = fv
				end
				c.e = attach(x.e)
				return c
			end
			-- (an operand: its value, then the name read — `x + 0*name` keeps both in order)
			return { k = "bin", op = "+", l = x, r = { k = "bin", op = "*", l = ZERO, r = v } }
		end
		return attach(e)
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
		-- `++`/`--` before a name is a pre-increment token (readtok), never `+ +`/`- -`:
		-- after an operand (`3 --x`) it is a syntax error
		if src:find("^%+%+[ \t\n]*[%a_]", i) or src:find("^%-%-[ \t\n]*[%a_]", i) then
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

	-- A LONG chain of one precedence level (`1+1+…` 20000 operands, a sum of 10000 products)
	-- as a left-deep tree is as deep as it is long: every walk of it — the evaluator, the
	-- compiler, the Lua it emits (200 nesting levels) — overflows. bash evaluates such a
	-- chain in a loop. An associative chain is regrouped BALANCED, the operands still in
	-- their order (evaluation order and value unchanged: + * & | ^ wrap modulo 2^64,
	-- && || short-circuit alike when grouped, and `a - b` is `a + -b`); short ones keep
	-- their shape. `made`: the chain's nodes, innermost first.
	local ASSOC = { ["+"] = true, ["*"] = true, ["&"] = true, ["|"] = true, ["^"] = true,
		["&&"] = true, ["||"] = true }
	local function cls(m)
		if m.etxt or m.paren then
			return nil
		end
		if m.op == "+" or m.op == "-" then
			return "+"
		end
		return ASSOC[m.op] and m.op or nil
	end
	local function rebalance(made)
		local i = 1
		while i <= #made do
			local c = cls(made[i])
			local j = i
			while c and made[j + 1] and cls(made[j + 1]) == c do
				j = j + 1
			end
			if c and j - i + 1 >= 32 then
				local ops, rp = { made[i].l }, {}
				for k = i, j do
					local m = made[k]
					ops[#ops + 1] = m.op == "-" and { k = "un", op = "-", e = m.r } or m.r
					rp[#ops] = m.rpow
				end
				local function build(lo, hi)
					if lo == hi then
						return ops[lo]
					end
					local mid = math.floor((lo + hi) / 2)
					local n = { k = "bin", op = c, l = build(lo, mid), r = build(mid + 1, hi) }
					for q = mid + 1, hi do
						if rp[q] then
							n.rpow = true
							break
						end
					end
					return n
				end
				local root, top = build(1, #ops), made[j]
				for f in pairs(top) do -- (in place: the next node's `l` is this table)
					top[f] = nil
				end
				for f, v in pairs(root) do
					top[f] = v
				end
			end
			i = j + 1
		end
	end
	parseExpr = function(minprec, noasgn)
		local left = primary(minprec == 0 and not noasgn)
		local made = {}
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
			local stp, np = i, npow
			if op == "**" then
				npow = npow + 1
			end
			local right = withpre(function(p) -- (`a && <bad>`: the bad side was noeval)
				if op == "&&" or op == "||" then
					return { k = "bin", op = op, l = left, r = p or ZERO }
				end
				return seq(left, p)
			end, parseExpr, op == "**" and prec or prec + 1) -- ** is right-assoc
			left = { k = "bin", op = op, l = left, r = right }
			made[#made + 1] = left
			if op == "**" then
				-- (for bash's eval-time error text: the expression, and the lookahead token
				-- after the right operand — `2 ** -1 ` -> error token "1 ")
				skip()
				left.etxt, left.etok = etxt, lasttp and src:sub(lasttp) or ""
			elseif op == "/" or op == "%" then
				-- (a division by 0 names the text from the divisor on: expmuldiv's lasttp = stp)
				left.etxt, left.etok = etxt, (src:sub(stp):gsub("^[ \t]+", ""))
			elseif (op == "&&" or op == "||") and npow > np then
				left.rpow = true -- (a skipped right operand still checks its exponents: see eval)
			end
		end
		if #made >= 32 then
			rebalance(made)
		end
		-- ternary c ? a : b (lowest precedence, right-assoc) — only at the top level
		if minprec == 0 and peek() == "?" then
			local np = npow
			i = i + 1
			if peek() == ":" or i > n then
				aerr("expression expected", left)
			end
			local c = left
			local a = withpre(function(p)
				return { k = "tern", c = c, a = p or ZERO, b = ZERO }
			end, parseExpr, 0)
			if not eat(":") then
				if asgn_next() then
					aerr("attempted assignment to non-variable", { k = "tern", c = c, a = a, b = ZERO })
				end
				aerr("`:' expected for conditional expression", { k = "tern", c = c, a = lookahead(a), b = ZERO })
			end
			if peek() == "" then
				aerr("expression expected", { k = "tern", c = c, a = a, b = ZERO })
			end
			local b = withpre(function(p) -- (the else-branch is a conditional, not an assignment)
				return { k = "tern", c = c, a = a, b = p or ZERO }
			end, parseExpr, 0, true)
			left = { k = "tern", c = left, a = a, b = b, rpow = npow > np or nil }
		end
		return left
	end

	-- comma operator: evaluate left-to-right, value is the last (bash/C semantics)
	parseComma = function()
		local e = parseExpr(0)
		local made = {}
		while peek() == "," do
			i = i + 1
			local l = e
			e = { k = "comma", l = l, r = withpre(function(p)
				return seq(l, p)
			end, parseExpr, 0) }
			made[#made + 1] = e
		end
		if #made >= 32 then -- (a long sequence: balanced, as a long chain in parseExpr)
			local items = { made[1].l }
			for _, m in ipairs(made) do
				items[#items + 1] = m.r
			end
			local function build(lo, hi)
				if lo == hi then
					return items[lo]
				end
				local mid = math.floor((lo + hi) / 2)
				return { k = "comma", l = build(lo, mid), r = build(mid + 1, hi) }
			end
			e = build(1, #items)
		end
		return e
	end

	local e = parseComma()
	skip()
	if i <= n then
		local c = src:sub(i, i)
		if (c == "=" and src:sub(i + 1, i + 1) ~= "=") or src:find("^[%+%-%*/%%&|%^]=", i) or src:find("^<<=", i)
			or src:find("^>>=", i) then
			aerr("attempted assignment to non-variable", e)
		elseif not c:match(ARITHOP) and not c:match("[%w_]") then
			-- (after an operand: `1 @ 2`; after a `)` — itself an operator token — readtok says
			-- an operand was expected)
			local pc = src:sub(1, i - 1):match("(%S)%s*$")
			aerr(pc == ")" and "syntax error: operand expected" or "syntax error: invalid arithmetic operator",
				spine(e, pc ~= ")"))
		elseif c:match("[%a_]") then
			-- a name right after the expression: bash's readtok, reading a name, reads the
			-- token after it too (the `=` peek) — past a run of names, a character that
			-- starts no token is ITS error (`x⏎y@`: invalid arithmetic operator at `@`)
			local j = i
			while true do
				local ns, ne = src:find("^[%a_][%w_]*", j)
				if not ns then
					break
				end
				j = ne + 1
				if src:sub(j, j) == "[" then
					local cl = M.subscript_close(src, j)
					if not cl then -- (readtok's expr_skipsubscript found no `]`: that name is
						-- the token in error — `y[t]y[|`)
						error({ __curse_arith = true, msg = "bad array subscript", tok = src:sub(ns) }, 0)
					end
					j = cl + 1
				end
				j = src:match("^[ \t\n]*()", j)
			end
			local c2 = src:sub(j, j)
			if c2 ~= "" and not c2:match(ARITHOP) and not c2:match("[%w_]") then
				i = j
				skip()
				aerr("syntax error: invalid arithmetic operator", spine(e))
			end
		end
		aerr("syntax error in expression", lookahead(e))
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
	local t = shown(tostring(type(err) == "table" and err.expr or expr or ""):gsub("^[ \t]+", ""), subscript)
	local pre = M.arith_cmd and (M.arith_cmd .. ": ") or ""
	if type(err) == "table" and err.msg then
		return pre .. t .. ": " .. err.msg .. ' (error token is "' .. shown(err.tok or "", subscript) .. '")'
	end
	return pre .. t .. ": syntax error in expression"
end

-- ---- statement parser ----

-- Parse the inside of ${ … } into a word part. Plain forms stay {var}/{param}/
-- {special}; anything with an operator becomes {pexp={name, op, arg, arg2}} which
-- Shell:expand_param interprets. `arg`/`arg2` are raw text (the caller expands
-- them before applying the operator, so ${v:-$x} and pattern vars work).
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
-- xg: the extglob state the body is read under, when known. A second result true: the
-- body's parse had to GUESS that state (an extglob-looking `X(` in it), so no error is
-- trusted — the caller's program then runs a line at a time (xg_guess).
local function comsub_syntax(body, xg)
	local key = (xg == nil and body or body .. (xg and "\0x" or "\0-")) .. (MBX and "\0b" .. MBX or "")
	local hit = comsub_err_cache[key]
	if hit ~= nil then
		if hit == "?" then
			return nil, true
		end
		if hit then
			local m, l = hit:match("^(.*)\1(%d+)$")
			if m then
				return m, false, tonumber(l)
			end
		end
		return hit or nil, false
	end
	local err, guessed, eline = false, false, nil
	-- (bash's parse_comsub reads the whole body under the extglob state of the moment: a
	-- `shopt -s extglob` in it takes effect only when it runs — M.xg_fixed stops the static
	-- tracking of it for this parse)
	local sxf = M.xg_fixed
	M.xg_fixed = true
	local ok, ast = pcall(M.parse, body, nil, nil, nil, nil, nil, nil, xg)
	M.xg_fixed = sxf
	if not ok then
		err = type(ast) == "table" and (ast.msg or "syntax error") or tostring(ast)
		guessed = xg == nil and body:find("[@!+*?]%(") ~= nil
	elseif ast and ast.stmts then
		guessed = ast.xg_guess and true or false
		for _, st in ipairs(ast.stmts) do
			if st.t == "parse_error" and not st.recoverable then
				err = tostring(st.msg or "syntax error")
				eline = st.line -- (the body's line holding the error: bash reports it there;
				local nl = select(2, body:gsub("\n", "")) + 1 -- an error at the body's end
				if eline and eline > nl then -- is at its closing `)`, on its last line)
					eline = nl
				end
				break
			end
		end
	end
	if err then
		err = err:gsub("^[%w%._/%-]+:%d+: ", "") -- (a Lua error position isn't part of it)
		if err:find("unexpected end of file", 1, true) or err:find("unexpected EOF", 1, true) then
			err = "syntax error near `)'"
		elseif err == "syntax error near `\n'" then
			err = "syntax error near `newline'"
		elseif err == "syntax error near `newline'" and not body:find("\n", 1, true) then
			err = "syntax error near `)'" -- (`$(<)`: a one-line body's end is the `)` bash reads)
		end
	end
	if comsub_err_n >= 512 then
		comsub_err_cache, comsub_err_n = {}, 0
	end
	comsub_err_cache[key] = guessed and "?" or (err and eline and (err .. "\1" .. eline)) or err
	comsub_err_n = comsub_err_n + 1
	if guessed then
		return nil, true
	end
	return err or nil, false, err and eline
end
local dparen_is_arith, grab_dparen -- forward (defined below)
-- ---- the scanning primitives: where does the construct starting at s[i] end? ----
-- (parse.y reads all of these with parse_matched_pair / parse_comsub; a scanner in this file
-- that skips a quoted string or an expansion asks them rather than hand-writing the loop —
-- except where bash's rule differs: brace_skip's "…" (only a $( … ) nests: braces.c) and
-- dequote_word, which rebuilds the text as it goes.) A `$$` is one token everywhere (bash's
-- LEX_WASDOL: the second `$` opens nothing — `"$$(( }"` is $$ then text). Each
-- returns the index just PAST the construct; one left open runs past the end (>= #s + 2),
-- or — `err` — raises bash's EOF error naming the quote.
-- A quoted string: s[i] is its opening quote, closed by the same byte. `esc`: a `\` escapes
-- the next byte ("…" without nesting, `…`, and a $'…' from its `'`); '…' has no escapes.
-- A syntax error raised with error() carries the Lua position of the raise (this chunk's
-- short_src:line — a checkout path in a dev run): not part of the message, and it would
-- make compiled code (which embeds the message) depend on where curse was built.
local POS = "^" .. debug.getinfo(1, "S").short_src:gsub("%p", "%%%0") .. ":%d+: "
local function unpos(m)
	return (m:gsub(POS, "", 1))
end

-- Every "unexpected EOF while looking for matching `X'" is raised here, noting where the
-- open construct began: bash reports it at THAT line (parse_matched_pair's start_lineno —
-- the quote's, not the command's), which next_line derives from the noted position.
local eof_s, eof_at
local function eof_error(s, at, close)
	eof_s, eof_at = s, at
	error("unexpected EOF while looking for matching `" .. close .. "'")
end
local function quote_end(s, i, esc, err)
	local q, k, n = s:byte(i), i + 1, #s
	while k <= n do
		local b = s:byte(k)
		if b == q then
			return k + 1
		end
		k = k + ((esc and b == 92) and 2 or 1)
	end
	if err then
		eof_error(s, i, string.char(q))
	end
	return k + 1
end
-- Split ${v/pat/repl} into pat, repl. The separator is the first `/` that is
-- NOT at position 1 (bash treats a `/` right after the operator as pattern text,
-- so ${x////c} is pat=`/` repl=`c`), NOT backslash-escaped, and NOT inside
-- single/double quotes. No separator -> the whole thing is the pattern.
local function split_subst(s)
	local i, n = 1, #s
	while i <= n do
		local c = s:sub(i, i)
		if c == "\\" then
			i = i + 2
		elseif c == "'" then -- (a backslash in '…' is literal: `${x/'\'/Z}`; in $'…' it
			i = quote_end(s, i, s:sub(i - 1, i - 1) == "$") -- escapes: `${v/$'\''/x}`)
		elseif c == '"' then
			i = quote_end(s, i, true)
		elseif c == "/" and i > 1 then
			return s:sub(1, i - 1), s:sub(i + 1)
		elseif c == "`" or (c == "$" and (s:byte(i + 1) == 40 or s:byte(i + 1) == 123)) then
			-- (bash's skip_to_delim: a `/` inside a nested ${…} / $(…) / `…` doesn't split —
			-- `${x/${/}}` is the pattern `${/}`; one left open runs to the end)
			local ok, e = pcall(expansion_end, s, i, false, true)
			if not ok then
				trap_flow(e)
			end
			i = ok and e or n + 1
		else
			i = i + 1
		end
	end
	return s, ""
end
local function scan_braces(s, bi, dq, onwarn) -- (onwarn: scan_cmdsub's, for a $(…) in it)
	local i, ns, depth = bi + 1, #s, 1
	local sq_lit = dq and POSIX_DQ
	while i <= ns and depth > 0 do
		local c = s:sub(i, i)
		if c == "\\" or c == "$" and s:byte(i + 1) == 36 then -- (`\x`; `$$`: LEX_WASDOL)
			i = i + 2
		elseif c == "$" and s:sub(i + 1, i + 1) == "'" then -- $'…': a \' inside doesn't close it
			i = quote_end(s, i + 1, true, true)
		elseif c == "'" and not sq_lit then
			i = quote_end(s, i, false, true)
		elseif c == '"' then -- (a "…" nests its own expansions: `${x%"${"}"…` — parse_matched_pair)
			i = dq_end(s, i)
		elseif c == "{" then
			-- only a nested `${` opens a level; a bare `{` is an ordinary char, so
			-- `${X//a/{x,y,z}}` ends at the FIRST `}` (bash: replacement `{x,y,z`, then `}`)
			if s:sub(i - 1, i - 1) == "$" then
				depth = depth + 1
			end
			i = i + 1
		elseif c == "$" and s:sub(i + 1, i + 1) == "(" then
			i = scan_cmdsub(s, i + 2, onwarn) -- a `}` inside $(…) doesn't close (unclosed: its error)
		elseif c == "$" and s:byte(i + 1) == 91 then -- …nor one inside $[…] (unclosed: its error)
			i = expansion_end(s, i, dq)
		elseif c == "`" then -- …nor one inside `…`
			i = quote_end(s, i, true, true)
		elseif c == "}" then
			depth = depth - 1
			i = i + 1
		else
			i = i + 1
		end
	end
	if depth > 0 then
		eof_error(s, bi, "}")
	end
	return i
end

local parse_paramexp
parse_paramexp = function(inner)
	if inner == "" then -- ${}: no parameter (bash: a bad substitution)
		return { pexp = { op = "badsubst", raw = "" } }
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
			local e = quote_end(inner, 2, true)
			if e <= #inner + 1 then
				return parse_paramexp(require("runtime").ansi_unescape(inner:sub(3, e - 2), true) .. inner:sub(e))
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
			(c1 == "?" or c1 == "$" or c1 == "-" or c1 == "!" and c2 ~= "?") and c2 ~= "" and c2:match("[:%-+=?]")
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
		if inner:match("^#[:%-=?+#%%/@]") then -- ${!##} ${!#:-z}: an operator on the last
			return { pexp = { name = "#", op = "indirect", iop = inner:sub(2) } } -- positional
		end
		-- ${!?}: indirect through $? (bash's VALID_INDIR_PARAM), an operator after it applied
		-- to that; any other text after the `?` makes no name (`${!?x]}`: bad substitution)
		-- (posix mode has no `?` there: `${!?word}` is $! under `?` — posixalt, at run time)
		if inner:sub(1, 1) == "?" then
			local alt = { name = "!", op = "?", arg = inner:sub(2) }
			if inner == "?" then
				return { pexp = { name = "?", op = "indirect", posixalt = alt } }
			elseif inner:match("^%?[:%-=?+#%%/@]") then
				return { pexp = { name = "?", op = "indirect", iop = inner:sub(2), posixalt = alt } }
			end
			return { pexp = { op = "badsubst", raw = "!" .. inner, posixalt = alt } }
		end
		if inner:sub(1, 1) == "!" or inner:sub(1, 1) == "#" then
			return { pexp = { op = "badsubst", raw = "!" .. inner } }
		end
		-- ${!a[@} ${!a[0]@} ${!a[0]*}: bash reads the name up to an operator character (a
		-- subscript that closes skipped whole); one that ends at the closing `@}` / `*}` is a
		-- ${!PREFIX@} whose prefix is that text, `[` and all — matching no variable
		local last = inner:sub(-1)
		if (last == "@" or last == "*") and inner:find("[", 1, true) and inner:match("^[%a_]") then
			local x, k, ok = inner:sub(1, -2), 1, true
			while k <= #x do
				local c = x:sub(k, k)
				if c == "[" then
					local cl = subscript_close(inner, k)
					if not cl and last == "*" then
						ok = false
						break
					end
					k = cl and cl <= #x and cl + 1 or k + 1
				elseif ("#%^,~:-=?+/@"):find(c, 1, true) then
					ok = false
					break
				else
					k = k + 1
				end
			end
			if ok then
				return { pexp = { name = x, op = "prefix", star = last == "*" } }
			end
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
		-- no valid parameter starts the text (${%}, ${%x}, ${.x}, ${#!x}, ${$(…)}, ${?x}):
		-- a bad substitution in bash (fails the command, status 1). (After `!`, `${!%x}`
		-- is $! with an operator; that stays the lenient empty read.)
		-- After `!` the text up to an operator character is bash's NAME: just `!` ($!, with
		-- that operator) is the lenient read; anything else there (`${! a}`, `${!.x}`,
		-- `${!"x"}`) starts no indirect name — valid_brace_expansion_word fails it too.
		if indices and (inner == "" or inner:find("^[#%%^,~:%-=?+/@]")) then
			return { var = inner }
		end
		return { pexp = { op = "badsubst", raw = (lenpfx and "#" or indices and "!" or "") .. inner } }
	end
	-- optional [subscript] — on a NAME only: `${*[0]}` `${1[0]}` are bad substitutions
	local index = nil
	if rest:sub(1, 1) == "[" and not name:match("^[%a_]") and not special_op and not sharp_op then
		return { pexp = { op = "badsubst", raw = (lenpfx and "#" or indices and "!" or "") .. inner } }
	end
	if rest:sub(1, 1) == "[" then
		-- (`${a[a[0]]}` takes `a[0]` as the subscript, not `a[0`; `${m[\]]}`)
		local close = subscript_close(rest, 1)
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
			if rest ~= "" and not rest:match("^[:%-=?+#%%/^,~@]") then -- ${!a[@]x}: no operator
				return { pexp = { op = "badsubst", raw = "!" .. inner } }
			end
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
		if rest ~= "" and not rest:match("^[:%-=?+#%%/^,~@]") then -- ${!_Q* } ${!a x}
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
			return { special = name, braced = true }
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
	elseif two == "~~" then -- case toggle (parameter_brace_casemod CASE_TOGGLEALL)
		return P({ op = "~~", arg = rest:sub(3) })
	elseif one == "~" then
		return P({ op = "~", arg = rest:sub(2) })
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
			elseif ch == "$" then -- (a nested ${…}/$(…)'s `:` isn't the separator)
				k = expansion_end(body, k, false, true)
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
	return P({ op = "badsubst", raw = name .. (index and "[" .. index .. "]" or "") .. rest })
end
M.parse_paramexp = parse_paramexp
function M.subscript_close(s, i) -- (bash's skipsubscript, for the runtime's validity checks)
	return subscript_close(s, i)
end

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
						eof_error(src, j, ")")
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
		elseif c == "'" then -- (a quote left open names itself: `$(echo "x` -> matching `"')
			i = quote_end(src, i, false, true)
			wstart = false
			patstart = false
		elseif c == "$" and src:sub(i + 1, i + 1) == "'" then
			i = quote_end(src, i + 1, true, true) -- only $'…' has backslash escapes
			wstart = false
			patstart = false
		elseif c == '"' then
			i = dq_end(src, i, false, onwarn)
			wstart = false
			patstart = false
		elseif c == "`" or c == "$" and src:find("^[({[]", i + 1) then
			i = expansion_end(src, i, false, false, onwarn)
			wstart = false
			patstart = false
		elseif c == "#" and wstart then -- comment to end of line
			i = src:find("\n", i, true) or n + 1
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
				elseif ch == "'" or ch == '"' then -- (one that never closes: its EOF error, at
					-- the quote's line — parse_comsub reads the word with read_token)
					local e = quote_end(src, k, ch == '"', true) - 1 -- (the closing quote; quote removal)
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
	if onwarn then -- (a here-document opened on the text's last line — its delimiter word ran
		for _, hd in ipairs(hdp) do -- to the end: bash warns about it there, then the `)`)
			onwarn(n, n, hd.delim)
		end
	end
	comsub_eof = src:sub(j, j) ~= "(" -- (`$((` unclosed: arithmetic, reported where it began)
	eof_error(src, j, ")") -- unclosed $(
end

-- The ONE end rule for a `((`/`$((` body starting at s[j]: the first `)` at paren depth 0
-- (bash reads it with parse_matched_pair, so parens inside quotes and nested expansions
-- don't count: `$(( ${x:-")"} + 1 ))`). Returns that index, or nil and the depth still open
-- when the text ran out.
local function dparen_close(s, j, strict) -- (strict: a quote or expansion left open raises its error)
	local d, n = 0, #s
	while j <= n do
		local b = s:byte(j)
		if b == 92 then -- \
			j = j + 2
		elseif b == 39 then -- '
			j = quote_end(s, j, false, strict)
		elseif b == 34 then -- "
			j = dq_end(s, j, not strict)
		elseif b == 36 and s:byte(j + 1) == 39 then -- $'…'
			j = quote_end(s, j + 1, true, strict)
		elseif b == 96 or (b == 36 and s:byte(j + 1) == 40) then -- `…` $(…)
			j = expansion_end(s, j, false, not strict)
		elseif b == 36 then -- (a ${ or $[ nests nothing here: parse_matched_pair's P_ARITH
			j = j + 1 -- nests only a $( — `$(( ${x:-)} ))` ends at that `)`, `$(( ${ ))` reads)
		elseif b == 40 then
			d = d + 1
			j = j + 1
		elseif b == 41 then
			if d == 0 then
				return j
			end
			d = d - 1
			j = j + 1
		else
			j = j + 1
		end
	end
	return nil, d
end
-- a `$((` at s[k] that is not arithmetic: the index past its P_ARITH extent (parse_comsub's
-- parse_matched_pair from the second `(`: a `${` nests nothing there) when that ends BEFORE
-- the $( … ) scanner's end (or the scanner fails), else nil — bash's token ends there:
-- `$(( ${x:-)} ))` is the word `$(( ${x:-)} )`, then a `)`
local function pa_short(s, k)
	local c1 = dparen_close(s, k + 3)
	if not c1 or s:byte(c1 + 1) == 41 then
		return nil
	end
	local e = dparen_close(s, c1 + 1)
	if not e then
		return nil
	end
	local ok, je = pcall(scan_cmdsub, s, k + 2)
	if ok and je and je <= e + 1 then
		return nil
	end
	return e + 1
end
-- `$((` is arithmetic ONLY when it's a balanced `$(( expr ))` — the body's close is
-- immediately followed by another `)`. Otherwise the first `(` opened a subshell
-- (`$( (…) )`, #2337).
dparen_is_arith = function(w, j0)
	local c = dparen_close(w, j0)
	return c ~= nil and w:byte(c + 1) == 41
end
-- The body of `$((…))` / `((…))` starting just after the opening `((`, and the index past
-- its closing `))` (past `)` + 1 when a lone `)` closed it: `for ((…)` checks).
grab_dparen = function(src, i)
	local c = dparen_close(src, i)
	if not c then
		dparen_close(src, i, true) -- (a quote left open in it: that one's EOF error)
		comsub_eof = false -- (reported at the line it began on)
		eof_error(src, i - 2, ")")
	end
	return src:sub(i, c - 1), c + 2
end

-- A $( … ) whose body may not parse (a word re-read at run time, a pattern): the scanner's
-- end, else the parens merely counted (j: just past the `$(`)
local function cmdsub_end_lenient(s, j)
	local ok, e = pcall(scan_cmdsub, s, j)
	if ok then
		return e
	end
	local d, n = 1, #s
	while j <= n do
		local b = s:byte(j)
		if b == 40 then
			d = d + 1
		elseif b == 41 then
			d = d - 1
			if d == 0 then
				return j + 1
			end
		end
		j = j + 1
	end
	return n + 2
end
-- bash's scan of a "…" when it EXPANDS the word (string_extract_double_quoted): each ${…}
-- in it is skipped by extract_dollar_brace_string, whose `[` in a parameter name skips a
-- subscript (skipsubscript) — one that never closes runs off the end of the WORD, and
-- expanding it fails with "bad substitution: no closing `}' in WORD" (`"${!a[@}"`,
-- `"${a[x}"`). A port of those scanners (1-based; "past the end" is n + 1): dq_brace_open
-- tells, for the "…" whose text starts at s[i], whether one of its ${…} runs off.
local skip_dq_x, dolbrace_x
local function skip_sq_x(s, i)
	local e = s:find("'", i, true)
	return e and e + 1 or #s + 1
end
local function cs_close_x(s, i) -- the `)` of the $( at s[i-2] (n + 1 when there's none)
	return math.min(cmdsub_end_lenient(s, i) - 1, #s + 1)
end
local function subscript_x(s, i) -- skip_matched_pair(s, i, '[', ']', 0): the `]`, or n + 1
	local n, d, backq = #s, 1, false
	i = i + 1
	while i <= n do
		local c = s:byte(i)
		if c == 92 then
			i = i + 2
		elseif backq then
			backq = c ~= 96
			i = i + 1
		elseif c == 96 then
			backq, i = true, i + 1
		elseif c == 91 then
			d, i = d + 1, i + 1
		elseif c == 93 then
			d = d - 1
			if d == 0 then
				return i
			end
			i = i + 1
		elseif c == 39 then
			i = skip_sq_x(s, i + 1)
		elseif c == 34 then
			i = skip_dq_x(s, i + 1)
		elseif c == 36 and (s:byte(i + 1) == 40 or s:byte(i + 1) == 123) then
			local si = s:byte(i + 1) == 40 and cs_close_x(s, i + 2) or dolbrace_x(s, i + 2)
			if si > n then
				return n + 1
			end
			i = si + 1
		else
			i = i + 1
		end
	end
	return n + 1
end
local PARAM, QUOTE, QUOTE2, OP, WORD = 1, 2, 3, 4, 5
dolbrace_x = function(s, i) -- extract_dollar_brace_string(Q_DOUBLE_QUOTES, 0): the `}`, or n + 1
	local n, st, nest, dbs, start = #s, PARAM, 1, { [0] = PARAM }, i
	while i <= n do
		local c = s:byte(i)
		if c == 92 then
			i = i + 2
		elseif c == 36 and s:byte(i + 1) == 123 then
			dbs[nest], nest, i = st, nest + 1, i + 2
			if st == QUOTE or st == WORD then
				st = PARAM
			end
		elseif c == 125 then
			nest = nest - 1
			if nest == 0 then
				return i
			end
			st, i = dbs[nest] or dbs[0], i + 1
		elseif c == 96 then
			local e = s:find("`", i + 1, true)
			if not e then
				return n + 1
			end
			i = e + 1
		elseif (c == 36 or c == 60 or c == 62) and s:byte(i + 1) == 40 then
			local si = cs_close_x(s, i + 2)
			if si > n then
				return n + 1
			end
			i = si + 1
		elseif c == 34 then
			i = skip_dq_x(s, i + 1)
		elseif c == 39 then
			i = skip_sq_x(s, i + 1)
		else
			if c == 91 and st == PARAM then
				local si = subscript_x(s, i)
				if si > n then
					return n + 1
				end
				if s:byte(si) == 93 then
					c, i = 93, si
				end
			end
			i = i + 1
			local ch = string.char(c)
			if st == PARAM and (ch == "%" or ch == "#" or ch == "^" or ch == ",") and i - start > 1 then
				st = QUOTE
			elseif st == PARAM and ch == "/" and i - start > 1 then
				st = QUOTE2
			elseif st == PARAM and ("#%^,~:-=?+/"):find(ch, 1, true) then
				st = OP
			elseif st == OP and not ("#%^,~:-=?+/"):find(ch, 1, true) then
				st = WORD
			end
		end
	end
	return n + 1
end
skip_dq_x = function(s, i) -- skip_double_quoted: past the closing `"`, or n + 1
	local n, backq = #s, false
	while i <= n do
		local c = s:byte(i)
		if c == 92 then
			i = i + 2
		elseif backq then
			backq = c ~= 96
			i = i + 1
		elseif c == 96 then
			backq, i = true, i + 1
		elseif c == 36 and (s:byte(i + 1) == 40 or s:byte(i + 1) == 123) then
			local si = s:byte(i + 1) == 40 and cs_close_x(s, i + 2) or dolbrace_x(s, i + 2)
			if si > n then
				return n + 1
			end
			i = si + 1
		elseif c ~= 34 then
			i = i + 1
		else
			return i + 1
		end
	end
	return n + 1
end
-- …and the $( … ) / $(( … )) its expansion extracts where the parser saw none: after the
-- `$` of `$$` (`"$$(("`), or inside a ${…} operand's single quotes (in "…" they don't quote:
-- `"${u-'$(('}"`). A $(( … )) is skipped as extract_delimited_string does (parens counted,
-- '…' "…" skipped): one that never closes fails the expansion with "bad substitution: no
-- closing `)' in WORD" (the whole word) — returns "arith"; an open $( … ) is a command
-- substitution whose body doesn't parse — returns "cs" and the position of its `(`.
local function delim_close_x(s, i) -- past `$((` at s[i-3..i-1]: the closing `)`, or n + 1
	local n, d = #s, 2
	while i <= n do
		local c = s:byte(i)
		if c == 92 then
			i = i + 2
		elseif c == 39 then
			i = skip_sq_x(s, i + 1)
		elseif c == 34 then
			i = skip_dq_x(s, i + 1)
		elseif c == 40 then
			d, i = d + 1, i + 1
		elseif c == 41 then
			d = d - 1
			if d == 0 then
				return i
			end
			i = i + 1
		else
			i = i + 1
		end
	end
	return n + 1
end
local function dq_hidden_open(s, i)
	local n, depth, backq = #s, 0, false
	while i <= n do
		local c = s:byte(i)
		if c == 92 then
			i = i + 2
		elseif backq then
			backq = c ~= 96
			i = i + 1
		elseif c == 96 then
			backq, i = true, i + 1
		elseif c == 36 and s:byte(i + 1) == 40 then
			if s:byte(i + 2) == 40 then
				local e = delim_close_x(s, i + 3)
				if e > n then
					return "arith"
				end
				i = e + 1
			else
				local e = cs_close_x(s, i + 2)
				if e > n then
					return depth > 0 and "cs" or nil, i + 1
				end
				i = e + 1
			end
		elseif c == 36 and s:byte(i + 1) == 123 then
			depth, i = depth + 1, i + 2
		elseif c == 125 and depth > 0 then
			depth, i = depth - 1, i + 1
		elseif c == 34 then
			if depth == 0 then
				return nil
			end
			i = skip_dq_x(s, i + 1)
		else
			i = i + 1
		end
	end
	return nil
end
local function dq_brace_open(s, i)
	local n, backq = #s, false
	while i <= n do
		local c = s:byte(i)
		if c == 92 then
			i = i + 2
		elseif backq then
			backq = c ~= 96
			i = i + 1
		elseif c == 96 then
			backq, i = true, i + 1
		elseif c == 36 and s:byte(i + 1) == 40 then
			i = cs_close_x(s, i + 2) + 1
		elseif c == 36 and s:byte(i + 1) == 123 then
			local si = dolbrace_x(s, i + 2)
			if si > n then
				return true
			end
			i = si + 1
		elseif c == 34 then
			return false
		else
			i = i + 1
		end
	end
	return false
end
-- The `]` closing the `[` at s[i], as bash's parse_matched_pair('[', ']') reads it — the
-- $[ … ] legacy arithmetic (P_ARITH), or, `arraysub`, the subscript of a NAME[ … ] word where
-- an assignment may start (read_token_word's P_ARRAYSUB): '…', "…" and `…` nest (a `]` inside
-- one doesn't close it), a $( … ) is a command substitution (P_ARRAYSUB: ${ … }, $[ … ] and
-- <( … ) too), a nested `[` counts, blanks and operators are plain text. Unclosed: bash's
-- "matching `]'" (or the inner construct's) EOF error — lenient: #s + 1 instead.
local function bracket_close(s, i, lenient, arraysub)
	local d, n, k = 1, #s, i + 1
	while k <= n do
		local b, nb = s:byte(k), s:byte(k + 1)
		if b == 92 or b == 36 and nb == 36 then -- \x, $$
			k = k + 2
		elseif b == 39 then -- '…' ($'…': `\` escapes)
			k = quote_end(s, k, s:byte(k - 1) == 36, not lenient)
		elseif b == 34 then
			k = dq_end(s, k, lenient)
		elseif b == 96 then
			k = quote_end(s, k, true, not lenient)
		elseif b == 36 and (nb == 40 or arraysub and (nb == 123 or nb == 91)) then
			k = expansion_end(s, k, false, lenient)
		elseif arraysub and (b == 60 or b == 62) and nb == 40 then
			k = scan_cmdsub(s, k + 2)
		elseif b == 91 then
			d = d + 1
			k = k + 1
		elseif b == 93 then
			d = d - 1
			if d == 0 then
				return k
			end
			k = k + 1
		else
			k = k + 1
		end
	end
	if not lenient then
		eof_error(s, i, "]")
	end
	return n + 1
end
-- An expansion: s[i] is a `$` or a backquote — $(( )), $( ), ${ }, $[ ], `…`; any other `$`
-- is just itself (i + 1). dq: inside "…" (scan_braces' posix `'` rule); lenient: an
-- unparsable $( … ) is paren-counted and an open `…` runs to the end (else their errors);
-- onwarn: scan_cmdsub's.
expansion_end = function(s, i, dq, lenient, onwarn)
	local b = s:byte(i + 1)
	if b == 36 and s:byte(i) == 36 then -- `$$`: one token (the pid), never the `$` of a `$(`
		return i + 2
	elseif s:byte(i) == 96 then
		return quote_end(s, i, true, not lenient)
	elseif b == 40 then
		if s:byte(i + 2) == 40 and dparen_is_arith(s, i + 3) then
			local _, e = grab_dparen(s, i + 3)
			return e
		end
		if lenient then
			return cmdsub_end_lenient(s, i + 2)
		end
		return scan_cmdsub(s, i + 2, onwarn)
	elseif b == 123 then
		return scan_braces(s, i + 1, dq)
	elseif b == 91 then
		return bracket_close(s, i + 1, lenient) + 1
	end
	return i + 1
end
-- A "…": s[i] is its opening quote. `\` escapes; a nested expansion keeps its own quoting
-- (`"$(echo ")")"`), so its `"` doesn't close this one. (lenient: as expansion_end's, and
-- an open "…" isn't an error either)
dq_end = function(s, i, lenient, onwarn)
	local n, q = #s, i
	i = i + 1
	while i <= n do
		local b = s:byte(i)
		if b == 34 then
			return i + 1
		elseif b == 92 then
			i = i + 2
		elseif b == 36 or b == 96 then
			i = expansion_end(s, i, true, lenient, onwarn)
		else
			i = i + 1
		end
	end
	if not lenient then
		eof_error(s, q, '"')
	end
	return i + 1
end
-- The `]` closing the subscript `[` at s[i], or nil: brackets nest (`a[a[0]]`), and a `]`
-- that is escaped, quoted or inside a $(…)/${…}/`…` doesn't close it (`A[']']`, `${m["a]a"]}`,
-- `a[$(echo ])]`) — bash's skipsubscript. Never raises: the text may be a runtime value.
subscript_close = function(s, i)
	local d, n = 0, #s
	while i <= n do
		local b = s:byte(i)
		if b == 92 then -- \
			i = i + 2
		elseif b == 39 then -- '
			i = quote_end(s, i, false)
		elseif b == 96 then -- ` (skip_matched_pair's backq)
			i = quote_end(s, i, true)
		elseif b == 34 then -- "
			i = dq_end(s, i, true)
		elseif b == 36 and (s:byte(i + 1) == 40 or s:byte(i + 1) == 123) then -- $( ${
			local ok, e = pcall(expansion_end, s, i, false, true)
			if not ok then -- (one the text never closes runs to its end: skip_matched_pair's
				trap_flow(e)
				return nil -- extract_dollar_brace_string / extract_delimited_string — `q[${x]`)
			end
			i = e
		else
			if b == 91 then
				d = d + 1
			elseif b == 93 then
				d = d - 1
				if d == 0 then
					return i
				end
			end
			i = i + 1
		end
	end
	return nil
end

-- Parse a $… expansion at position i of string w; add(part) tagging it with the
-- quoted flag q; returns the next index. (q drives word-splitting downstream.)
-- ${x:-$'…'} inside "…": bash 5.2 DOES expand ANSI-C quoting in a quoted default word
-- (parse_default_quoted sets this while parsing it); elsewhere in "…" `$'` is literal.
local DQ_ANSI = false
-- A $(…) body as bash runs it: parse_comsub re-prints the parsed body (print_comsub — `a; b`,
-- `a | b` joined, compound commands laid out, blank lines gone, top-level newlines kept) and
-- command_substitute parses and runs THAT text, so its commands' line numbers ($LINENO, an
-- error's `line N:`) count the printed lines. Not a here-document body's (expanded as it
-- is read), nor one the printer can't take (a syntax error, …: the text as written).
local IN_HEREDOC = false
local COMSUB_PRINTED, comsub_printed_n = {}, 0
local function comsub_text(body)
	if IN_HEREDOC then
		return body
	end
	local t = COMSUB_PRINTED[body]
	if t == nil then
		t = require("deparse").comsub(body) or false
		if comsub_printed_n >= 4096 then
			COMSUB_PRINTED, comsub_printed_n = {}, 0
		end
		COMSUB_PRINTED[body], comsub_printed_n = t, comsub_printed_n + 1
	end
	return t or body
end
local function parse_dollar(w, i, add, q)
	local nx = w:sub(i + 1, i + 1)
	if w:sub(i + 1, i + 2) == "((" and dparen_is_arith(w, i + 3) then
		local body, ni = grab_dparen(w, i + 3)
		add({ arith = body, q = q })
		return ni
	elseif nx == "[" then -- $[expr]: deprecated arithmetic, an alias of $(( ))
		local j = bracket_close(w, i + 1, true)
		if j > #w then -- (one the text never closes — a here-document body read as it expands:
			-- extract_arithmetic_subst runs off it, "bad substitution: no closing `]' in TEXT")
			add({ nulcut = w, nocl = "]", q = true })
			return #w + 1
		end
		add({ arith = w:sub(i + 2, j - 1), q = q, bracket = true })
		return j + 1
	elseif nx == "(" then
		-- index just past the closing `)` (case/quote/nesting aware) — or a `$((`'s P_ARITH end
		local pa = w:byte(i + 2) == 40 and pa_short(w, i)
		local je = pa or scan_cmdsub(w, i + 2)
		add({ cmdsub = pa and w:sub(i + 2, je - 2) or comsub_text(w:sub(i + 2, je - 2)), q = q, aenv = ALIAS_ENV,
			noalias = COMSUB_PREX or nil, posix = POSIX_DQ or nil, backtick = pa and "late" or nil })
		return je
	elseif nx == '"' and q then
		-- inside "…" (or a here-doc body) the `"` after `$` is no $"…" opener: a literal `$`
		add({ lit = "$", q = true })
		return i + 1
	elseif nx == '"' then
		-- $"…" locale translation: with no catalog it's just the double-quoted string.
		return i + 1 -- skip the `$`; the caller parses the following "…" normally
	elseif nx == "'" and q and not DQ_ANSI then
		-- inside "…" (or a heredoc body) `$'` is just a literal `$` followed by text
		add({ lit = "$", q = true })
		return i + 1
	elseif nx == "'" then
		-- $'…' ANSI-C quoting: a literal string with backslash escapes, no expansion.
		local j = quote_end(w, i + 1, true)
		local raw = w:sub(i + 2, j - 2)
		-- (a \u/\U code point is encoded in the locale current when the line is parsed —
		-- `ansic` keeps the source so the compiled tier encodes it when the line runs)
		add({ lit = require("runtime").ansi_unescape(raw, true), q = true,
			ansic = raw:find("\\[uU]%x") and raw or nil })
		return j
	elseif nx == "{" then
		-- find the MATCHING } — honoring \-escapes, '…'/"…" quoting, and nested ${…}
		-- so `${var#\}}`, `${var-'}'}`, `${a:-${b}}` take the right inner text.
		local endp = scan_braces(w, i + 1, q) -- index just past the closing }
		-- (unquoted, the word's expansion re-extracts it — extract_dollar_brace_string, whose
		-- subscript in the NAME skips to its `]` past a `}`: `${a[@}]}` is a[@}], and
		-- `[${!a[@}]` runs to the word's end, the `]` in the subscript)
		local sb = not q and w:match("^!?[%a_][%w_]*()%[", i + 2)
		local ce = endp - 2 -- (the text's end)
		if sb then
			local ex = dolbrace_x(w, i + 2)
			if ex <= #w and ex ~= endp - 1 then
				endp, ce = ex + 1, ex - 1
			elseif ex > #w and subscript_x(w, sb) <= #w then
				endp, ce = #w + 1, #w
			end
		end
		local part = parse_paramexp(w:sub(i + 2, ce))
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
-- A `…` command substitution's body, from its opening backquote at s[i], and the index just
-- past it: a `\` before a char of the class `unesc` is removed, a \<newline> is dropped
-- (even inside its '…' — POSIX), any other `\` stays.
local function bq_body(s, i, unesc)
	local j, buf, n = i + 1, {}, #s
	while j <= n and s:byte(j) ~= 96 do
		local nx = s:sub(j + 1, j + 1)
		if s:byte(j) == 92 and nx == "\n" then
			j = j + 2
		elseif s:byte(j) == 92 and nx:match(unesc) then
			buf[#buf + 1] = nx
			j = j + 2
		else
			buf[#buf + 1] = s:sub(j, j)
			j = j + 1
		end
	end
	return table.concat(buf), j + 1
end
-- A "…" ${NAME-WORD} (also :- = := ? :? + :+) whose WORD holds a $'…' decoding to a NUL:
-- bash translates that $'…' as it reads the word (parse_matched_pair's ansiexpand), and its
-- C string ends at the NUL — so the word's text is cut there, and expanding it is `bad
-- substitution: no closing `}' in "${u-r` (status 1, the line abandoned). Sets M.nulcut
-- to the cut text of the "…" contents (from inner[1]) and returns true.
function M.dq_nulcut(inner, i)
	if not inner:find("$'", i, true) then
		return false
	end
	local ok, e = pcall(scan_braces, inner, i + 1, true)
	if not ok then
		return false
	end
	local body = inner:sub(i + 2, e - 2)
	local _, oe = body:find("^[#!]?[%w_@*?$!#-]+%b[]")
	oe = oe or select(2, body:find("^[#!]?[%w_@*?$!#-][%w_]*"))
	if not oe or not body:find("^:?[-=?+]", oe + 1) then
		return false
	end
	local k = i + 2 + oe
	while k < e - 1 do
		local c = inner:sub(k, k)
		if c == "\\" then
			k = k + 2
		elseif c == "$" and inner:sub(k + 1, k + 1) == "'" then
			local qe = quote_end(inner, k + 1, true)
			local d = require("runtime").ansi_unescape(inner:sub(k + 2, qe - 2), "z")
			local z = d:find("\0", 1, true)
			if z then
				M.nulcut = inner:sub(1, k - 1) .. d:sub(1, z - 1)
				return true
			end
			k = qe
		else
			k = k + 1
		end
	end
	return false
end
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
			if not (heredoc or POSIX_DQ) and inner:byte(i + 1) == 123 and M.dq_nulcut(inner, i) then
				return -- (the word's text ends at a NUL: parse_word makes it an error part)
			end
			-- `$$(` read as the word expands: `$$` is the pid, but string_extract_double_quoted
			-- first extracts a $( … ) from the second `$` — one that never closes (the `"`
			-- ending the word is read into it) fails the command as a substitution's syntax error
			if not heredoc and inner:sub(i + 1, i + 2) == "$(" and not pcall(scan_cmdsub, inner .. '"', i + 3) then
				add({ cserr = M.open_comsub_err(inner:sub(i + 3) .. '"'), q = true })
				return
			end
			-- a $( a here-document body never closes: expanding the body runs what precedes
			-- it, then fails there (parse_comsub's EOF error, reported at the line the body
			-- ends on — csnl: the newlines from the `$(` — then DISCARD)
			if heredoc == true and inner:byte(i + 1) == 40 and not (inner:byte(i + 2) == 40 and dparen_is_arith(inner, i + 3))
				and not pcall(scan_cmdsub, inner, i + 2) then
				add({ cserr = M.open_comsub_err(inner:sub(i + 2)), csnl = select(2, inner:sub(i):gsub("\n", "")), q = true })
				return
			end
			-- (a heredoc body's ${x-word} keeps a $'…' in word literal — bash; so does a
			-- "…" one in posix mode)
			local lastp
			i = parse_dollar(inner, i, (heredoc or POSIX_DQ) and function(p)
				if p.pexp then
					p.pexp.hd = heredoc and "hdoc" or true -- (parse_default_quoted tells them apart)
					p.pexp.hdoc = heredoc or nil
				elseif heredoc and p.special == "*" then
					p.hdoc = true -- (a here-document's $* joins with a space: bash)
				end
				lastp = p
				add(p)
			end or add, true)
			-- a here-document's $( … ) is parsed as the body expands (xparse_dolparen over the
			-- rest of the body): its syntax error shows the rest of that line — hdtail
			if heredoc == true and lastp and lastp.cmdsub and not lastp.backtick then
				lastp.hdtail = inner:match("^[^\n]*", i)
			end
		elseif c == "`" then -- `cmd` command substitution inside "…"
			-- within a backtick INSIDE double quotes, `\` also escapes `"` (unlike the
			-- `$()` form) — bash unwraps `\"`→`"`, so `"`echo \"hi\"`"` runs `echo "hi"`
			-- (not in a heredoc body or a prompt: `\"` reaches the command as is).
			local body, i0 = nil, i
			body, i = bq_body(inner, i, bt_keep and "[`$\\]" or '[`$\\"]')
			if heredoc == true and i > #inner + 1 then -- (a here-document body's `…` that never
				-- closes: expanding the body fails — string_extract's "no closing "`" in `…")
				add({ bterr = inner:sub(i0), q = true })
				return
			end
			add({ cmdsub = body, q = true, backtick = true, aenv = ALIAS_ENV })
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
			local e = quote_end(w, i)
			o[#o + 1] = w:sub(i, e - 1)
			i = e
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

-- A bare array-literal element's word: a copy (parse_word memoizes — the cached word is
-- shared) marked `noassign` (its `x=~` is not an assignment: no ~ after =) and `aelem`
-- (bash expands it with other word flags: a lone "$@" there splits as "${@}" does).
local function elem_word(w)
	local c = {}
	for k, v in pairs(w) do
		c[k] = v
	end
	c.noassign, c.aelem = true, true
	return c
end
-- The valid UTF-8 sequence starting at w[i] (a lead byte 0xC2-0xF4), as mbrtowc takes
-- it (no overlong, surrogate or >U+10FFFF form), or nil.
local function utf8_seq(w, i)
	local b = w:byte(i)
	local l = b >= 0xF0 and 4 or b >= 0xE0 and 3 or 2
	local lo, hi = 0x80, 0xBF
	if b == 0xE0 then
		lo = 0xA0
	elseif b == 0xED then
		hi = 0x9F
	elseif b == 0xF0 then
		lo = 0x90
	elseif b == 0xF4 then
		hi = 0x8F
	end
	local c = w:byte(i + 1)
	if not c or c < lo or c > hi then
		return nil
	end
	for k = i + 2, i + l - 1 do
		c = w:byte(k)
		if not c or c < 0x80 or c > 0xBF then
			return nil
		end
	end
	return w:sub(i, i + l - 1)
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
			local e = quote_end(w, i) - 1
			parts[#parts + 1] = { lit = w:sub(i + 1, e - 1), q = true }
			i = e + 1
		elseif c == '"' and w:find("${", i, true) and w:find("[", i, true) and dq_brace_open(w, i + 1) then
			parts[#parts + 1] = { nulcut = w, q = true } -- (expanding the word fails here: dq_brace_open)
			break
		elseif c == '"' and w:find("$(", i, true) and dq_hidden_open(w, i + 1) then
			local kind, at = dq_hidden_open(w, i + 1)
			parts[#parts + 1] = kind == "arith" and { nulcut = w, nocl = ")", q = true }
				or { cserr = M.open_comsub_err(w:sub(at + 1)), q = true }
			break
		elseif c == '"' then -- double quotes: expand inside (an unterminated $( … ) body in it
			local j = dq_end(w, i, true) - 1 -- is paren-counted); j: the closing quote
			local before = #parts
			parse_dquote(w:sub(i + 1, j - 1), add)
			if M.nulcut then -- (the text ends at a $'…' NUL: expanding it is an error)
				local cut = w:sub(1, i) .. M.nulcut
				M.nulcut = nil
				return { k = "word", parts = { { nulcut = cut } }, src = src }
			end
			if #parts == before then
				parts[#parts + 1] = { lit = "", q = true }
			elseif #parts > before + 1 then
				-- a "…" holding "$@"/"${a[@]}" besides other parts: when the @ expands to no
				-- words and the rest to empty, the whole segment is no word (subst.c: the
				-- inner expand_word_internal returns NULL for "$e$@"), unlike "$e""$@". Tag the
				-- segment's parts (dqat = its first part's index; dqend on its last).
				for k = before + 1, #parts do
					local pk = parts[k]
					local pe = pk.pexp
					if pk.special == "@" or (pe and (pe.name == "@" or pe.index == "@")) then
						for k2 = before + 1, #parts do
							parts[k2].dqat = before + 1
						end
						parts[#parts].dqend = true
						break
					end
				end
			end -- empty "" is still a field
			for k = before + 1, #parts do -- (a bad ${…} in "…" reports the quoted text)
				local pe = parts[k].pexp
				if pe and pe.op == "badsubst" then
					pe.wraw = (w:sub(i + 1, j - 1):gsub('\\"', '"'))
				end
			end
			i = j + 1
		elseif c == "$" then
			i = parse_dollar(w, i, add, false)
		elseif c == "`" then -- `cmd` command substitution
			local body
			body, i = bq_body(w, i, "[`$\\]")
			parts[#parts + 1] = { cmdsub = body, q = false, backtick = true, aenv = ALIAS_ENV }
		elseif (c == "<" or c == ">") and w:sub(i + 1, i + 1) == "(" then
			-- <(cmd) / >(cmd) process substitution: capture the inner command — its body has
			-- its own quoting/case syntax, so use the $(…) scanner (plain counting if unclosed)
			local j = cmdsub_end_lenient(w, i + 2) - 1 -- (the closing `)`)
			parts[#parts + 1] = { procsub = comsub_text(w:sub(i + 2, j - 1)), dir = c, q = false }
			i = j + 1
		elseif c == "\\" then -- backslash escape: literal next char (newline = continuation)
			local nx = w:sub(i + 1, i + 1)
			if nx == "\n" then -- line continuation: drop
			elseif nx == "" then -- a backslash ending the input is itself literal (bash: `a\`)
				parts[#parts + 1] = { lit = "\\", q = true }
			else
				-- (a valid UTF-8 sequence is escaped WHOLE — bash's SCOPY_CHAR_I: one CTLESC
				-- before the char, so a word split still sees its later bytes)
				local b = nx:byte()
				if b >= 0xC2 and b <= 0xF4 then
					nx = utf8_seq(w, i + 1) or nx
				end
				parts[#parts + 1] = { lit = nx, q = true }
			end
			i = i + 1 + math.max(#nx, 1)
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
	for k = 1, #parts do -- a bad ${…} reports the whole word it is in (bash's `string`)
		local pe = parts[k].pexp
		if pe and pe.op == "badsubst" and not pe.wraw then
			pe.wraw = w
		end
	end
	return { k = "word", parts = parts, src = src }
end
M.parse_word = parse_word
M.unpos = unpos
M.scan_cmdsub = scan_cmdsub
M.strip_contin = strip_contin
M.quote_end = quote_end
M.expansion_end = expansion_end
-- bash's fork optimization (execute_in_subshell / optimize_connection_fork /
-- parse_and_execute's should_suppress_fork): the last command of a ( … ) or $( … ) body —
-- a plain simple command, the last of a `;`/&&/|| list — is exec'd in place of the
-- subshell. Marked for the runtime ($SHLVL: rt.exec_tail_lvl): 2 = always (alone in a
-- `( … )`, redirections and all), 1 = unless a trap must still run (no redirections).
function M.mark_tail(body, paren)
	local n = body and #body or 0
	local last = body and body[n]
	local alone = n == 1
	if last and last.t == "andor" then
		last, alone = last.items[#last.items].cmd, false
	end
	if last and last.t == "simple" and not last.timed and ((alone and paren) or not last.redirs)
		and not (n > 1 and body[n - 1].t == "background") then
		last.shtail = (alone and paren) and 2 or 1
		last.cstail = not paren or nil -- (a $( … ) body's: a function it calls passes it on)
	elseif last and alone and paren and last.t == "subshell" and not last.ttimed then
		last.inplace = true -- (a `( … )` alone in one: run in its process — rt.subshell_run)
	elseif last and alone and paren and last.t == "pipeline" and last.negate and #last.cmds == 1 then
		last.cmds[1].bang = nil
	end
end
-- A `time ( … )` (`time ! ( … )`): execute_in_subshell passes CMD_TIME_PIPELINE on to the
-- body, so the subshell times it itself, INSIDE its redirections (`time ( … ) 2>f` writes
-- the report to f) — and no command of it is exec'd in place: the body becomes one timed
-- group (.tw; `ttimed` keeps the `time` for deparse). A `! ( … )`: the `!` shows in its job
-- text (.bang) — unless it's alone in a `( … )`, whose execute_in_subshell strips the flag
-- (mark_tail).
function M.untail(pipe, sub, timed, timed_p)
	if not timed then
		sub.bang = true
		return
	end
	local body = sub.body
	local last = body[#body]
	if last and last.t == "andor" then
		last = last.items[#last.items].cmd
	end
	if last then
		last.shtail, last.cstail, last.inplace = nil, nil, nil
	end
	sub.body = { { t = "group", line = body[1] and body[1].line or sub.line, body = body, tw = true,
		timed = true, timed_p = timed_p or nil } }
	pipe.timed, pipe.timed_p, pipe.ttimed = nil, nil, timed_p and "p" or true
	if pipe ~= sub then
		sub.bang = true
	end
end
-- …and a function called as a $( … ) body's tail passes that on to its own body's last
-- command, the same shape (bash 5.2 optimizes the function's tail inside the comsub too):
-- marked with the function's name (rt: sh.fntail_arm names the function so called).
function M.mark_fntail(body, name)
	local n = body and #body or 0
	local last = body and body[n]
	if last and last.t == "andor" then
		last = last.items[#last.items].cmd
	end
	if last and last.t == "simple" and not last.timed and not last.redirs
		and not (n > 1 and body[n - 1].t == "background") then
		last.fntail = name
	end
end
M.scan_braces = scan_braces
M.grab_dparen = grab_dparen
M.fn_bstart = 0 -- (parse.y's function_bstart, a static: see func_body; Shell.new resets it)

-- Memoize the runtime-facing parsers. The interpreter re-parses the SAME arith
-- expressions and words on every loop iteration — $(( … )), array subscripts,
-- ${x:-word}, ${x#pat}, redirect targets — via P.arith / P.parse_word. Both are
-- pure functions of their source string (the returned AST is used read-only by
-- the evaluator/expander), so cache them. Measured: an assoc-array/arith loop was
-- ~5x slower than bash because it re-lexed the subscript + arith text every pass.
-- Bounded so a script with unboundedly many distinct expressions can't leak.
local MEMO_CAP = 8192
local mb_hide, mb_restore
do
	-- the ASCII bytes a Big5/GBK/SJIS trail byte (0x40-0x7e) can be that a scanner reads
	-- as syntax (letters, digits and `_` just continue a word either way)
	local MB_SPECIAL = { [64] = true, [91] = true, [92] = true, [93] = true, [94] = true, [96] = true,
		[123] = true, [124] = true, [125] = true, [126] = true }
	-- -> the text with each such trail byte replaced by a high byte `src` doesn't use,
	-- the placeholder -> original map and its pattern class; nil when there's nothing to hide
	function mb_hide(src)
		if not src:find("[\128-\255]") then
			return nil
		end
		local charlen = package.loaded.runtime.mb_charlen
		local used, rev, map, cls = {}, {}, nil, nil
		for c in src:gmatch("[\128-\255]") do
			used[c:byte()] = true
		end
		local out, last, i, n = {}, 1, 1, #src
		while i <= n do
			if src:byte(i) >= 0x80 then
				local len = charlen(src, i)
				for k = i + 1, i + len - 1 do
					local t = src:byte(k)
					if MB_SPECIAL[t] then
						local ph = rev[t]
						if not ph then
							for c = 0x80, 0xff do
								if not used[c] then
									ph = c
									break
								end
							end
							if not ph then
								return nil -- (every high byte in use: parse it byte-wise)
							end
							used[ph], rev[t] = true, ph
							map = map or {}
							map[string.char(ph)] = string.char(t)
							cls = (cls or "") .. string.char(ph)
						end
						out[#out + 1] = src:sub(last, k - 1)
						out[#out + 1] = string.char(ph)
						last = k + 1
					end
				end
				i = i + len
			else
				i = i + 1
			end
		end
		if not map then
			return nil
		end
		out[#out + 1] = src:sub(last)
		return table.concat(out), map, "[" .. cls .. "]"
	end
	-- put the hidden trail bytes back in every string of a parsed tree (same lengths, so
	-- recorded positions stay valid)
	function mb_restore(v, map, cls, seen)
		seen[v] = true
		for k, x in pairs(v) do
			local tx = type(x)
			if tx == "string" then
				if x:find(cls) then
					v[k] = (x:gsub(cls, map))
				end
			elseif tx == "table" and not seen[x] then
				mb_restore(x, map, cls, seen)
			end
		end
		return v
	end
end
function M.mb_locale(on) -- (runtime: the locale changed)
	MBX = on or false
end
function M.mb_on() -- (tier: the lexing state is part of every compile-cache key): false, or
	return MBX -- the LC_CTYPE name
end
do
	local acache, an = {}, 0
	local aimpl = arith
	arith = function(src, nodefer)
		-- (not memoized: a let under assoc_expand_once, whose subscripts' extent depends on
		-- which names are associative arrays — M.let_noexpand)
		if type(src) == "string" and not (nodefer == "let" and M.let_noexpand) then
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
		if type(src) == "string" and not COMSUB_PREX and not POSIX_DQ and not MBX
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
		if MBX and type(src) == "string" then
			local hsrc, map, cls = mb_hide(src)
			if hsrc then
				return mb_restore(wimpl(hsrc), map, cls, {})
			end
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
	local saved, sprex, shd = ALIAS_ENV, COMSUB_PREX, IN_HEREDOC
	ALIAS_ENV = aenv -- its $(…) parts carry the heredoc line's static alias state
	COMSUB_PREX = false
	IN_HEREDOC = true
	local ok, err = pcall(parse_dquote, body, function(p)
		parts[#parts + 1] = p
	end, is_body, prompt)
	ALIAS_ENV, COMSUB_PREX, IN_HEREDOC = saved, sprex, shd
	if not ok then
		error(err, 0)
	end
	return { k = "word", parts = parts }
end

-- set -v: does TEXT (a command being read, through its last complete line) end inside an
-- open $( … ) / <( … ) / >( … )? bash reads such a body with parse_comsub, whose lines
-- shell_getc doesn't echo (shell_eof_token set). A quote-aware scan of the top level: '…',
-- "…", `…`, comments, $(( … )) and here-document bodies are skipped.
function M.in_open_cmdsub(text)
	local i, n, hd, wstart = 1, #text, {}, true
	local function sub_open(k) -- the $( / <( / >( at text[k]: true when it never closes
		local ok, e = pcall(scan_cmdsub, text, k + 2)
		if not ok then
			trap_flow(e)
			return true, nil
		end
		return false, e
	end
	while i <= n do
		local c = text:sub(i, i)
		local c2 = text:sub(i + 1, i + 1)
		if c == "\\" then
			i, wstart = i + 2, false
		elseif c == "'" then
			local e = text:find("'", i + 1, true)
			if not e then
				return false
			end
			i, wstart = e + 1, false
		elseif c == "`" then
			local k = i + 1
			while k <= n and text:sub(k, k) ~= "`" do
				k = k + (text:sub(k, k) == "\\" and 2 or 1)
			end
			if k > n then
				return false
			end
			i, wstart = k + 1, false
		elseif c == '"' then
			local k = i + 1
			while k <= n and text:sub(k, k) ~= '"' do
				local d = text:sub(k, k)
				if d == "\\" then
					k = k + 2
				elseif d == "$" and text:sub(k + 1, k + 1) == "(" and text:sub(k + 2, k + 2) ~= "(" then
					local open, e = sub_open(k)
					if open then
						return true
					end
					k = e
				else
					k = k + 1
				end
			end
			if k > n then
				return false
			end
			i, wstart = k + 1, false
		elseif c == "#" and wstart then
			i = text:find("\n", i, true) or n + 1
		elseif c == "\n" then
			i, wstart = i + 1, true
			for _, d in ipairs(hd) do -- (the bodies the line opened: text, not syntax)
				while true do
					if i > n then
						return false
					end
					local e = text:find("\n", i, true) or n + 1
					local l = text:sub(i, e - 1)
					i = e + 1
					if (d.strip and l:gsub("^\t+", "") or l) == d.word then
						break
					end
				end
			end
			hd = {}
		elseif c == "<" and c2 == "<" and text:sub(i + 2, i + 2) ~= "<" then
			local k = i + 2
			local strip = text:sub(k, k) == "-"
			k = text:match("^[ \t]*()", strip and k + 1 or k)
			local w = text:match("^[^%s;&|()<>]+", k)
			if w then
				hd[#hd + 1] = { word = (w:gsub("[\\'\"]", "")), strip = strip }
				i = k + #w
			else
				i = k
			end
			wstart = false
		elseif c == "$" and c2 == "(" and text:sub(i + 2, i + 2) == "(" then
			local e = delim_close_x(text, i + 3)
			if e > n then
				return false
			end
			i, wstart = e + 1, false
		elseif (c == "$" or c == "<" or c == ">") and c2 == "(" then
			local open, e = sub_open(i)
			if open then
				return true
			end
			i, wstart = e, false
		else
			wstart = c == " " or c == "\t" or c == ";" or c == "&" or c == "|" or c == "(" or c == ")"
			i = i + 1
		end
	end
	return false
end
-- A here-document body that doesn't parse (parse_heredoc failed): the position of the
-- top-level $( that never closes, or nil. bash reads the substitution from there to the end
-- of the body (its error is reported at the here-document's line + 1 + the lines it read).
function M.hd_open_cmdsub(body)
	local i = 1
	while true do
		local p = body:find("$(", i, true)
		if not p then
			return nil
		end
		if pcall(M.parse_heredoc, body:sub(1, p - 1), true) and not pcall(scan_cmdsub, body, p + 2) then
			return p
		end
		i = p + 2
	end
end
-- The default/alternate word of a ${x-word} / ${x:-word} / … that sits INSIDE DOUBLE
-- QUOTES follows double-quoted rules: single quotes are literal, a backslash is kept
-- except before $ ` " \ (and \} -> a literal }, \<newline> is a line continuation), and
-- a syntactic inner " is dropped (`"${x:-"a b"}"` -> `a b`). Shared by the interpreter's
-- pexp default expansion and the compiled tier so both render such a default identically.
-- The error bash's xparse_dolparen reports for a $( whose `)` never comes (BODY: the text
-- after it, to the end of the word): the body's own syntax error, else the missing `)'.
function M.open_comsub_err(body)
	local ok, ast = pcall(M.parse, body)
	local err = not ok and (type(ast) == "table" and ast.msg or tostring(ast)) or nil
	for _, st in ipairs(ok and ast.stmts or {}) do
		if st.t == "parse_error" and not st.recoverable then
			err = tostring(st.msg)
			break
		end
	end
	err = err and unpos(err)
	if err == "syntax error: unexpected end of file" then -- (the body ran out inside a
		err = nil -- construct: parse_comsub's own EOF — the `)' it was looking for)
	end
	return err or "unexpected EOF while looking for matching `)'"
end
function M.parse_default_quoted(txt, heredoc)
	local out, k, m, inq = {}, 1, #txt, false
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
			inq = not inq
		elseif ch == "$" and txt:sub(k + 1, k + 1) == '"' then
			-- (`"${u-"$"}"`: inside the inner "…" a `$` before its close is literal; in a
			-- here-document's word a `$"` is no locale string at all — the `"` just drops
			-- and the `$` expands what follows: `${u-$"k"}` is `$k`)
			if inq or heredoc == "hdoc" then
				out[#out + 1] = "$"
			end
			k = k + 1 -- $"…" (a locale string): its text, as "…"
		elseif ch == "$" or ch == "`" then
			-- a nested $(…)/$((…))/${…}/`…` keeps its OWN quoting (`${u:-$(echo "p)q")}`): copy
			-- it verbatim rather than dropping the quotes inside it
			local ok, nj = pcall(expansion_end, txt, k, false, true)
			nj = ok and nj or k + 1
			out[#out + 1] = txt:sub(k, nj - 1)
			k = nj
		else
			out[#out + 1] = ch
			k = k + 1
		end
	end
	local t = table.concat(out)
	-- a construct in the word left open (`"${u-'${'}"`: in "…" the `'` are literal): bash's
	-- expansion of the word fails there — after expanding what precedes it — with
	-- extract_dollar_brace_string's "bad substitution: no closing `}' in WORD" (`$[`: `]',
	-- `$((`: `)'), or "no closing "`" in `…" for a backquote; an open $( … ) is a command substitution
	-- whose body (the rest) fails to parse when it runs
	local bad, k2 = nil, 1
	while k2 <= #t do
		local b = t:byte(k2)
		if b == 92 then
			k2 = k2 + 2
		elseif b == 96 or b == 36 then
			local ok, e = pcall(expansion_end, t, k2, true, b == 96 or t:byte(k2 + 1) == 40)
			if not ok or e > #t + 1 then
				bad = k2
				break
			end
			k2 = e
		else
			k2 = k2 + 1
		end
	end
	local saved = DQ_ANSI
	DQ_ANSI = not heredoc
	local ok, r = pcall(M.parse_heredoc, bad and t:sub(1, bad - 1) or t)
	DQ_ANSI = saved
	if not ok then
		error(r, 0)
	end
	if bad then
		local c2 = t:sub(bad + 1, bad + 1)
		r.parts[#r.parts + 1] = t:byte(bad) == 96 and { bterr = t:sub(bad), q = true }
			or c2 == "(" and t:sub(bad + 2, bad + 2) ~= "(" and { cserr = M.open_comsub_err(t:sub(bad + 2)), q = true }
			or { nulcut = txt, nocl = c2 == "[" and "]" or c2 == "(" and ")" or nil, q = true }
	end
	return r
end

-- bash's own [[ ]] grammar check (parse.y cond_term/cond_and/cond_or/cond_error), run
-- before the AST is built: a malformed conditional is a PARSE-time syntax error — the
-- line runs nothing — reported with bash's messages, then `syntax error near `TOK'`
-- (the offending token; `&&`/`||` shows its first character, as bash's reporter does).
local COND_UNOP, COND_BINOP = {}, {}
for c in ("abcdefghknoprstuvwxzGLOSNR"):gmatch(".") do
	COND_UNOP["-" .. c] = true
end
for _, b in ipairs({ "=", "==", "!=", "=~", "<", ">", "-nt", "-ot", "-ef", "-eq", "-ne", "-lt", "-le", "-gt", "-ge" }) do
	COND_BINOP[b] = true
end
local COND_OPTOK = { ["&&"] = true, ["||"] = true, ["("] = true, [")"] = true, ["<"] = true, [">"] = true,
	-- (the shell's other operator tokens, which [[ ]] has no use for: its errors name them)
	["<<<"] = true, ["<<-"] = true, ["&>>"] = true, [";;&"] = true, ["<<"] = true, ["<&"] = true, ["<>"] = true,
	[">>"] = true, [">&"] = true, [">|"] = true, ["&>"] = true, ["|&"] = true, [";;"] = true, [";&"] = true,
	["|"] = true, [";"] = true, ["&"] = true }
-- (nlb[k]: a newline came before token k. cond_term skips newlines only where bash's
-- cond_skip_newlines does — before a term and after one; reading a unary operator's
-- operand, a binary operator, or its right side (`nonl`) a newline is a `newline' token)
local COND_PEND = {} -- (the token slot of a word that ran into the end of input)
-- An arithmetic operand of [[ ]] (`-lt` …) is expanded with Q_ARITH, where an unquoted `[`
-- starts a subscript (subst.c expand_array_subscript): to its matching `]` its text is
-- expanded, then `[ ] $ ` ~ \ ' "` in it backslash-quoted — `[[:a:]]` reaches the
-- expression (and its error message) as `[\[:a:\]]`. The operand's raw text, rewritten
-- so (the rewritten brackets single-quoted: their backslashes stay); one with an expansion
-- anywhere is left as written.
local ARITH_SUBQ = { ["["] = true, ["]"] = true, ["$"] = true, ["`"] = true, ["~"] = true,
	["\\"] = true, ["'"] = true, ['"'] = true }
local function cond_arith_word(raw)
	if not raw:find("[", 1, true) or raw:find("[$`]") then
		return raw
	end
	local out, i, n, changed = {}, 1, #raw, false
	local function skipq(k) -- past a quote/escape starting at k
		local c = raw:sub(k, k)
		if c == "\\" then
			return k + 2
		end
		local e = raw:find(c, k + 1, true)
		return e and e + 1 or n + 1
	end
	while i <= n do
		local c = raw:sub(i, i)
		if c == "\\" or c == "'" or c == '"' then
			local k = skipq(i)
			out[#out + 1] = raw:sub(i, k - 1)
			i = k
		elseif c == "[" then
			local k, depth = i + 1, 1 -- (skipsubscript: nested brackets, quotes skipped)
			while k <= n do
				local d = raw:sub(k, k)
				if d == "\\" or d == "'" or d == '"' then
					k = skipq(k)
				else
					if d == "[" then
						depth = depth + 1
					elseif d == "]" then
						depth = depth - 1
						if depth == 0 then
							break
						end
					end
					k = k + 1
				end
			end
			local inner = k <= n and k > i + 1 and raw:sub(i + 1, k - 1)
			local plain, q = {}, {}
			if inner then
				local j = 1
				while j <= #inner do -- (its quote removal)
					local d = inner:sub(j, j)
					if d == "\\" then
						plain[#plain + 1] = inner:sub(j + 1, j + 1)
						j = j + 2
					elseif d == "'" or d == '"' then
						local e = inner:find(d, j + 1, true) or #inner + 1
						plain[#plain + 1] = inner:sub(j + 1, e - 1)
						j = e + 1
					else
						plain[#plain + 1] = d
						j = j + 1
					end
				end
				for ch in table.concat(plain):gmatch(".") do
					q[#q + 1] = ARITH_SUBQ[ch] and ("\\" .. ch) or ch
				end
			end
			local qs = inner and table.concat(q)
			if inner and qs ~= table.concat(plain) then
				out[#out + 1] = "'[" .. qs:gsub("'", "'\\''") .. "]'"
				changed = true
				i = k + 1
			else
				out[#out + 1] = "["
				i = i + 1
			end
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	return changed and table.concat(out) or raw
end
local COND_ARITH = { ["-eq"] = true, ["-ne"] = true, ["-lt"] = true, ["-le"] = true, ["-gt"] = true, ["-ge"] = true }
local function cond_check(toks, quoted, nlb, eof, line0, tl)
	local pend_read = false -- (the grammar read the COND_PEND token)
	local pos, ck, ct, fk = 1, nil, nil, nil -- (ck/ct: bash's cond_token, kind and text;
	-- fk: its index — negative for a newline before that token — where an error is reported)
	local pre = {}
	local function nxt(nonl)
		if nonl and nlb[pos] then
			ck, ct = "NL", "newline"
			fk = -pos
			return ck, ct
		end
		fk = pos
		local t = toks[pos]
		pos = pos + 1
		if t == COND_PEND then -- (a word that failed to read: bash's error token, -1)
			ck, ct = "ERR", "\255"
			pend_read = true
			return ck, ct
		end
		if t == nil then -- (no `]]` before the input's end: bash's EOF token)
			ck, ct = eof and "EOF" or "END", eof and "EOF" or "]]"
		elseif not quoted[pos - 1] and COND_OPTOK[t] then
			ck, ct = t, t
		else
			ck, ct = "WORD", t
		end
		return ck, ct
	end
	local function fail(near)
		error({ cond_fail = true, near = near, pend = pend_read or nil }, 0)
	end
	local cond_or
	local function term()
		local k, t = nxt()
		if k == "END" then
			fail(t)
		elseif k == "(" then
			local pl = tl[pos - 1] -- (its errors are reported at the `(`'s line: {msg, line})
			local ok, e = pcall(cond_or)
			if not ok then
				if type(e) ~= "table" or not e.cond_fail then
					error(e, 0)
				end
				pre[#pre + 1] = { "expected `)'", pl } -- (the inner error left cond_token COND_ERROR)
				error(e, 0)
			end
			if ck ~= ")" then
				pre[#pre + 1] = { ck == "WORD" and "expected `)'" or ("unexpected token `" .. ct .. "', expected `)'"), pl }
				fail(ct)
			end
			nxt()
		elseif k == "WORD" and t == "!" then
			term()
		elseif k == "WORD" and COND_UNOP[t] then
			local k2, t2 = nxt(true)
			if k2 == "ERR" then -- (error_token_from_token: none to name)
				pre[#pre + 1] = "unexpected argument to conditional unary operator"
				fail(t2)
			elseif k2 ~= "WORD" then
				pre[#pre + 1] = "unexpected argument `" .. t2 .. "' to conditional unary operator"
				fail(k2 == "NL" and t or t2) -- (near: the input line's last token)
			end
			nxt()
		elseif k == "WORD" then
			local k2, t2 = nxt(true)
			if (k2 == "WORD" and COND_BINOP[t2]) or k2 == "<" or k2 == ">" then
				local k3, t3 = nxt(true)
				if k3 == "ERR" then
					pre[#pre + 1] = "unexpected argument to conditional binary operator"
					fail(t3)
				elseif k3 ~= "WORD" then
					pre[#pre + 1] = "unexpected argument `" .. t3 .. "' to conditional binary operator"
					fail(k3 == "NL" and t2 or t3)
				end
				nxt()
			elseif not (k2 == "END" or k2 == "&&" or k2 == "||" or k2 == ")") then
				pre[#pre + 1] = (k2 == "WORD" or k2 == "ERR") and "conditional binary operator expected"
					or ("unexpected token `" .. t2 .. "', conditional binary operator expected")
				fail(k2 == "NL" and t or t2)
			end
		else
			pre[#pre + 1] = "unexpected token `" .. t .. "' in conditional command"
			fail(t)
		end
	end
	local function cond_and()
		term()
		if ck == "&&" then
			cond_and()
		end
	end
	cond_or = function()
		cond_and()
		if ck == "||" then
			cond_or()
		end
	end
	local ok, e = pcall(cond_or)
	if ok and ck == "EOF" then -- (cond_error at EOF: reported at the `[[`'s line)
		error({ __curse_perr = true, pre = { "unexpected EOF while looking for `]]'" }, preline = line0,
			msg = "syntax error: unexpected end of file", eof = true }, 0)
	elseif ok and ck ~= "END" then -- (cond_error: a token left before `]]`)
		pre[#pre + 1] = ck == "WORD" and "syntax error in conditional expression"
			or ("syntax error in conditional expression: unexpected token `" .. ct .. "'")
		ok, e = false, { cond_fail = true, near = ct }
	end
	if ok then
		return
	end
	if type(e) ~= "table" or not e.cond_fail then
		error(e, 0)
	end
	if e.near == "EOF" then -- (`[[ a &&` then EOF: the term's error, then the parser's)
		error({ __curse_perr = true, pre = pre, msg = "syntax error: unexpected end of file", eof = true }, 0)
	end
	-- (at a real token the caller re-derives `near` from the input text, as bash does)
	error({ __curse_perr = true, pre = pre, exact = true, msg = "syntax error near `" .. e.near .. "'", fk = fk,
		pend = e.pend }, 0)
end

-- Build a [[ … ]] token list's boolean-expression AST:
--   {kind="and"/"or", l, r} | {kind="not", e} | {kind="str", word}
--   {kind="unary", op, word} | {kind="binary", op, l, r, rq}
-- `rq` marks the RHS of ==/!= as fully-quoted (literal, not a glob).
-- The tokens already passed cond_check (bash's grammar), so the list is well formed:
-- only bash's unary operators (COND_UNOP) are unary — `[[ -Q ]]` is a string test.
local function own_word(w)
	local c = {}
	for k, v in pairs(w) do
		c[k] = v
	end
	return c
end
local function parse_dbracket(toks, quoted)
	local pos = 1
	local function peek()
		return toks[pos]
	end
	local parse_or
	local function primary()
		local t = peek()
		if t == "!" then
			pos = pos + 1
			return { kind = "not", e = primary() }
		end
		if t == "(" then
			pos = pos + 1
			local e = parse_or()
			pos = pos + 1 -- (its `)`)
			e.paren = (e.paren or 0) + 1 -- (for `declare -f`, which prints the grouping)
			return e
		end
		if COND_UNOP[t] then -- unary file/string test
			pos = pos + 2
			return { kind = "unary", op = t, word = parse_word(toks[pos - 1]) }
		end
		pos = pos + 1 -- consume lhs
		local op = peek()
		if COND_BINOP[op] then
			pos = pos + 2
			local rt0 = toks[pos - 1]
			local rx = COND_ARITH[op] and cond_arith_word(rt0) or rt0
			local rw = own_word(parse_word(rx)) -- (a copy: parse_word's result is memoized, shared)
			rw.src, rw.xsub = rt0, rx ~= rt0 or nil -- (the word as written: `declare -f`)
			local rq = quoted[pos - 1] -- (fully quoted: `"a"*` starts with a quote yet globs)
			for _, p in ipairs(rq and rw.parts or {}) do
				if not p.q then
					rq = false
					break
				end
			end
			local lx = COND_ARITH[op] and cond_arith_word(t) or t -- (its subscripts: cond_arith_word)
			local lw = own_word(parse_word(lx))
			lw.src, lw.xsub = t, lx ~= t or nil
			return { kind = "binary", op = op, l = lw, r = rw, rq = rq }
		end
		return { kind = "str", word = parse_word(t) }
	end
	-- (a long `a && b && …` chain: grouped balanced, its operands in order — short-circuit
	-- evaluation is the same; a left-deep one as deep as it is long overflows every walk)
	local function balance(kind, items)
		local function build(lo, hi)
			if lo == hi then
				return items[lo]
			end
			local mid = math.floor((lo + hi) / 2)
			return { kind = kind, l = build(lo, mid), r = build(mid + 1, hi) }
		end
		return build(1, #items)
	end
	local function parse_and()
		local items = { primary() }
		while peek() == "&&" do
			pos = pos + 1
			items[#items + 1] = primary()
		end
		if #items >= 32 then
			return balance("and", items)
		end
		local l = items[1]
		for k = 2, #items do
			l = { kind = "and", l = l, r = items[k] }
		end
		return l
	end
	parse_or = function()
		local items = { parse_and() }
		while peek() == "||" do
			pos = pos + 1
			items[#items + 1] = parse_and()
		end
		if #items >= 32 then
			return balance("or", items)
		end
		local l = items[1]
		for k = 2, #items do
			l = { kind = "or", l = l, r = items[k] }
		end
		return l
	end
	return parse_or()
end

-- ---- brace expansion ({a,b,c}, {m..n}, {m..n..step}, {a..z}) ----
-- Textual, before any other expansion; applies to command words and for-in
-- lists (NOT assignment RHS). Quoted regions are skipped.
--
-- Anti-"billion laughs": a word is parsed ONCE into factors (literal chunks and
-- brace groups); ranges stay symbolic (a,b,step), never materialized. Combinations
-- are produced by an odometer that STREAMS each result to a callback — so a huge
-- expansion never builds a giant intermediate. Consumers decide the policy:
-- a command's or a for/select list's word bigger than BRACE_CAP words stays ONE lazy
-- word (bxlazy) that M.brace_words expands in full each time the command runs, as bash
-- does at execution (a huge one in code that never runs costs nothing). Nothing is ever
-- capped or dropped: every word is produced (stress-attack S9; a word list too big for
-- memory ends the shell as bash's xmalloc failure does — rt.oom).
local BRACE_CAP = 100000

-- The unit at `i` in `s` that brace syntax is inert inside, copied whole (braces.c
-- brace_gobbler): a backslash escape (`{abc\,def}`, `{x,\{a}`), a quoted string (`{"a,b",c}`,
-- `"x\"{a,b}"`), a `…`, a ${…}, a $(…)/<(…)/>(…) (`$(echo ")")x{a,b}`). -> the index just
-- past it, or nil.
local function brace_skip(s, i)
	local c, c2 = s:sub(i, i), s:sub(i + 1, i + 1)
	if c == "\\" then
		return i + 2
	elseif c == "'" then
		return quote_end(s, i)
	elseif c == '"' then -- (only a $( … ) nests in it here: `"${u:-"a{b,c}"}"` is ab ac)
		local k, n = i + 1, #s
		while k <= n and s:byte(k) ~= 34 do
			k = s:find("^%$%(", k) and cmdsub_end_lenient(s, k + 2) or k + (s:byte(k) == 92 and 2 or 1)
		end
		return k + 1
	elseif c == "`" or c == "$" and (c2 == "(" or c2 == "{") then
		local ok, e = pcall(expansion_end, s, i, false, true)
		return ok and e or i + 1
	elseif (c == "<" or c == ">") and c2 == "(" then
		return cmdsub_end_lenient(s, i + 2)
	end
	return nil
end
-- Split `s` at each `delim` outside quotes, expansions (brace_skip) and — `braces` — {…}
local function split_top(s, delim, braces)
	local parts, depth, start = {}, 0, 1
	local i = 1
	while i <= #s do
		local c = s:sub(i, i)
		local skip = brace_skip(s, i)
		if skip then
			i = skip
		else
			if braces and c == "{" then
				depth = depth + 1
			elseif braces and c == "}" then
				depth = depth - 1
			elseif c == delim and depth == 0 then
				parts[#parts + 1] = s:sub(start, i - 1)
				start = i + 1
			end
			i = i + 1
		end
	end
	parts[#parts + 1] = s:sub(start)
	return parts
end
-- A character from a {x..y} range, as word TEXT (the expansion is re-parsed as a word):
-- shell-special characters must stay literal (`{Z..a}` yields ` literally), and a `\`
-- comes out as an empty argument (bash's quote removal of the lone backslash).
-- A range's backquote (`{_..a}`): bash expands braces on the raw word, so a generated
-- ` is live — it pairs into a command substitution, stays literal at the word's end, and
-- left open is an expansion error. It travels as BRACE_BQ until the word is whole (bq_word).
local BRACE_BQ = "\0bq\0"
local function brace_char(v)
	local ch = string.char(v)
	if ch == "\\" then
		return "''"
	end
	if ch == "`" then
		return BRACE_BQ
	end
	if ch:match("['\"$;&|<>() \t]") then
		return "\\" .. ch
	end
	return ch
end

-- A brace-expanded word's source text, parsed — resolving its BRACE_BQ backquotes the way
-- bash's expand_word_internal does (subst.c, case '`').
local function bq_word(x)
	if not x:find(BRACE_BQ, 1, true) then
		return parse_word(x)
	end
	local out, pos = {}, 1
	while true do
		local s = x:find(BRACE_BQ, pos, true)
		if not s then
			out[#out + 1] = x:sub(pos)
			break
		end
		out[#out + 1] = x:sub(pos, s - 1)
		local r0 = s + #BRACE_BQ
		if r0 > #x then -- a bare ` ending the word passes through
			out[#out + 1] = "\\`"
			break
		end
		local e = x:find(BRACE_BQ, r0, true)
		if not e then -- no closing `: "bad substitution" when the word is expanded
			local w = parse_word(table.concat(out))
			local parts = {}
			for i, p in ipairs(w.parts) do
				parts[i] = p
			end
			parts[#parts + 1] = { bterr = "`" .. x:sub(r0) } -- (no BRACE_BQ follows: none closed it)
			return { k = "word", parts = parts }
		end
		out[#out + 1] = "`" .. x:sub(r0, e - 1) .. "`"
		pos = e + #BRACE_BQ
	end
	return parse_word(table.concat(out))
end
-- classify the inside of a {…}: a numeric/char range (symbolic) or a comma list
-- (raw alternatives, possibly themselves containing braces), or nil (not a brace).
-- bash zero-pads a numeric range to the widest endpoint iff either endpoint has
-- a leading zero (e.g. {01..3} -> 01 02 03, {01..003} -> 001 002 003).
-- The width counts a `-` sign, as C's %0*d does (braces.c: {-05..5..5} -> -05 000 005).
local function num_pad_width(a, b)
	if a:match("^%-?0%d") or b:match("^%-?0%d") then
		return math.max(#a, #b)
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
	local parts = split_top(inner, ",", true)
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
		local skip = brace_skip(s, i)
		if skip then -- (a backslash escapes the next char, so `\{` isn't a brace open)
			litbuf[#litbuf + 1] = s:sub(i, skip - 1)
			i = skip
		elseif c == "{" then
			local d, j = 1, i + 1
			while j <= #s and d > 0 do
				local cc = s:sub(j, j)
				local skip = brace_skip(s, j)
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

local brace_stream -- forward (mutually recursive with itself over nested alts)
local function range_count(r)
	if type(r.a) == "cdata" or type(r.b) == "cdata" then
		local d = r.b > r.a and r.b - r.a or r.a - r.b
		return tonumber(d / r.step) + 1
	end
	return math.floor(math.abs(r.b - r.a) / r.step) + 1
end
local function pad_num(v, w) -- C's %0*d: zero-pad to a total width w, a sign included
	if type(v) == "cdata" then
		return (tostring(v):gsub("LL$", ""))
	end
	local d = tostring(math.abs(v))
	local dw = v < 0 and w - 1 or w
	if #d < dw then
		d = string.rep("0", dw - #d) .. d
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
local function add_word(words, w, lazy)
	local factors = brace_factors(w)
	if not factors then
		words[#words + 1] = parse_word(w)
		return
	end
	if lazy and count_str(w) > BRACE_CAP then
		local pw = parse_word(w)
		words[#words + 1] = { k = pw.k, parts = pw.parts, src = w, plain = false, bxlazy = w } -- (not plain: no literal fast path)
		words.bxlazy = true
		return
	end
	local r = #factors == 1 and factors[1].range
	if r and not r.char and not r.width and type(r.a) == "number" and type(r.b) == "number"
		and math.abs(r.a) < 1e14 and math.abs(r.b) < 1e14 then
		-- a lone numeric range ({0..N}, {9..1..2}): its words straight from the loop
		local cnt = range_count(r)
		local step = r.a <= r.b and r.step or -r.step
		local v = r.a
		local nw = #words
		local first = nw + 1
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
		if words[first] then
			words[first].bx = { raw = w, n = cnt }
		end
		return
	end
	local n = 0
	local first = #words + 1
	stream_factors(factors, function(x)
		-- (the source text belongs to the unexpanded word: the first expansion carries it,
		-- the rest print nothing — `declare -f` shows `{a,b}` as written. A COPY: parsed
		-- words are memoized and shared.)
		if x ~= "" and not x:find("[^%w_%-%.,/+:=@%%]") then -- plain text: the literal word as is
			words[#words + 1] = { k = "word", parts = { { lit = x, q = false } }, src = n == 0 and w or false }
		else
			local pw = bq_word(x)
			words[#words + 1] = { k = pw.k, parts = pw.parts, src = n == 0 and w or false }
		end
		n = n + 1
	end)
	if words[first] then -- (`set +B` at run time: the n words go back to the one raw word)
		words[first].bx = { raw = w, n = n }
	end
end
M.add_word = add_word -- (compgen -W brace-expands each of its words the same way)
-- An array literal's huge brace element (bxlazy / brace_lazy), expanded as it runs: its
-- element words
function M.brace_elem_words(raw)
	local out = {}
	stream_factors(brace_factors(raw), function(x)
		out[#out + 1] = elem_word(bq_word(x))
	end)
	return out
end
-- A command's word list as it runs: its lazy (huge) brace words expanded in full — or,
-- under `set +B` (optB false), every brace-expanded run back to its one raw word.
function M.brace_words(words, optB)
	if optB == false then
		return M.unbrace_words(words)
	end
	if not words.bxlazy then
		return words
	end
	local out = {}
	for _, w in ipairs(words) do
		if w.bxlazy then
			local first = #out + 1
			add_word(out, w.bxlazy)
			if w.plainarg then -- (a command's argument: see parse_simple's plainarg)
				for k = first, #out do
					if not out[k].fresh then
						out[k].plainarg = true
					end
				end
			end
		else
			out[#out + 1] = w
		end
	end
	return out
end
-- A word list as parsed with brace expansion OFF (`set +B`, which bash consults at
-- expansion time): each brace-expanded run collapses back to its one literal word.
local unbraced = setmetatable({}, { __mode = "k" })
function M.unbrace_words(words)
	local u = unbraced[words]
	if u then
		return u
	end
	u = {}
	local i = 1
	while i <= #words do
		local w = words[i]
		if w.bx then
			local pw = parse_word(w.bx.raw)
			u[#u + 1] = { k = pw.k, parts = pw.parts, src = w.bx.raw, plain = pw.plain }
			i = i + w.bx.n
		else
			u[#u + 1] = w
			i = i + 1
		end
	end
	unbraced[words] = u
	return u
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
				-- (inside "…" a backslash quotes only $ ` " \ and newline: `"E\F"` is E\F)
				if w:sub(i, i) == "\\" and w:sub(i + 1, i + 1):find('^[$`"\\\n]') then
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
local LTR_SEEN = false -- a $"…" was read (M.parse: the program's lines translate as read)
-- A $(…) body's $"…" strings are translated when the OUTER line is read, like the rest of
-- that line (bash reads the whole body text then): each becomes a plain "…" (translated,
-- or not — the run-time parse of the body must not translate it again under a later
-- $TEXTDOMAIN). -> the new body, and how many newlines the translations added (the
-- outer line count skips them; the body's own numbering keeps them, as bash's does).
local function ltr_cmdsub(sh, body)
	if body:find("<<", 1, true) then
		return body, 0 -- (a here-document's text isn't scanned)
	end
	local out, last, k, m, dq, dnl, stack = {}, 1, 1, #body, false, 0, {}
	while k <= m do
		local c = body:sub(k, k)
		local nx = body:sub(k + 1, k + 1)
		if c == "\\" then
			k = k + 2
		elseif c == "'" and not dq then
			k = quote_end(body, k)
		elseif c == "$" and nx == "'" and not dq then
			k = quote_end(body, k + 1, true)
		elseif c == "$" and nx == "(" then
			stack[#stack + 1] = dq
			dq = false
			k = k + 2
		elseif c == "(" and not dq then
			stack[#stack + 1] = false
			k = k + 1
		elseif c == ")" and not dq then
			if #stack > 0 then
				dq = stack[#stack]
				stack[#stack] = nil
			end
			k = k + 1
		elseif c == '"' then
			dq = not dq
			k = k + 1
		elseif c == "$" and nx == '"' and not dq then
			local e = quote_end(body, k + 1, true) - 1
			if e > m then
				break
			end
			local txt = body:sub(k + 2, e - 1)
			local t = require("gettext").translate(sh, txt) or txt
			out[#out + 1] = body:sub(last, k - 1)
			out[#out + 1] = '"' .. t .. '"'
			if t ~= txt then
				dnl = dnl + select(2, t:gsub("\n", "")) - select(2, txt:gsub("\n", ""))
			end
			last = e + 1
			k = e + 1
		else
			k = k + 1
		end
	end
	if last == 1 then
		return body, 0
	end
	out[#out + 1] = body:sub(last)
	return table.concat(out), dnl
end
local WORD_SPECIAL = "[\\()\"'$<>|&`; \t\n?*+@!]"
local DQ_SPECIAL = '[\\"$`]' -- (…and inside "…")
-- bash's reserved words (word_token_alist)
local RESERVED = { ["if"] = true, ["then"] = true, ["else"] = true, ["elif"] = true, ["fi"] = true,
	["case"] = true, ["esac"] = true, ["for"] = true, ["select"] = true, ["while"] = true, ["until"] = true,
	["do"] = true, ["done"] = true, ["in"] = true, ["function"] = true, ["time"] = true, ["{"] = true,
	["}"] = true, ["!"] = true, ["[["] = true, ["]]"] = true, ["coproc"] = true }
-- a case clause's terminators: ;; stop, ;;& test the next patterns, ;& fall through
local CASE_TERM = { [";;"] = "break", [";;&"] = "test", [";&"] = "fall" }
-- reserved words that open a compound command usable as a function body
local FBODY_KW = { ["if"] = true, ["for"] = true, ["while"] = true, ["until"] = true, ["case"] = true, ["select"] = true }

local function make_parser(src, sh, aenv, noalias, posix, line0, lineabs, xg, bq, cs)
	if MBX then -- (a multibyte locale with ASCII trail bytes: see mb_hide)
		local hsrc, map, cls = mb_hide(src)
		if hsrc then
			for ph, c in pairs(map) do
				if c == "\\" then -- (a trail-byte `\`: a here-document body still reads it
					MB_BSL = ph -- byte-wise, as a line continuation — see collect_heredocs)
				end
			end
			local nextf = make_parser(hsrc, sh, aenv, noalias, posix, line0, lineabs, xg, bq, cs)
			return function()
				local lg = nextf()
				if lg then
					local s = lg.src
					lg.src = nil
					mb_restore(lg, map, cls, {})
					lg.src = s == hsrc and src or s and (s:gsub(cls, map))
				end
				return lg
			end
		end
	end
	local i, n, line = 1, #src, lineabs or 1
	local hd_bsl = MB_BSL -- (a trail-byte `\`'s placeholder: collect_heredocs' continuation)
	MB_BSL = nil
	local firstline = lineabs or line0 or 1 -- (the text's first line: an EOF error counts from it)
	local orig_src = src -- (alias expansion splices into src; an error echoes the line as written)
	if line0 then -- a $(…) body numbers from its command's line; leading newlines don't count
		-- (a `…` body's do: parse_and_execute reads it line by line from line_number - 1)
		line = bq and line0 or line0 - #(src:match("^[ \t\n]*"):gsub("[^\n]", ""))
	end
	local loopId = 0
	local arrlit_eof = false -- (an EOF error read inside a NAME=( … ) literal: status 1)
	-- jcx: the line a foreground job killed by a signal is reported at — bash's line_number
	-- once the command is back from execute_simple_command (restored to the enclosing
	-- context's): a top-level command's parser line (its line group's last, heredocs and
	-- all), a function body's `{`, a for/select/case's head, a subshell's `)`. A record
	-- shared by the commands it encloses (the top-level's and subshell's are filled in at
	-- their end); a simple command / pipeline / subshell node carries it as .jcx.
	local jcx = {}
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
	local extglob_on = xg or false -- shopt extglob state (from source; the live sh.shopt when interpreting)
	-- a static parse (no sh, extglob not known off) read `X(…)` / `!(` by a GUESS at the
	-- extglob state the tracking says is off: the program's parse may depend on a live
	-- state (shopt in a function, a syntax error bash would report) — the compiler runs it
	-- in line mode, where each line is parsed by the live reader (xg_guess on the line group)
	local xg_guess = false
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
	-- bash's pushed_string_list: each expansion in progress is a stack entry { name, end
	-- position (just past its spliced text), value-ends-blank }. An entry pops once the
	-- parser reaches a word at/after its end — innermost first — and each pop sets the
	-- next word's eligibility from ITS value (pop_string's PST_ALEXPNEXT), so the last
	-- (outermost) finished expansion decides; a word that isn't expanded clears it. A name
	-- on the stack is AL_BEINGEXPANDED: not expanded again until its text is consumed.
	local astk, astk_n = {}, 0
	local alias_seen = {} -- names on astk (recursion guard)
	-- A syntax error at a token read from an alias's text shows bash's shell_input_line —
	-- that text (the pushed string), not the source line; when the token ends the text, the
	-- delimiter read_token_word ungets (the END_ALIAS space) overwrites its last character.
	local function alias_line(pos, tok)
		for k = astk_n, 1, -1 do
			local e = astk[k]
			if e[4] and pos >= e[4] and pos <= e[2] then -- (the parser at/after the token)
				local v = e[5]
				if v:sub(-#tok) == tok then -- (the token ends the text: a word's delimiter is
					if v:match("[ \t\n|&;()<>]$") then -- ungot over it; after an operator the
						return nil -- text is done — popped, the source line is the input again)
					end
					v = v:sub(1, -2) .. " "
				end
				return v
			end
		end
	end
	local alias_next = false -- the next word is eligible (PST_ALEXPNEXT)
	-- positions of newlines spliced in from alias values: bash reads those from the pushed
	-- string, so they don't advance line_number (nil while there are none)
	local alias_nl = nil
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
				elseif a == "extglob" and set ~= nil and not M.xg_fixed then
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
		-- a $(…) later on THIS line expands with the table as it is when it RUNS (bash):
		-- after an alias/unalias/shopt/set here the line-start snapshot is stale — `dirty`
		-- sends that body to the run-time capture (emit compile_cmdsub_inner)
		local w1 = node.words[1].parts
		local c = #w1 == 1 and not w1[1].q and w1[1].lit
		local dirty = c == "alias" or c == "unalias"
		if c == "shopt" or c == "set" then -- (expand_aliases / posix mode, or a dynamic word)
			for k = 2, #node.words do
				local a = static_word(node.words[k])
				if not a or a == "expand_aliases" or a == "posix" then
					dirty = true
				end
			end
		end
		if dirty then
			ALIAS_ENV = { tab = ALIAS_ENV and ALIAS_ENV.tab or {}, dirty = true }
		end
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
	-- (always eligible); otherwise eligible only via trailing-blank chaining: the flag the
	-- expansions finished before this word leave (see astk).
	local function try_alias(cmdpos)
		local on, tab = alias_state()
		if not on then
			return
		end
		-- pop_string for each expansion whose text is consumed (the word starts past it)
		while astk_n > 0 and astk[astk_n][2] <= i do
			local e = astk[astk_n]
			astk[astk_n], astk_n = nil, astk_n - 1
			alias_seen[e[1]] = nil
			alias_next = e[3]
		end
		if not (cmdpos or alias_next) then
			return
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
			local cand, nls = nil, 0
			-- a `\<newline>` is gone before bash tokenizes (shell_getc): the word runs on
			-- past it (`E\<nl> x` is `E x`, `E\<nl>X` is `EX`)
			while nextch == "\\" and src:sub(re + 2, re + 2) == "\n" do
				local more = src:match("^[^ \t\n|&;()<>'\"`\\$]*", re + 3)
				cand = (cand or src:sub(rs, re)) .. more
				nls = nls + 1
				re = re + 2 + #more
				nextch = src:sub(re + 1, re + 1)
			end
			if nextch ~= "" and nextch:match("['\"`\\$]") then
				break
			end -- not a pure literal word
			cand = cand or src:sub(rs, re)
			local val = tab and tab[cand]
			if val == nil or alias_seen[cand] then
				break
			end
			-- posix mode checks for a reserved word BEFORE alias expansion (parse.y's
			-- read_token_word): one where a command starts is never an alias there
			if cmdpos and RESERVED[cand] and (sh and sh.opt_posix or (not sh and posix_on)) then
				break
			end
			line = line + nls -- (the spliced-out continuations' newlines)
			local L = re - rs + 1
			-- the end of an expansion delimits the token (bash mk_alexpansion adds a space) —
			-- `alias foo='echo 0'; foo>&2` is `echo 0 >&2`, not `echo 0>&2` — except after a
			-- trailing backslash, which quotes the next input char (`alias a='… \'; a|cat`)
			local ins = val
			-- (shell_getc: none after a blank, newline or metachar — `alias s='echo 8 )'`)
			if ins ~= "" and not ins:match("[ \t\n\\|&;()<>]$") then
				-- …and not when the value ends INSIDE an open quote (`alias foo="echo 'Err:"`):
				-- the quoted string continues into the following input
				local k, open = 1, false
				while k <= #ins do
					local b = ins:byte(k)
					if b == 39 or b == 34 then -- ' "
						k = quote_end(ins, k, b == 34)
						open = k > #ins + 1 -- (ran off the end: left open)
					else
						k = k + (b == 92 and 2 or 1)
					end
				end
				if not open then
					ins = ins .. " "
				end
			end
			src = src:sub(1, rs - 1) .. ins .. src:sub(re + 1)
			n = #src
			-- the enclosing expansions' texts (and their newlines) grow around the splice
			local d = #ins - L
			for k = 1, astk_n do
				astk[k][2] = astk[k][2] + d
			end
			if alias_nl then
				local moved = {}
				for p in pairs(alias_nl) do
					moved[p > re and p + d or p] = true
				end
				alias_nl = moved
			end
			if ins:find("\n", 1, true) then
				alias_nl = alias_nl or {}
				local k = ins:find("\n", 1, true)
				while k do
					alias_nl[rs - 1 + k] = true
					k = ins:find("\n", k + 1, true)
				end
			end
			astk_n = astk_n + 1
			astk[astk_n] = { cand, rs + #ins, val:match("[ \t]$") ~= nil, rs, val }
			alias_seen[cand] = true
			expanded = true
			-- recurse: the value's first word (now at i) is itself command-position
		end
		-- the word read isn't an alias (alias_expand_token's NO_EXPANSION): the chain
		-- ends until a later pop sets it again
		alias_next = false
	end
	-- Collect the bodies of any heredocs opened on the just-parsed line. Called
	-- after a simple command AND after a compound command's redirs (group,
	-- subshell, etc.), since `{ ...; } <<EOF` also opens a heredoc.
	local function collect_heredocs()
		if #heredocs_pending == 0 then
			return
		end
		i = src:find("\n", i, true) or n + 1 -- to end of command line
		local rline, nread = line, 0 -- (bash's warning lines: where reading began, + lines read)
		-- A command line ended by a newline from an ALIAS value: bash reads a heredoc body
		-- with read_secondary_line -> yy_getc, straight from the input source and NOT from
		-- the pushed alias string (parse.y read_a_line) — so the body is the lines after the
		-- current PHYSICAL line, and the rest of the alias text is parsed as commands after
		-- it (`alias c='cat <<EOF<nl>$(echo hi)<nl>EOF<nl>'; c` reads an empty body at EOF,
		-- then runs `hi` and `EOF`). Read from past the physical newline, splice the bodies
		-- out of src below, and resume just past the alias newline.
		local anl = alias_nl and i <= n and alias_nl[i] and i
		if anl then
			i = i + 1
			while i <= n and (src:byte(i) ~= 10 or alias_nl[i]) do
				i = i + 1
			end
		end
		local pnl = i -- (the physical newline the bodies follow)
		if i <= n then
			i = i + 1
			if not (alias_nl and alias_nl[i - 1]) then line = line + 1 end
		end
		for _, hd in ipairs(heredocs_pending) do
			local blines = {}
			local found = false
			local hline = rline + nread -- (the line its reading began at: after the bodies before it)
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
				-- (bash reads a body byte by byte: a multibyte char's trail `\` just before the
				-- newline joins too — though it escapes nothing, so `\xa3\x5c\\` joins as well)
				while hd.expand and le <= n and not (le == n and src == M.synth_eol)
					and (#lstr:match("\\*$") % 2 == 1 or (hd_bsl and lstr:sub(-1) == hd_bsl)) do
					le = src:find("\n", i, true) or (n + 1)
					local nxt = src:sub(i, le - 1)
					if hd.strip then
						nxt = nxt:gsub("^\t+", "")
					end
					lstr = lstr:sub(1, -2) .. nxt
					i = le + 1
					line = line + 1
					nread = nread + 1 -- (a joined line is read too: the warning's line counts it)
				end
				-- (the input ends in a `\` quoting nothing: bash drops it, and the body's last
				-- line then has no newline)
				if hd.expand and #lstr:match("\\*$") % 2 == 1 and (le > n or le == n and src == M.synth_eol) then
					if le == n then -- (a script file's last line: shell_getc's added newline)
						lstr, hd.nonl = lstr:sub(1, -2), true
						i = n + 1
					else -- (a string's end — eval, source: the EOF shell_getc returned after the
						lstr = lstr .. "\255" -- `\` is stored as a byte, 0xff, in the line)
					end
				end
				if lstr == hd.delim then
					found = true
					break
				end
				-- a $(…) body's final `DELIM )` line reached here as `DELIM ` (see scan_cmdsub);
				-- a backtick body has no such form: its last `DELIM ` line is body text
				-- (cs: a $(…) body compiled as a fragment, read without a line0)
				if le > n and (line0 or cs) and not bq and lstr:match("^(.-)[ \t]+$") == hd.delim then
					found = true
					break
				end
				blines[#blines + 1] = lstr
			end
			if not found then
				warns[#warns + 1] = { t = "warn", line = rline + nread,
					msg = ("warning: here-document at line %d delimited by end-of-file (wanted `%s')"):format(hline, hd.delim) }
			end
			hd.body = #blines > 0 and (table.concat(blines, "\n") .. (hd.nonl and not found and "" or "\n")) or ""
			hd.nonl = nil
			hd.aenv = ALIAS_ENV -- the compiler re-parses an expanding body later (parse_heredoc)
		end
		heredocs_pending = {}
		if anl then
			if pnl < n then -- drop the consumed body lines (keep the physical newline)
				local e = i <= n and i or n + 1
				src = src:sub(1, pnl) .. src:sub(e)
				n = #src
				local d = e - pnl - 1
				if d > 0 then
					local moved = {}
					for x in pairs(alias_nl) do
						moved[x > pnl and x - d or x] = true
					end
					alias_nl = moved
				end
			end
			if pnl <= n then
				line = line - 1 -- (the physical newline is counted again when parsing reaches it)
			end
			i = anl + 1
		end
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
		local redirs = hoisted or {}
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
	-- Past the newline at i: the bodies of here-documents opened on the line just read follow
	-- it (collect_heredocs takes them, newline and all); else it's one more line — unless an
	-- alias value spliced it in (bash reads those from the pushed string: no line_number++).
	local function newline()
		if #heredocs_pending > 0 then
			collect_heredocs()
		else
			if not (alias_nl and alias_nl[i]) then line = line + 1 end
			i = i + 1
		end
	end
	-- Skip what may separate tokens where a command (list) goes on: blanks, `\<newline>`s,
	-- newlines (newline()), comments — and `;`s when `semi`. Without it this STOPS at a
	-- statement separator (; & |), so the statement loops can tell a *trailing* separator
	-- (fine) from one in command position (a syntax error — see bare_sep_tok).
	local function skipsep(semi) -- (-> whether a newline was crossed)
		local nl = false
		while i <= n do
			ws()
			local c = src:byte(i)
			if c == 10 then
				newline()
				nl = true
			elseif c == 35 then -- (a comment, to the end of the line)
				i = src:find("\n", i, true) or n + 1
			elseif c == 59 and semi then
				i = i + 1
			else
				break
			end
		end
		return nl
	end
	-- the token bash's lexer reads at k when no word starts there (read_token's operators,
	-- longest match; the end or a newline is `newline`)
	local OPTOKS = { "<<<", "<<-", ";;&", "&>>", "<<", "<&", "<>", ">>", ">&", ">|", "&>", "&&", "||",
		"|&", ";;", ";&", "<", ">", "&", "|", ";", "(", ")" }
	local function op_token(k)
		if k > n or src:byte(k) == 10 or src:byte(k) == 35 then -- (a comment: to the newline)
			return "newline"
		end
		for _, t in ipairs(OPTOKS) do
			if src:sub(k, k + #t - 1) == t then
				return t
			end
		end
		return src:sub(k, k)
	end
	-- At a command-expected position a control operator means an empty command,
	-- which bash rejects as a syntax error (status 2): a leading/doubled `;`, `;;`,
	-- `&`, `&&`, `||`, `|`, or `|&`. Returns the offending token, or nil.
	local function bare_sep_tok()
		if src:sub(i, i + 1) == "&>" then -- (`&>` / `&>>` is a redirection: `&>f cmd`)
			return nil
		end
		if src:sub(i, i + 2) == ";;&" then -- (the lexer's longest match: `;;&`, `;&` are tokens)
			return ";;&"
		end
		local c2 = src:sub(i, i + 1)
		if c2 == ";;" or c2 == ";&" or c2 == "&&" or c2 == "||" or c2 == "|&" then
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
	-- a here-document opened inside a $( … ) / <( … ) / >( … ) that ends on this line:
	-- its body is on the following lines (bash) — move those lines (through each
	-- delimiter) inside the substitution's text; returns its new end
	local function hdp_splice(je, hdp) -- (-> the new end, and the lines it moved in)
		local dl = 0
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
			dl = -1 -- (that inserted newline isn't a source line)
			warns[#warns + 1] = { t = "warn", line = line,
				msg = ("warning: command substitution: %d unterminated here-document%s"):format(#hdp, #hdp == 1 and "" or "s") }
		end
		return je, dl
	end
	-- A syntax error on a line that opened here-documents: bash's error recovery reads on
	-- through the newline, which gathers their bodies first — their EOF warnings come before
	-- the error, reported at the last line read; the line shown stays the command's (the
	-- reader's position is kept). LG: the group being returned; WHEN: the error is one.
	local function perr_gather(when, lg)
		if when and #heredocs_pending > 0 then
			local ei = i
			if pcall(collect_heredocs) then
				lg.perr.line = line - 1
			end
			i = ei
		end
		return lg
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
	-- extglob is known to be OFF: the live shell's option when interpreting (the static,
	-- source-tracked state is only a guess — `shopt -s extglob` in a called function,
	-- BASHOPTS, `bash -O` — so the sh-less path never rejects a pattern on it)
	local function xg_off()
		if sh then
			return sh.shopt ~= nil and not sh.shopt.extglob
		end
		return xg == false and not extglob_on -- (the live state the text started from, if given)
	end
	-- the extglob state a $(…) body is read under (bash's parse_comsub: the state when the
	-- enclosing line is read) for its read-time syntax check, or nil when only a guess
	local function xg_body()
		if sh then
			return sh.shopt ~= nil and sh.shopt.extglob or false
		elseif extglob_on then
			return true
		elseif xg == false then
			return false
		end
		return nil
	end
	-- the parse-time options (posix, extglob) a loop / function definition was read under,
	-- in tier.compile_fragment's pst form: its hot-path recompile from its source text
	-- (tier loop_fragment / fn_hot) must parse it the same way, whatever is live by then.
	-- nil: a static parse from the defaults (the recompile's own default reproduces it).
	-- "b": read in a multibyte locale with ASCII trail bytes (MBX), which the recompile
	-- must lex the same way.
	local function pst_now()
		local p, x
		if sh then
			p, x = sh.opt_posix, sh.shopt ~= nil and sh.shopt.extglob
		else
			p, x = posix_on, extglob_on
			if not (p or x or MBX) then
				return nil
			end
		end
		return (p and "p" or "") .. (x and "x" or "-") .. (MBX and "b" or "")
	end
	-- from just past an extglob `X(`, to just past its matching `)`
	local function scan_extglob(k)
		local d, k0 = 1, k
		while k <= n do
			local cc = src:byte(k)
			if cc == 92 then -- \
				k = k + 2
			elseif cc == 39 or cc == 34 then -- ' "
				k = quote_end(src, k, cc == 34)
			else
				if cc == 40 then
					d = d + 1
				elseif cc == 41 then
					d = d - 1
					if d == 0 then
						return k + 1
					end
				end
				k = k + 1
			end
		end
		comsub_eof = false -- (reported at the line it began on)
		eof_error(src, k0, ")")
	end
	-- a syntax error in a $( … ) body: parse_comsub's jump_to_top_level(FORCE_EOF) — an eval'd
	-- text's one ends the (non-interactive) shell, status 1
	-- could an alias change how this $( … ) body parses? (one of the live names is in it)
	local function alias_touch(body)
		local on, tab = alias_state()
		if on and tab then
			for k in pairs(tab) do
				if body:find(k, 1, true) then
					return true
				end
			end
		end
		return false
	end
	local function comsub_err(cerr, eline, cbody, je) -- (eline: the body's line with the error,
		local near, t = cerr:find("near `", 1, true), nil -- reported there, and shown when it's
		if near and eline and eline > 1 then -- a whole source line)
			local k, last = 0, true
			for l in (cbody .. "\n"):gmatch("([^\n]*)\n") do
				k = k + 1
				if k == eline then
					t = l
				elseif k > eline then
					last = false
				end
			end
			if t and last and je then -- (the body's last line: the source line goes on past its `)`)
				t = t .. (src:match("^[^\n]*", je - 1) or "")
			end
		end
		error({ __curse_perr = true, msg = cerr, line = near and (line + (eline or 1) - 1) or nil, ltext = t,
			forceeof = true }, 0)
	end
	-- the read-time syntax check of a $(…) body (a guessed extglob state: line mode)
	local function comsub_check(cbody, je)
		local bxg = nil
		if cbody:find("[@!+*?]%(") then
			bxg = xg_body()
		end
		local cerr, guessed, eline = comsub_syntax(cbody, bxg)
		if guessed then
			xg_guess = true
		elseif cerr then
			comsub_err(cerr, eline, cbody, je)
		end
	end
	-- the $( … ) bodies in a ${ … } (src[k..e)) are syntax-checked as the line is read, as
	-- at the word's top level: bash's parse_matched_pair reads a ${ with parse_comsub for
	-- each `$(`, and nested "…" the same way — but a '…' (even one inside "${…}", where it
	-- expands as literal quotes) and `…` are read as quoted strings, unchecked
	local function braces_comsubs(k, e)
		while k < e do
			local c = src:sub(k, k)
			if c == "\\" then
				k = k + 2
			elseif c == "'" then
				k = quote_end(src, k, src:sub(k - 1, k - 1) == "$")
			elseif c == "`" then
				k = quote_end(src, k, true)
			elseif c == "$" and src:sub(k + 1, k + 1) == "(" then
				local je = scan_cmdsub(src, k + 2)
				local cbody = src:sub(k + 2, je - 2)
				if src:sub(k + 2, k + 2) ~= "(" and not cbody:find("<<", 1, true) and not cbody:find('$"', 1, true)
					and not alias_touch(cbody) then
					comsub_check(cbody, je)
				end
				k = je
			else
				k = k + 1
			end
		end
	end
	-- Read one shell word, keeping quotes and $(( )) / ${ } / $( ) balanced. One loop reads
	-- the whole word, inside "…" (q0: its opening quote) and out: an expansion is read the
	-- same way in both — a $( … ) in "…" is syntax-checked and takes its here-document too.
	local word_sub -- (a command-position NAME[ … ] whose subscript was already scanned: word())
	local function word(stop_paren, stop_cmp, xgok) -- (xgok false: a [[ ]] word that is no
		-- pattern — extglob only as the shell's option has it)
		ws()
		local start, line0, lfix, ldq, q0 = i, line, 0, nil, nil
		if word_sub and word_sub.at == i and word_sub.src == src then -- (NAME[ … ]: read whole)
			i = word_sub.close + 1
		end
		word_sub = nil
		while i <= n do
			-- (a run of ordinary characters is part of the word: jump to the next one that
			-- could matter — one find instead of a per-character pattern test)
			local j = src:find(q0 and DQ_SPECIAL or WORD_SPECIAL, i)
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
			elseif c == "$" and src:byte(i + 1) == 34 and not q0 then
				i = i + 1
				ldq = i -- (a $"…": its text is translated once the close is found)
				LTR_SEEN = true
			elseif c == '"' and not q0 then
				q0 = i
				i = i + 1
			elseif c == '"' then
				i = i + 1 -- past closing quote
				if ldq == q0 and sh then
					-- bash's locale_expand, as the line is READ (the locale and $TEXTDOMAIN
					-- then in force): the translation replaces the text, still in "…"
					local ot = src:sub(q0 + 1, i - 2)
					local t = require("gettext").translate(sh, ot)
					if t then
						if t:find("\n", 1, true) or ot:find("\n", 1, true) then -- (the line count is the
							lfix = lfix - select(2, t:gsub("\n", "")) + select(2, ot:gsub("\n", "")) -- text's as read)
						end
						src = src:sub(1, q0) .. t .. src:sub(i - 1)
						n = #src
						i = q0 + #t + 2
					end
				end
				q0 = nil
			elseif c == "'" then -- single quotes: everything literal, no escapes
				i = quote_end(src, i, false, true)
			elseif c == "$" and src:sub(i + 1, i + 1) == "'" and not q0 then
				i = quote_end(src, i + 1, true, true) -- $'…' ANSI-C quote: \' \\ don't close it
			elseif c == "$" and src:sub(i + 1, i + 2) == "((" and (dparen_is_arith(src, i + 3)
				or not dparen_close(src, i + 3)) then -- (bash reads a `$((` as arithmetic first
				local _, ni = grab_dparen(src, i + 3) -- — P_ARITH: a `${` in it nests nothing —
				i = ni -- so one never closed is ITS EOF error: `$(( ${a` wants `)')
			elseif c == "$" and src:sub(i + 1, i + 2) == "((" and pa_short(src, i) then
				-- (a `$((` that is no `$(( … ))`: bash's token still ends where parse_matched_pair
				-- (P_ARITH) balanced it, before the $( … ) reading would: `$(( ${x:-)} ))` is the
				-- word `$(( ${x:-)} )`, then a `)`)
				i = pa_short(src, i)
			elseif c == "$" and src:sub(i + 1, i + 1) == "[" then -- $[expr]: keep whole (spaces inside)
				i = bracket_close(src, i + 1) + 1
			elseif c == "$" and src:byte(i + 1) == 36 then -- `$$` (read_token_word): one token
				i = i + 2
			elseif c == "$" and src:sub(i + 1, i + 1) == "(" then
				if COMSUB_PREX and not noalias then
					i = i + 2
					prex_comsub()
				else
					local je, hdp = scan_cmdsub(src, i + 2, hdwarn_for(start, line0)) -- case/quote/nesting-aware boundary (errors if unclosed)
					local cbody = src:sub(i + 2, je - 2)
					if cbody:find('$"', 1, true) then -- ($"…" in it: translated as this line is read)
						LTR_SEEN = true
						if sh then
							local nb, dnl = ltr_cmdsub(sh, cbody)
							if nb ~= cbody then
								src = src:sub(1, i + 1) .. nb .. src:sub(je - 1)
								n = #src
								je = je + #nb - #cbody
								lfix = lfix - dnl
								cbody = nb
							end
						end
					end
					-- (not when the static parse could be wrong: aliases in play, here-documents,
					-- extglob patterns while the state they're read under is only a guess)
					-- (a `<<` with no delimiter word at all is an error either way: `$(cat <<)`)
					if not hdp and src:sub(i + 2, i + 2) ~= "("
						and (not cbody:find("<<", 1, true) or cbody:find("<<%-?[ \t]*$") or cbody:find("<<%-?[ \t]*[\n;&|)]"))
						and not alias_touch(cbody) then
						comsub_check(cbody, je)
					end
					if hdp then
						local dl
						je, dl = hdp_splice(je, hdp)
						lfix = lfix + dl
					end
					i = je
				end
			elseif (c == "<" or c == ">") and src:sub(i + 1, i + 1) == "(" then
				-- <(cmd) / >(cmd) process substitution: part of the word — scanned like $(…)
				-- (its body has its own quoting / case syntax; a here-document opened in it
				-- reads its body from the following lines, as a $(…)'s does)
				local je, hdp = scan_cmdsub(src, i + 2, hdwarn_for(start, line0))
				-- (bash 5.2 reads the body with parse_comsub too: a syntax error in it fails
				-- the whole line as the word is read — the $( … ) check below)
				local cbody = src:sub(i + 2, je - 2)
				if not hdp and not cbody:find('$"', 1, true)
					and (not cbody:find("<<", 1, true) or cbody:find("<<%-?[ \t]*$") or cbody:find("<<%-?[ \t]*[\n;&|)]"))
					and not alias_touch(cbody) then
					comsub_check(cbody, je)
				end
				if hdp then
					local dl
					je, dl = hdp_splice(je, hdp)
					lfix = lfix + dl
				end
				i = je
			elseif (c == "?" or c == "*" or c == "+" or c == "@" or c == "!") and src:sub(i + 1, i + 1) == "("
				and ((stop_cmp and xgok ~= false) or not xg_off()) then
				if not (sh or (stop_cmp and xgok ~= false) or extglob_on or xg == false) then
					xg_guess = true
				end
				-- extglob ?(..) *(..) +(..) @(..) !(..): part of the word, not a subshell —
				-- decided when the line is PARSED (bash's lexer checks extended_glob; a [[ ]]
				-- pattern always allows it). Quotes and `\` inside don't count toward the
				-- parens (parse_matched_pair).
				i = scan_extglob(i + 2)
			elseif c == "<" or c == ">" or c == "|" or c == "&" then
				break -- metacharacters end a word: redirs (procsub <(/>( handled above), `|`/`&` pipelines/lists & `&&`/`||`/`>&` need no surrounding space
			elseif c == "$" and src:sub(i + 1, i + 1) == "{" then
				local bs = i
				i = scan_braces(src, i + 1, q0, hdwarn_for(start, line0)) -- ${…}: match the close, honoring \ ' " and nesting
				if src:find("$(", bs + 2, true) and src:find("$(", bs + 2, true) < i then
					braces_comsubs(bs + 2, i - 1)
				end
			elseif c == "`" then -- `…` command sub: keep it whole (spaces inside included)
				i = quote_end(src, i, true, true)
			elseif c == " " or c == "\t" or c == "\n" or c == ";" then
				break
			else
				i = i + 1
			end
		end
		if q0 then
			eof_error(src, q0, '"') -- unterminated "
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
		-- (a reserved word is a whole token: `if=1`, `do.x`, `fi-2` are ordinary words)
		local w = s and not src:find("^[^ \t\n;&|()<>]", e + 1) and src:sub(s, e) or nil
		i = save
		pk_i, pk_src, pk_w, pk_dl = save, src, w, line - l0
		return w
	end

	local brace_group
	local parse_command -- forward (a function body may be any compound command)
	-- A for/select body: `do … done`, or bash's `{ … }` alternative
	-- (`for ((i=0; i<3; i++)) { echo $i; }`, `for x in a b; { …; }`).
	local function loop_body()
		skipsep(true)
		if src:sub(i, i) == "{" then
			return brace_group()
		end
		if peekword() == "do" and not src:sub(i + 2, i + 2):match("[^ \t\n;&|()<>]") then
			i = i + 2
		elseif i > n then
			error("syntax error: unexpected end of file")
		else -- (bash: the token where `do` or `{` belongs)
			local tok = src:match("^[^ \t\n;&|()<>]+", i) or src:match("^[;&|]+", i) or src:sub(i, i)
			error("syntax error near `" .. tok .. "'")
		end
		local body, term = parse_stmts({ done = true })
		if term ~= "done" then
			error("syntax error: unexpected end of file") -- (no done)
		end
		return body, term
	end
	brace_group = function() -- parse `{ stmts }` (a function body / group)
		ws()
		if i > n then
			error("syntax error: unexpected end of file")
		end
		if src:sub(i, i) ~= "{" or src:find("^[^ \t\n;&|()<>]", i + 1) then -- (bash: the token found instead)
			local tok = src:match("^[^ \t\n;&|()<>]+", i) or peekword() or src:sub(i, i)
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
		skipsep() -- bash allows newlines before the body
		local bline = line -- the body's first line (a traced call's entry DEBUG reports it)
		local sjcx = jcx
		jcx = { l = bline, up = sjcx } -- (restored by funcdef_node)
		-- any compound command is a body (bash's function_body: shell_command): `f() if …
		-- fi`, `f() for …`, `f() [[ … ]]`, `f() (( … ))`, `function f case … esac`
		local kw = src:match("^[%a]+", i)
		if (kw and FBODY_KW[kw] and not src:find("^[^ \t\n;&|()<>]", i + #kw))
			or src:find("^%[%[[ \t\n]", i) or src:sub(i, i + 1) == "((" then
			local node = parse_command()
			local fb = M.fn_bstart
			jcx.l = math.max(fb, 1) -- (bash's tc->line: see below)
			if node.t ~= "subshell" then
				-- (its redirections are the definition's — bash's function_body:
				-- shell_command redirection_list — applied at tc->line: funcdef_node)
				local hr = node.redirs
				node.redirs = nil
				-- ([[ ]] / (( )) / for (( )) name their own line in errors instead:
				-- executing_line_number's cm_cond / cm_arith / cm_arith_for)
				-- — while bash is `executing`, not in an EXIT trap after end of input)
				local own = (node.t == "dbracket" or node.t == "arithcmd" or node.t == "forc") and node.line
				return { node }, bline, hr and "kw" or nil, fb, hr, own or nil -- (subbody:
				-- declare -f prints them on the body command, as with a `( … )` body)
			end
			-- (`((` that was two nested subshells: the subshell body, as below)
			node.jcx = { l = math.max(fb, 1) }
			return { node }, bline, true, node.line
		end
		if src:sub(i, i) == "(" then
			i = i + 1
			local fjcx = jcx
			jcx = {}
			local body, pterm = parse_stmts({ [")"] = true })
			local close = line
			jcx.l, jcx = line, fjcx -- (bash's subshell->line: where it closes)
			if pterm ~= ")" then
				error("syntax error: unexpected end of file") -- unclosed ( )
			end
			if #body == 0 then
				error("syntax error near `)'") -- (`f() ( )`: bash)
			end
			M.mark_tail(body, true)
			-- the line its caller reports the subshell's job at: execute_function's
			-- line_number = tc->line, which make_function_def sets to function_bstart — only
			-- a `{` body's parse updates that (parse.y's PST_ALLOWOPNBRC), so any other body
			-- carries the last `{`-bodied function's `{` line (0 -> 1: notify_of_job_status)
			return { { t = "subshell", line = bline, body = body, jcx = { l = math.max(M.fn_bstart, 1) }, fnbody = true } }, bline, true,
				close
		end
		M.fn_bstart = bline -- (at its `{`: a function defined inside moves it on)
		return brace_group(), bline, nil, bline
	end
	-- A function definition, with any trailing redirects (`f() { … } >&2`) that apply
	-- to the whole body on every call.
	-- the end of the WORD at src[k] as the reader takes it (quotes, escapes and expansions
	-- whole; an unclosed one runs to the end), for a function name read raw
	local function raw_word_end(k)
		while k <= n do
			local c = src:sub(k, k)
			if c == "\\" then
				k = k + 2
			elseif c == "'" then
				k = quote_end(src, k, false)
			elseif c == '"' then
				k = dq_end(src, k, true)
			elseif c == "$" and src:sub(k + 1, k + 1) == "'" then
				k = quote_end(src, k + 1, true)
			elseif c == "$" or c == "`" then
				local ok, e = pcall(expansion_end, src, k, false, true)
				if not ok then
					trap_flow(e)
				end
				k = ok and e or n + 1
			elseif c:match("[ \t\n;&|()<>]") then
				break
			else
				k = k + 1
			end
		end
		return math.min(k, n + 1)
	end
	local function funcdef_node(nm, dstart, dline)
		-- rline: the line the definition's redirections are applied at — execute_function's
		-- line_number = tc->line (make_function_def's function_bstart: the `{` line, or for
		-- any other body the last `{`-bodied definition's, 0 — no line — before any), and
		-- for a `( … )` body the subshell's own (execute_in_subshell: where it closes)
		local body, bline, subbody, rline, hoisted, rline_own = func_body()
		jcx = jcx.up or jcx
		if subbody ~= true then -- ("kw": a keyword body, its redirections hoisted)
			M.mark_fntail(body, nm)
		end
		-- capture the definition's exact source text (name/`function` through the
		-- closing `}`) so `declare -f`/`type`/`command -V` can recover it verbatim,
		-- no deparser needed. `src` here is the whole script or the -c/stdin string.
		local deftext = dstart and src:sub(dstart, i - 1) or nil
		local redirs = hoisted or {}
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
			_pst = deftext and pst_now(),
			line = dline,
			bline = bline,
			rline = rline,
			rline_own = rline_own,
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
				local hw = src:byte(i) ~= 35 and word(true) or "" -- (`#`: a comment)
				if hw == "" then -- (no word: bash's token after `<<<` — `<<<`, `;`, `newline`)
					error("syntax error near `" .. op_token(i) .. "'")
				end
				return { op = "herestring", fd = fd and tonumber(fd) or 0, word = hw, fdvar = fdvar } -- raw word (expanded at runtime)
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
				local draw = src:byte(i) ~= 35 and strip_contin(word()) or "" -- (`<<\EOT\<newline>4` is EOT4; `#`: a comment)
				if draw == "" then -- (no delimiter word: bash's token after `<<`)
					error("syntax error near `" .. op_token(i) .. "'")
				end
				-- ANY quoting anywhere in the delimiter word makes the body literal (bash);
				-- the delimiter itself is the word with all quotes removed.
				-- (a quote inside a ${…} / $(…) / $[…] / `…` is that construct's: it doesn't set
				-- the word's W_QUOTED — `<<${x"y"}` is unquoted, the delimiter kept as written)
				local quoted = false
				if draw:find("['\"\\]") then
					local k, dn = 1, #draw
					while k <= dn do
						local b = draw:byte(k)
						if b == 39 or b == 34 or b == 92 then
							quoted = true
							break
						elseif b == 36 and draw:match("^[{(%[]", k + 1) or b == 96 then
							local ok, e = pcall(expansion_end, draw, k, false, true)
							k = ok and e or dn + 1
						else
							k = k + 1
						end
					end
				end
				local dword = quoted and dequote_word(draw) or draw
				local r = {
					op = "heredoc",
					fd = fd and tonumber(fd) or 0,
					-- (`<<-`: the delimiter's own leading tabs go too, like each line's)
					delim = strip and (dword:gsub("^\t+", "")) or dword,
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
		-- after `>&`/`<&` a `-` is a token of its own (parse.y read_token): `>&-1` closes
		-- stdout and leaves `1` as the next word
		if (op == "dup" or op == "dupin") and src:byte(i) == 45 then
			i = i + 1
			return { fd = tfd, op = op, target = "-", src = "-", fdvar = fdvar, line = line }
		end
		-- stop_paren: a redirect target is a metacharacter-terminated word, so `)` ends it
		-- — `(cmd >&7)` / `(cmd >f)` must read `7`/`f` and leave `)` to close the subshell,
		-- not swallow it into the target (which unbalanced the parse and dropped the pipe).
		local raw = src:byte(i) ~= 35 and word(true) or "" -- (a `#` there starts a comment: bash)
		-- a redirection with NO word (`echo >`, `cmd <;`) is a syntax error in bash
		-- (status 2). A quoted empty target (`> ''`) is a real, empty filename — that's
		-- a runtime failure, not a parse error — so key on the raw word being absent.
		if raw == "" then
			error("syntax error near `" .. op_token(i) .. "'")
		end
		return { fd = tfd, op = op, target = unquote(raw), src = raw, fdvar = fdvar, line = line } -- (src: `declare -f`)
	end

	-- Parse ONE assignment at the cursor (NAME=… / NAME[i]=… / NAME+=… /
	-- NAME=(array)); returns an assign node, or nil (cursor unchanged) if there
	-- isn't one. Used for both statements and leading prefix assignments.
	-- Parse an array literal `( elem elem … )` with `i` positioned ON the `(`.
	-- Each element is `value` or `[sub]=value` / `[sub]+=value`; the subscript may
	-- nest brackets (`[a[0]]=x`). Consumes through the closing `)`.
	local parse_array_elems0
	-- (bash's parse_compound_assignment: a word inside that fails to read — an unclosed
	-- quote, backquote or ${ — is parse_string_error: status 1 and a DISCARD, as the
	-- literal's own unclosed `)`)
	local function parse_array_elems()
		local ok, r, ltext = pcall(parse_array_elems0) -- (ltext: the literal's text — keep it)
		if ok then
			return r, ltext
		end
		if type(r) == "table" and r.__curse_perr and not r.status
			and tostring(r.msg or ""):find("^unexpected EOF while looking for matching") then
			r.status, r.discard = 1, true
		elseif type(r) == "string" and r:find("unexpected EOF while looking for matching", 1, true) then
			arrlit_eof = true -- (the line's parse_error takes status 1 + DISCARD: next_line)
		end
		error(r, 0)
	end
	parse_array_elems0 = function()
		i = i + 1
		local elems = {}
		local toks = {} -- (each element's token as read: bash's parse_compound_assignment joins
		-- them with single blanks, comments and newlines dropped — the literal's text)
		local line0, closed = line, false
		while i <= n do
			skipsep() -- (newlines, comments: a word never starts at a `#` here)
			local c = src:sub(i, i)
			if c == ")" then
				i = i + 1
				closed = true
				break
			end
			if c == "" then
				break
			elseif c == "&" or c == ";" or c == "|" or ((c == "<" or c == ">") and src:sub(i + 1, i + 1) ~= "(") then
				-- a control operator inside the list (`a=(x & y)`): bash's recoverable
				-- syntax error at that token, which discards the rest of the LINE — later
				-- lines of a multi-line literal then parse as ordinary commands (bash)
				-- (the token is the whole operator: `<>`, `>>`, `&&`, …)
				local tok = src:match("^[<>]+", i) or src:match("^[&|;][&|;]?", i) or c
				i = src:find("\n", i, true) or n + 1
				error({ __curse_arraylit = true, tok = tok })
			elseif c == "(" then
				-- an ELEMENT can't be `(` (a nested `()`, as in `a=( inside=() )`): bash
				-- reports a syntax error but the assignment is NON-fatal (the var stays
				-- unset, the script CONTINUES). Like an operator above, the error discards
				-- the rest of the LINE; raise a RECOVERABLE error the line-parser marks so.
				i = src:find("\n", i, true) or n + 1
				error({ __curse_arraylit = true })
			else
				-- `[foo bar]=v`: a subscript is read as one unit, blanks and all, when a
				-- `=`/`+=` follows its closing `]` (bash's compound-assignment reader)
				-- A word that starts with `[` is read through its matching `]` as one unit —
				-- blanks, newlines, even `)` and all (bash's parse_matched_pair in a compound
				-- assignment): `[foo bar]=v`, or a bare `[2 3]` element. No `]` before EOF is a
				-- syntax error (status 1), reported at the `[`'s line.
				local pre = ""
				if c == "[" then
					local depth, k = 0, i
					while k <= n do
						local e = brace_skip(src, k) -- (quoted text, `…`, $( … ): no brackets)
						if e then
							k = e
						else
							local ch = src:byte(k)
							if ch == 91 then
								depth = depth + 1
							elseif ch == 93 then
								depth = depth - 1
								if depth == 0 then
									break
								end
							end
							k = k + 1
						end
					end
					if src:sub(k, k) ~= "]" or k > n then
						error({ __curse_perr = true, line = line, status = 1,
							msg = "unexpected EOF while looking for matching `]'" })
					end
					pre = src:sub(i, k)
					for p in pre:gmatch("()\n") do
						if not (alias_nl and alias_nl[i + p - 1]) then line = line + 1 end
					end
					i = k + 1
				end
				-- (the word goes on past the `]` only if no blank/metachar ends it there)
				local more = pre == "" or not src:sub(i, i):match("^[%s;&|<>()]?$")
				local w = pre .. (more and word(true) or "")
				if w == "" then
					break
				end
				toks[#toks + 1] = w
				local keyraw, eop, rhs = nil, "=", w
				if w:sub(1, 1) == "[" then
					local close = subscript_close(w, 1)
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
					if factors and count_str(rhs) > BRACE_CAP then -- (huge: expanded as it runs)
						local lw = elem_word(parse_word(rhs))
						lw.bxlazy, lw.bxelem = rhs, true
						elems[#elems + 1] = { key = nil, op = "=", word = lw, bxlazy = rhs }
					elseif factors then
						stream_factors(factors, function(x)
							local bw = elem_word(bq_word(x))
							elems[#elems + 1] = { key = nil, op = "=", word = bw }
						end)
					else
						local bw = elem_word(parse_word(rhs))
						elems[#elems + 1] = { key = nil, op = "=", word = bw }
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
					if factors and count_str(w) > BRACE_CAP then -- (huge: expanded as it runs)
						elem.brace_lazy = w
					elseif factors then
						elem.brace_bare = {}
						stream_factors(factors, function(x)
							local bw = elem_word(bq_word(x))
							elem.brace_bare[#elem.brace_bare + 1] = bw
						end)
					end
					elems[#elems + 1] = elem
				end
			end
		end
		if not closed then -- (never closed: bash's error, at the line it began on — status 1,
			-- and a DISCARD: an eval'd one ends a subshell)
			comsub_eof = false
			-- (exactmsg: its own msgid, not the `%c' one the others share — translated as
			-- such when reported, rt.L)
			error({ __curse_perr = true, line = line0, status = 1, discard = true, exactmsg = true,
				msg = "unexpected EOF while looking for matching `)'" }, 0)
		end
		return elems, "(" .. table.concat(toks, " ") .. ")"
	end

	local function try_assign()
		local name = src:match("^([%a_][%w_]*)", i)
		if not name then
			return nil
		end
		local p = i + #name
		local subidx = nil
		if src:sub(p, p) == "[" then
			-- (the key may nest: `a[${b[i]}]=`, `A[']']=10` has the key `]`)
			local q = subscript_close(src, p)
			if q and src:sub(q + 1, q + 1):match("[+=]") then
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
			local elems, ltext = parse_array_elems()
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
				raw = ltext, -- (normalized as bash's parser rebuilds it: `(1 2)` for `( 1\n 2 )`)
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
		if not subidx and op == "=" and raw:sub(1, 3) == "$((" and raw:sub(-2) == "))"
			and dparen_close(raw, 4) == #raw - 1 then -- (the `))` at the end closes THIS `$((`:
			-- not `$((()))$(())`)
			-- (a bad expression — or `$((1))$((2))` — takes the word path: its error is a
			-- runtime one, reported when the assignment runs)
			local aok, ae = pcall(arith, raw:sub(4, -3))
			if not aok then
				trap_flow(ae)
			end
			if aok then
				return { t = "assign", name = name, arith = ae, rhssrc = raw } -- (rhssrc: declare -f)
			end
		end
		return { t = "assign", name = name, index = subidx, append = (op == "+="), rhs = parse_word(raw) }
	end

	parse_command = function()
		ws()
		-- expand a leading alias in place (handles a compound-command alias like LEFT='{'
		-- before dispatch; the command-word case with leading assignments/redirects re-runs
		-- in the simple loop; astk's guard keeps a self-referential alias from looping).
		if cmd_prex == i then
			cmd_prex = nil -- parse_stmts already expanded this command word
		else
			try_alias(true)
		end
		-- an alias that expanded to a comment (`alias c=#`): the rest of the line is a comment
		-- and there is NO command ($? unchanged)
		if src:sub(i, i) == "#" then
			i = src:find("\n", i, true) or n + 1
			return { t = "noop", line = line }
		end
		local dstart, dline = i, line -- byte offset + line where this command (hence a funcdef) begins
		-- coproc [NAME] compound-command | coproc simple-command: an async command wired to
		-- the shell by two pipes. A NAME (default COPROC) is only allowed before a COMPOUND
		-- command — before a simple one, that word is the command (bash).
		if peekword() == "coproc" and not src:find("^[^ \t\n;&|()<>]", i + 6) and src:sub(i, i + 5) == "coproc" then
			local k = i + 6
			while is_blank(src:sub(k, k)) do
				k = k + 1
			end
			local c = src:sub(k, k)
			if c == "" or c == "\n" or c == ";" or c == "&" or c == "|" or c == ")" then -- (no command)
				local tok = c == "" and "newline" or c == "\n" and "newline" or src:match("^[;&|]+", k) or c
				error("syntax error near `" .. tok .. "'")
			end
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
				local s, e = src:find("^[^ \t\n;&|()<>]+", i)
				-- (an assignment word is never the NAME: it starts a simple command)
				if s and not src:find("^[%a_][%w_]*%+?=", s) and not src:find("^[%a_][%w_]*%b[]%+?=", s) then
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
			if s and src:sub(e + 1, e + 1):match("[$'\"\\`]") or not s and src:sub(i, i):match("[$'\"\\`]") then
				s, e = i, raw_word_end(i) - 1 -- (a quoted/expanded NAME: reported when it runs)
			end
			if not s then
				if i > n then -- (the input's final newline is the token: bash)
					error("syntax error near `newline'")
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
			-- bash is lenient about funcdef names: `=` is allowed (`func-name=ext () { … }`,
			-- `==x=()`), unless the name is an assignment word ending in `=` — an array/scalar
			-- assignment (`a=()`, `x=`), which the assignment path handles instead (and `a=(`
			-- is caught there before we get here anyway).
			-- (a leading `!` or `-` too — `!x() { …; }` names `!x`: a `!` only negates as a word
			-- of its own; `!()` is no name)
			local s, e = src:find("^[%w_:%.+@/%%%^~,!%-=][%w_%.%-:+@/!#=%%%^~,]*", i)
			if s == e and src:byte(s) == 33 then
				s = nil
			end
			if s and src:byte(e + 1) == 91 then -- (`a[1]()` names a function too; an unbalanced
				local _, e2 = src:find("^[%w_%.%-:+@/!#=%%%^~,%[%]]*", e + 1) -- `f[x` is left to the
				if src:sub(s, e2):find("^[^][]*%b[][^][]*$") then -- word reader)
					e = e2
				end
			end
			if s and not (src:byte(e) == 61 and (src:find("^[%a_][%w_]*%+?=", s) or src:find("^[%a_][%w_]*%b[]%+?=", s))) then
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
						-- (an assignment word — `c=d`, `a[1]+=x` — is ASSIGNMENT_WORD, never a
						-- function name: bash's grammar rejects the `(` after it)
						if nm:find("^[%a_][%w_]*%+?=") or nm:find("^[%a_][%w_]*%b[]%+?=") then
							error("syntax error near `('")
						end
						i = k + 1
						return funcdef_node(nm, dstart, dline)
					end
				end
			end
		end
		-- A funcdef whose "name" is an EXPANSION or QUOTED (`$foo-bar()`, `foo-$(x)()`,
		-- `'f'()`, `\h()`): to bash's grammar any WORD before `()` is a function name — it
		-- reports "`'f'': not a valid identifier" at RUNTIME (status 1), not a parse error.
		-- Scan the word (quotes and expansions whole); if it has a `$`, a quote or a `\`
		-- and `()` follows, it's a funcdef with that (invalid) name.
		local d1 = src:find("[$'\"\\` \t\n(;&|<>]", i) -- (none before the word ends: can't be one)
		if d1 and src:sub(d1, d1):match("[$'\"\\`]") then
			local j = raw_word_end(i)
			if j > i and src:sub(i, j - 1):find("[$'\"\\`]") then
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
				if src:byte(ni - 1) ~= 41 then
					-- `for ((…)` closed by a lone `)`: bash's parse_dparen fails and its re-read
					-- as `(` tokens stops at the word after the `)`, else at the header's tail
					local nx = src:match("^[ \t]*([^ \t\n;&|()<>]+)", ni - 1)
					error({ __curse_perr = true, exact = true, line = line, msg = "syntax error near `"
						.. (nx or ((body:match(".*(;.*)$") or ("((" .. body)) .. ")")) .. "'" }, 0)
				end
				-- (the header's own newlines: bash's lexer counts them as it reads the `((…))`)
				line = line + select(2, src:sub(i + 2, ni - 1):gsub("\n", ""))
				i = ni
				-- split the header at its top-level `;`s — not inside quotes, $(…), ${…}
				local slots = split_top(body, ";")
				local a, b, c = slots[1], slots[2], slots[3]
				loopId = loopId + 1
				local id = loopId
				local h1 = i -- (past the header: a hot loop's fragment re-states it without init)
				local body_stmts = loop_body()
				if #slots ~= 3 then -- (bash then shows the whole `(( … ))'; only once the body is read)
					error({
						__curse_perr = true,
						msg = #slots < 3 and "syntax error: arithmetic expression required" or "syntax error: `;' unexpected",
						text = "((" .. body .. "))",
					})
				end
				local s1 = i - 1
				-- Parse each arith slot eagerly, but a SYNTAX ERROR in a slot (`i='3'`,
				-- `++'i'`) is deferred to runtime — bash reports such an error when the loop
				-- executes and runs zero iterations non-fatally, rather than failing to parse
				-- the whole script (same rule as `$((…))`). A clean parse is unchanged.
				local function parith(s)
					if not s:match("[^ \t]") then -- (make_arith_for_expr skips only blanks: a slot of
						-- just a newline is an expression, evaluating to 0)
						return nil
					end
					-- (its leading blanks skipped, as make_arith_for_expr: a bad substitution in
					-- it names `i = ${} `, not `  i = ${} `)
					local ok, ast = pcall(arith, (s:gsub("^[ \t]+", "")))
					if not ok then
						trap_flow(ast)
					end
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
					_pst = pst_now(),
					_h1 = h1,
					_s1 = s1,
				}
			end
			-- for NAME in WORDS. Capture NAME as a whole token (not just a valid
			-- identifier): bash accepts `for i.j`/`for -` at PARSE time and reports the
			-- invalid name as a non-fatal RUNTIME error (status 1), so the interp checks.
			-- (each header word can come from a trailing-blank alias chain: `FOR eye IN …`)
			try_alias(false)
			local s, e = src:find("^[^%s;#()&|<>]+", i)
			if not s then -- (bash: the token found instead of a name)
				if i > n then -- (the input's final newline is the token: bash)
					error("syntax error near `newline'")
				end
				-- (a comment runs to the newline, which is the token: `for  #3`)
				error("syntax error near `" .. op_token(i) .. "'")
			end
			local name = src:sub(s, e)
			i = e + 1
			-- bash allows blank lines / comments between the loop var and `in` (but a
			-- `;` terminates the header — `for i;` iterates "$@").
			skipsep()
			local words = {}
			try_alias(false)
			do -- (after the name: `in`, `do`, or a separator — `for x y` is an error)
				local pw, c = peekword() or src:match("^[^ \t\n;&|()<>]+", i), src:sub(i, i)
				-- (a redirection / `;;` there: bash's token is the whole operator — `>&`, `;;`)
				local op = (c == "<" or c == ">" or src:sub(i, i + 1) == "&>" or src:sub(i, i + 1) == ";;")
					and (src:match("^<<<", i) or src:match("^<<%-", i) or src:match("^&>>", i) or src:match("^;;&", i)
						or src:match("^[<>]%(", i) and src:sub(i, scan_cmdsub(src, i + 2) - 1) -- (an open one: its EOF)
						or src:match("^<[<&>]", i) or src:match("^>[>&|]", i)
						or src:match("^&>", i) or src:match("^;;", i) or c)
				if op then
					error("syntax error near `" .. op .. "'")
				end
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
					-- (a `do` here is a word of the list: only a `;` or newline ends it —
					-- `for i in a do :; done` is bash's syntax error at `done')
					-- an unquoted bare `(` in word position is a syntax error (`for x in a=()`,
					-- `for x in (`); extglob/$()/<() are consumed inside word(true).
					if c == "(" or c == ")" then
						error("syntax error near `" .. c .. "'")
					end
					local w = word(true)
					if w == "" then
						break
					end
					add_word(words, w, true)
				end
			else
				words = { parse_word('"$@"') } -- `for NAME; do …` iterates the positional params
			end
			loopId = loopId + 1
			local id = loopId
			local sjcx = jcx
			jcx = { l = ln }
			local body_stmts = loop_body()
			jcx = sjcx
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
				_pst = pst_now(),
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
				_pst = pst_now(),
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
			local j, d = dparen_close(src, i + 2)
			if not j and d == 0 then -- (`(( 1 +` never closed: bash's arithmetic EOF error)
				dparen_close(src, i + 2, true) -- (a quote left open in it: that one's)
				comsub_eof = false
				eof_error(src, i, ")")
			end
			if j and src:byte(j + 1) == 41 then
				local body = src:sub(i + 2, j - 1)
				i = j + 2
				-- bash's make_arith_command stamps the line the `))` closed on (its lexer has
				-- counted the body's newlines by then): $LINENO and error lines use it
				line = line + select(2, body:gsub("\n", ""))
				-- a malformed `(( expr ))` (bad lvalue) is a NON-fatal runtime error in bash,
				-- so defer the parse failure to eval (caught by the arithcmd handler) rather
				-- than aborting the whole parse.
				local ok, e = pcall(arith, body)
				if not ok then
					trap_flow(e)
				end
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
		if src:sub(i, i + 1) == "[[" and (is_blank(src:sub(i + 2, i + 2)) or src:sub(i + 2, i + 2) == "\n" or i + 2 > n) then
			i = i + 2
			local line0, closed = line, false
			local toks, quoted, nlb, tp, tl = {}, {}, {}, {}, {} -- (tp/tl: each token's position/line)
			-- (a word that runs into the end of input — an unclosed quote — is an error only
			-- when bash's cond parser READS it: a grammar error on an earlier token wins)
			local pend_err
			while true do
				ws()
				tp[#toks + 1], tl[#toks + 1] = i, line
				if src:sub(i, i) == "\n" then
					nlb[#toks + 1] = nlb[#toks + 1] or { i, line } -- (the first newline before it)
					newline() -- continuation inside [[ ]]
				elseif i > n or src:sub(i, i + 1) == "]]" then
					if src:sub(i, i + 1) == "]]" then
						i = i + 2
						closed = true
					else -- (the input's end reads as a newline first: an eval string's, a file's last line)
						nlb[#toks + 1] = nlb[#toks + 1] or { n + 1, line }
					end
					break
				elseif toks[#toks] == "=~" then
					-- the =~ operand is ONE regex word (read_token_word under PST_REGEXP): it ends
					-- at a metacharacter — blank, newline, `;` `&` `<` `>` `)` — except inside a
					-- `( … )` group, read whole as parse_matched_pair does (blanks and metachars
					-- in it are kept: `([a b])`); `|` is an ordinary character. A `[ … ]` bracket
					-- class shields nothing (`[a b]` splits, `[^;]` ends at the `;`) and `]]` is
					-- COND_END only as a word of its own (`[[:space:]]`, `a\ ]]` are one word).
					local rs, pd, po = i, 0, {}
					while i <= n do
						local c0 = src:sub(i, i)
						if pd == 0 and c0:match("[ \t\n;&<>)]") then
							break
						end
						if c0 == "\\" then
							i = i + 2
						elseif c0 == "'" or c0 == '"' then
							i = quote_end(src, i, c0 == '"')
						elseif c0 == "(" then
							pd = pd + 1
							po[pd] = i
							i = i + 1
						elseif c0 == ")" then
							pd = pd - 1
							i = i + 1
						else
							i = i + 1
						end
					end
					if pd > 0 then -- (a group never closed: parse_matched_pair's EOF error, read
						pend_err = select(2, pcall(eof_error, src, po[1], ")")) -- by the grammar)
						toks[#toks + 1] = COND_PEND
						quoted[#toks] = false
						break
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
					if not (sh or xg == false) then
						xg_guess = true
					end
					quoted[#toks] = false
					i = i + 1
				else
					local before = i
					-- (bash reads an extglob pattern in [[ ]] only after `==`/`=`/`!=` — PST_EXTPAT —
					-- or with extglob on as the line is read: `[[ x -le @(a|b) ]]` is `@` then `(`)
					local lt = toks[#toks]
					local pat = (lt == "==" or lt == "=" or lt == "!=") and not quoted[#toks]
					local wok, w = pcall(word, true, true, pat) -- split on <,>,(,) operators (no spaces needed in [[ ]])
					if not wok then
						if type(w) == "string" and w:find("unexpected EOF while looking for matching", 1, true) then
							pend_err = w
							toks[#toks + 1] = COND_PEND
							quoted[#toks] = false
							break
						end
						error(w, 0)
					end
					if w == "" then
						-- word() stalled on a self-delimiting metacharacter. `&&`/`||` are
						-- two-char operator tokens; `(`, `)`, `<`, `>`, `;`, … are one char
						-- (each becomes its own token so the tokenizer makes progress).
						if i == before then -- (the shell's operator tokens, whole: `>|` `<&` `;;` …)
							w = src:match("^<<<", i) or src:match("^<<%-", i) or src:match("^&>>", i)
								or src:match("^;;&", i) or src:match("^[<>]%(", i) and src:sub(i, i)
								or src:match("^<[<&>]", i) or src:match("^>[>&|]", i) or src:match("^&[&>]", i)
								or src:match("^|[|&]", i) or src:match("^;[;&]", i) or src:sub(i, i)
							i = i + #w
						else
							break
						end
					end
					local c1 = w:sub(1, 1)
					toks[#toks + 1] = w
					quoted[#toks] = (c1 == '"' or c1 == "'")
				end
			end
			local cok, cerr = pcall(cond_check, toks, quoted, nlb, not closed, line0, tl)
			if pend_err and (cok or (type(cerr) == "table" and cerr.eof)) then
				error(pend_err, 0) -- (the grammar took the unclosed word as it was: the quote's error)
			end
			if pend_err and not cok and type(cerr) == "table" and cerr.pend then
				-- the grammar READ the failed word (bash's error token): parse_matched_pair's
				-- EOF message at the quote's line, then cond_term's own — at the end of input
				-- (the quote swallowed the rest; a missing final newline is supplied) — and no
				-- `syntax error near` line
				local ptl = tl[#toks] -- (the failed word's line)
				local eofl = ptl + select(2, src:sub(tp[#toks]):gsub("\n", "")) + (src:sub(-1) == "\n" and 0 or 1)
				local out = { { (pend_err:gsub("^.-:%d+: ", "")), ptl } }
				for _, m in ipairs(cerr.pre or {}) do
					out[#out + 1] = type(m) == "table" and m or { m, eofl }
				end
				error({ __curse_perr = true, pre = out, nomsg = true, line = eofl, msg = "" }, 0)
			end
			if not cok then -- (reported at the failing token: its line, shown as the input line)
				local k = type(cerr) == "table" and cerr.fk
				if type(cerr) == "table" and cerr.eof then
					i = n + 1
				elseif k then
					local at = k < 0 and nlb[-k] or (tp[k] and { tp[k], tl[k] })
					if at then
						i, line = at[1], at[2]
						cerr.line = line
					end
					-- (bash names the offending token from the input TEXT, not the token:
					-- error_token_from_text reads back from where the lexer stopped — just past
					-- it — to a blank or one of `;|&`: `]];` reads as `;`, `]]>f` as `]]>`,
					-- `&&` as `&`)
					local tk = k > 0 and (toks[k] or (k == #toks + 1 and closed and "]]"))
					if tk and cerr.exact then
						local j = tp[k] + #tk - 1 -- (the token's last char…)
						if not is_blank(src:sub(j + 1, j + 1)) and src:sub(j + 1, j + 1) ~= "\n" and j < n then
							j = j + 1 -- (…or the metachar the lexer stopped on)
						end
						local b = j
						while b > 1 and not (" \n\t;|&"):find(src:sub(b, b), 1, true) do
							b = b - 1
						end
						if b < j and (" \n\t"):find(src:sub(b, b), 1, true) then
							b = b + 1
						end
						cerr.msg = "syntax error near `" .. src:sub(b, j) .. "'"
					end
				end
				error(cerr, 0)
			end
			return { t = "dbracket", line = line, expr = parse_dbracket(toks, quoted), redirs = tail_redirs() }
		end
		-- brace group { list; }  and subshell ( list )  — optional trailing redirs
		if src:sub(i, i) == "{" and (i + 1 > n or src:find("^[ \t\n;&|()<>]", i + 1)) then
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
			local sjcx = jcx
			jcx = {}
			local body, pterm = parse_stmts({ [")"] = true })
			jcx.l, jcx = line, sjcx -- (bash's subshell->line: where it closes)
			if pterm ~= ")" then
				error("syntax error: unexpected end of file") -- unclosed ( )
			end
			if #body == 0 then
				error("syntax error near `)'") -- (`( )`: bash)
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
			M.mark_tail(body, true)
			return { t = "subshell", line = line, body = body, redirs = (#redirs > 0 and redirs or nil), jcx = jcx }
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
				error("syntax error near `" .. ((c == "\n" or c == "") and "newline" or c) .. "'")
			end
			local subject = parse_word(subw)
			skipsep()
			if peekword() == "in" then
				i = i + 2
				jcx = { l = ln, up = jcx } -- (its clauses: `up` restores it after — see below)
			else -- (bash: the token that isn't `in`)
				if i > n then -- (newlines may come before `in`: the input just ended)
					error("syntax error: unexpected end of file")
				end
				local l0 = line
				local w = word(true)
				line = l0
				error("syntax error near `" .. (w ~= "" and w or src:match("^[;&|<>]+", i) or src:sub(i, i)) .. "'")
			end -- ysh `case (x) { }` etc. rejected
			-- separator skipper that STOPS at a clause's ;; / ;;& / ;& (-> it; at EOF "eof")
			-- (semi_ok: one `;` may end the statement just read; anywhere else — a clause's
			-- start, after a newline — a `;` is an empty command, bash's syntax error)
			local function skip_sep(semi_ok)
				while true do
					if skipsep() then
						semi_ok = false
					end
					local t = src:match("^;;&", i) or src:match("^;[;&]", i)
					if t or i > n then
						return t or "eof"
					elseif src:byte(i) ~= 59 then
						return nil
					elseif not semi_ok then
						error("syntax error near `;'")
					end
					semi_ok = false
					i = i + 1
				end
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
				-- the patterns: words (read like any other — quotes, expansions and an extglob
				-- group are part of one, so their `|` and `)` are too) joined by `|`, up to the
				-- clause's `)`. Anything else there is bash's syntax error at that token: `a|)`,
				-- `|a)`, `)`, `x|(z)`, `a;;esac`, `a&)`, `a b)`, a `(` without extglob.
				local pats = {}
				while true do
					local pw = word(true)
					ws()
					local c = src:sub(i, i)
					if pw == "" or not (c == ")" or c == "|" and not src:find("^[|&]", i + 1)) then
						local tok = (c == "\n" or c == "") and "newline" or src:match("^;;&", i) or src:match("^;[;&]", i)
							or src:match("^|[|&]", i) or src:match("^&[&>]", i)
							or pw ~= "" and src:match("^[^ \t\n;&|()<>]+", i) or c
						error("syntax error near `" .. tok .. "'")
					end
					pats[#pats + 1] = pw
					i = i + 1
					if c == ")" then
						break
					end
				end
				local body, term = {}, "break"
				local svs = cur_stopset
				cur_stopset = { esac = true } -- (a clause body may run straight into `esac`)
				local semi_ok = false
				while true do
					local s = skip_sep(semi_ok)
					if CASE_TERM[s] then
						i = i + #s
						term = CASE_TERM[s]
						break
					end
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
					semi_ok = true
				end
				cur_stopset = svs
				clauses[#clauses + 1] = { pats = pats, body = body, term = term }
			end
			jcx = jcx.up
			return { t = "case", line = ln, subject = subject, clauses = clauses, redirs = tail_redirs() }
		end

		-- leading assignments AND redirects (bash allows them interleaved before the
		-- command: `FOO=1 >f BAR=2 cmd`), forming the prefix for a following command,
		-- else a bare assignment/redirection statement.
		local ln = line
		local assigns = {}
		local redirs = {}
		-- cline: the line a simple command runs "at", which its $(…) bodies number from —
		-- where bash's yacc reduced its first element: past a leading assignment/redirect
		-- (a default reduction), but only once the SECOND token is read after a leading
		-- WORD (the lookahead that rules out `WORD ( )`, a funcdef)
		local cline
		while true do
			-- (the reduction takes no lookahead: the line the first element ENDED on, before
			-- a `\<newline>` after it is read — `x=1 \<newline>y=$(echo $LINENO)` is line 1)
			if not cline and #assigns + #redirs >= 1 then
				cline = line
			end
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

		-- At command position (bash's assignment_acceptable), a word that is a NAME so far then
		-- `[` reads the subscript as parse_matched_pair's P_ARRAYSUB group — blanks, `;`, quotes
		-- included — whether or not an `=` follows (`a[b c]x` is one word, a command name);
		-- never closed: bash's "unexpected EOF while looking for matching `]'"
		do
			local bs = src:match("^[%a_][%w_]*()%[", i)
			if bs then
				word_sub = { src = src, at = i, close = bracket_close(src, bs, false, true) }
			end
		end

		-- a keyword that only closes/continues a compound command, reaching command
		-- position on its own (or a bare `}`), is a misplaced-token syntax error.
		do
			local MISPLACED =
				{ ["then"] = 1, ["else"] = 1, ["elif"] = 1, ["fi"] = 1, ["do"] = 1, ["done"] = 1, ["esac"] = 1, ["in"] = 1 }
			-- (after an assignment or redirection prefix nothing is a reserved word: `>f }`
			-- runs a command named `}` — bash)
			local noprefix = #assigns + #redirs == 0
			local pwm = noprefix and peekword()
			-- (`}` and `]]` are whole tokens up to any metacharacter: `}(x`, `]]>f` — bash)
			local cb = noprefix and not pwm and (src:match("^}()", i) or src:match("^%]%]()", i))
			if cb and cb <= n and not src:sub(cb, cb):match("[ \t\n;&|()<>]") then
				cb = nil
			end
			if noprefix and (MISPLACED[pwm] or cb) then
				error("syntax error near `" .. (pwm or src:sub(i, cb - 1)) .. "'")
			end
		end
		-- simple command: WORD WORD ...
		local words = {}
		local arrayargs = nil -- `NAME=(...)` args to a declaration builtin
		while i <= n do
			if not cline and #words + #assigns + #redirs >= 2 then
				cline = line
			end
			local c = src:sub(i, i)
			local rl = line
			local r = parse_redir() -- also catches &> before the & break below
			if r then
				-- (the lookahead after a lone WORD is the redirection's OPERATOR: the line
				-- it's on, however many lines its word runs on — `cat <<${a⏎b}`)
				if not cline and #words + #assigns + #redirs == 1 then
					cline = rl
				end
				redirs[#redirs + 1] = r
			elseif c == "(" and (#words > 0 or #assigns > 0 or #redirs > 0) then
				-- a bare single `(` after a command word isn't a subshell — `ls foo=(1 2)`,
				-- `builtin typeset a=(…)`, `echo a(b)` are syntax errors in bash. Likewise a
				-- `(` after an assignment prefix with a space: `a= (1 2)` is a syntax error
				-- (the `(` can't be a command word there; `a=(1 2)` with no space is an
				-- array assignment, parsed earlier). (extglob @(…), $(…), <(…) are consumed
				-- inside word(); a `((` there is no arithmetic command either: `echo a ((1))`,
				-- `echo $$((1))` — `$$` is a token of its own — are the same error.)
				if #words == 1 and #assigns == 0 and #redirs == 0 then
					-- (a lone word then `(` began a `NAME ( )` funcdef: bash wanted the `)`)
					local k = i + 1
					while is_blank(src:sub(k, k)) do
						k = k + 1
					end
					-- (a word there is read whole first — an unclosed `$(` in it is ITS error,
					-- `+($(x` — and named as written: `f ($(x) y)` names `$(x)`)
					if k <= n and not src:sub(k, k):match("[\n;&|()<>#]") then
						i = k
						local w = word(true)
						if w ~= "" then
							error("syntax error near `" .. w .. "'")
						end
					end
					error("syntax error near `" .. op_token(k) .. "'")
				end
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
					local elems, ltext = parse_array_elems()
					-- (src/pos: the arg as bash's parser rebuilds it — `(x y)` for `(  x  y )` — and
					-- where it sat among the words, for `declare -f`)
					arrayargs[#arrayargs + 1] = { name = an, elems = elems, append = (ap == "+"),
						src = ltext and (an .. ap .. "=" .. ltext) or src:sub(a0, i - 1), pos = #words + 1 }
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
								i = quote_end(src, i, ch == '"') - 1 -- (its closing quote)
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
					add_word(words, w, true)
				end
			end
		end
		if #words == 0 and #redirs == 0 then
			-- no command: the leading assignments are plain (persistent) statements
			if #assigns == 0 then
				return nil
			end
			if #assigns == 1 then
				-- (a lone assignment runs at the line it ENDED: bash's lookahead was the
				-- newline after it — its $(…)/`…` bodies number from there)
				local a = assigns[1]
				if line ~= (a.line or ln) then
					a.cline = line
				end
				return a
			end
			cline = cline or line
			if cline ~= ln then -- (each binding runs at the list's line: its bodies number from it)
				for k = 1, #assigns do
					assigns[k].cline = cline
				end
			end
			return { t = "assignlist", line = ln, cline = cline ~= ln and cline or nil, list = assigns }
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
					words[k] = { k = w.k, parts = w.parts, src = w.src, plainarg = true, plain = w.plain, bx = w.bx, bxlazy = w.bxlazy }
				end
			end
		end
		cline = cline or line
		if cline ~= ln then -- (its prefix bindings run at that line too)
			for k = 1, #assigns do
				assigns[k].cline = cline
			end
		end
		local node = {
			t = "simple",
			line = ln,
			cline = cline ~= ln and cline or nil,
			words = words,
			redirs = (#redirs > 0 and redirs or nil),
			assigns = (#assigns > 0 and assigns or nil),
			arrayargs = arrayargs,
			jcx = jcx,
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
		local t = bare_sep_tok() or src:sub(i, i) == ")" and ")"
		if t then
			error("syntax error near `" .. t .. "'")
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
			-- (outside posix mode a reserved word is recognized AFTER alias expansion:
			-- `alias bang='!'` negates — parse.y's read_token_word)
			if cmd_prex ~= i then
				try_alias(true)
				cmd_prex = i
			end
			if time_at(i) then
				timed = true
				i = i + 4
				ws()
				while src:sub(i, i + 1) == "-p" and not src:find("^[^ \t\n;&|()<>]", i + 2) do
					timed_p = true
					i = i + 2
					ws()
				end
				if src:sub(i, i + 1) == "--" and src:sub(i + 2, i + 2):match("^[ \t\n]?$") then
					-- `time -- cmd` / `time -p -- cmd`: the options end — parse.y's TIMEIGN,
					-- which also selects the POSIX format (CMD_TIME_POSIX)
					timed_p = true
					i = i + 2
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
			if not (sh or xg == false) then
				xg_guess = true
			end
			i = i + 1
		end
		-- a control operator where a command begins: bash's syntax error at that token (a
		-- case clause's body `x)|0`, `x)&&y` — parse_command would find no command there)
		do
			local bs = bare_sep_tok()
			if bs then
				error("syntax error near `" .. bs .. "'")
			end
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
				local w = src:match("^[^ \t\n;&|()<>]+", i)
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
				-- (a heredoc opened by the stage before this `|` has its body on the following
				-- lines: `cat <<EOF |` <newline> body EOF <newline> next)
				skipsep()
				operand_check()
				if bang_at(i) then -- (`!` only starts a pipeline: bash's grammar)
					error("syntax error near `!'")
				end
				cmds[#cmds + 1] = parse_command()
			else
				break
			end
		end
		local pipe = (#cmds == 1 and not negate) and first
			or { t = "pipeline", cmds = cmds, negate = negate, line = ln, jcx = jcx }
		if timed then
			pipe.timed = true
			pipe.timed_p = timed_p
		end -- `time` prefix: measure this pipeline
		if #cmds == 1 and first.t == "subshell" and (timed or negate) then
			M.untail(pipe, first, timed, timed_p)
		end
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
				skipsep()
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
			skipsep()
			if i > n then
				return stmts, nil
			end
			if next(stopset) ~= nil and cmd_prex ~= i then
				-- the command word may be an alias for the terminator (`alias DONE='}'`):
				-- expand it before looking for one; parse_command then won't re-expand
				try_alias(true)
				cmd_prex = i
			end
			if stopset["}"] and src:sub(i, i) == "}" and not src:find("^[^ \t\n;&|()<>]", i + 1) then
				i = i + 1 -- (a reserved word is a whole token: `}x`, `}\r` are ordinary words)
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
			-- parse_stmt/skipsep. A following `;` is then a bare separator (error).
			ws()
			if src:sub(i, i) == ";" and not src:find("^[;&]", i + 1) then -- (`;;`, `;&`: tokens)
				i = i + 1
				if st then
					st.semi = true -- (as at the top level: deparse's comsubs keep the newlines)
				end
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
	-- Yield one LOGICAL LINE at a time: a complete `simple_list` — all the
	-- `;`/`&`/`&&`/`||`-joined and-or lists up to a top-level newline or EOF, as
	-- bash's `inputunit` does. Returns { stmts = {…}, perr = <parse_error>? } or nil.
	-- A `perr` means a syntax error was hit somewhere on the line, so the WHOLE line
	-- runs nothing (bash parses the entire line before executing any of it). The
	-- parser stays statement-lazy (parse_stmt consumes complete multi-line compounds
	-- and each stmt makes progress or errors), so there is no parse-ahead spin.
	local prev_end -- (the last line group's last line: the reader goes on at the next)
	local function next_line()
		if done then
			return nil
		end
		alias_line_start()
		skipsep() -- blank lines, comments, and pending heredocs
		if i > n then
			done = true
			return nil
		end
		local bs = bare_sep_tok() -- a leading control op (`;`, `&`, `||`, …) is an error
		if bs then
			done = true
			return perr_gather(true, { stmts = {}, perr = { t = "parse_error", line = line, msg = "syntax error near `" .. bs .. "'" } })
		end
		local stmts = {}
		local gstart, gline = i, line -- (where this logical line's text begins: its compiled-group key)
		jcx = {}
		while true do
			local start, startline = i, line
			arrlit_eof = false
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
				local atext = type(st) == "string" and astk_n > 0 and (st:match("near unexpected token `(.*)'$")
					or st:match("syntax error near `(.*)'$"))
				atext = atext and alias_line(i, atext)
				-- (…only when that token is where the line's list could end — the first of a
				-- command after complete ones: bash's reduction to simple_list gathers them;
				-- one inside an unfinished command — `cat <<E && ;` — reports first)
				local etok = not recover and type(st) == "string" and st:match("near `(.*)'$")
				local s0 = etok and src:match("^[ \t]*()", start)
				return perr_gather(etok and src:sub(s0, s0 + #etok - 1) == etok, {
					-- (bash's DISCARD: a recoverable error drops the whole line — what ran
					-- before it on the line too, as bash parses a line before running it)
					stmts = recover and {} or stmts,
					perr = {
						t = "parse_error",
						-- (a recoverable one, or a `near TOKEN` one: the token's line)
						line = (type(st) == "table" and st.__curse_perr and st.line)
							or (recover or (type(st) == "string" and (st:find("near `", 1, true)
								or st:find("near unexpected token `", 1, true)))) and line
							or (eof_s == src and eof_at >= start and type(st) == "string"
								and st:find("EOF while looking for matching", 1, true)) -- (where it opened)
								and startline + select(2, src:sub(start, eof_at - 1):gsub("\n", ""))
							or startline,
						msg = recover and ("syntax error near `" .. (st.tok or "(") .. "'")
							or (type(st) == "table" and st.__curse_perr and st.msg) or unpos(tostring(st)),
						status = type(st) == "table" and st.__curse_perr and st.status
							or (arrlit_eof and type(st) == "string" and 1) or nil, -- (else 2)
						pre = type(st) == "table" and st.__curse_perr and st.pre or nil, -- (messages before it)
						preline = type(st) == "table" and st.__curse_perr and st.preline or nil, -- (their line)
						exact = type(st) == "table" and st.__curse_perr and st.exact or nil, -- (msg verbatim)
						text = type(st) == "table" and st.__curse_perr and (st.text or st.ltext) or atext or nil, -- (ltext: the line shown, plainly)
						showtext = type(st) == "table" and st.__curse_perr and st.text and true or nil,
						recoverable = recover or nil,
						discard = type(st) == "table" and st.__curse_perr and st.discard
							or (arrlit_eof and type(st) == "string") or nil,
						forceeof = type(st) == "table" and st.__curse_perr and st.forceeof or nil,
						-- (parse_matched_pair's EOF error: parser_error, then the grammar's `error
						-- yacc_EOF` sets $? to 2 only when it's 0 — an open `$(`'s is reported as a
						-- syntax error, which always does)
						keepst = type(st) == "string" and st:find("EOF while looking for matching `", 1, true)
							and not (comsub_eof and st:find("matching `)'", 1, true)) or nil,
						exactmsg = type(st) == "table" and st.__curse_perr and st.exactmsg or nil, -- (its own msgid)
						nomsg = type(st) == "table" and st.__curse_perr and st.nomsg or nil, -- (its `pre` says it all)
					},
				})
			end
			-- No progress: a stray metacharacter/keyword in command position (`)`, `}`,
			-- `done`, `fi`, …). Report a syntax error (and guard against spinning).
			if i <= start then
				local tok = peekword() or src:sub(i, i)
				done = true -- stray keyword/metachar in command position: stop (no-progress guard)
				ws()
				return perr_gather(true, {
					stmts = stmts,
					perr = { t = "parse_error", line = line, msg = "syntax error near `" .. tok .. "'",
						text = alias_line(i, tok) },
				})
			end
			if st.t == "funcdef" or st.redirs then
				st.top = true -- (not nested in a compound: its errors report its END line)
			end
			stmts[#stmts + 1] = st
			ws()
			local c = src:sub(i, i)
			if st.t ~= "background" then
				-- foreground: a single `;` continues the line; `\n`/EOF/`#` end it cleanly.
				-- A bare separator here (`;;`, `|`) is a syntax error ON the line — bash runs
				-- nothing on it (`echo 1 ;; echo 2`). Anything else (`(`, `((`, `)`, `}`, a
				-- stray keyword) is left to the existing statement-boundary handling.
				if c == ";" and not src:find("^[;&]", i + 1) then -- (`;;`, `;&`: tokens)
					i = i + 1
					st.semi = true -- (`a;⏎b` joins with `;`, not a newline: deparse's comsubs)
					ws()
				elseif i > n or c == "\n" or c == "#" then
					break
				else
					-- a stray `)` ends nothing here: the whole line is a syntax error (bash
					-- runs none of `echo hi )`)
					local bsx = bare_sep_tok() or (c == ")" and ")") or nil
					if bsx then
						done = true
						return perr_gather(true, {
							stmts = stmts,
							perr = { t = "parse_error", line = line, msg = "syntax error near `" .. bsx .. "'" },
						})
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
				return perr_gather(true, {
					stmts = stmts,
					perr = { t = "parse_error", line = line, msg = "syntax error near `" .. bs2 .. "'" },
				})
			end
		end
		local eline = line -- (the command's last line: its terminating newline's)
		jcx.l = line -- (the top-level commands' job-report line: jcx — a heredoc's last)
		if #heredocs_pending > 0 then
			collect_heredocs()
			eline = line - 1 -- (the bodies' last line: the reader is past its newline)
			jcx.l = line - 1
		end -- read bodies after the line
		if #warns > 0 then
			for k = #warns, 1, -1 do
				table.insert(stmts, 1, warns[k])
			end
			warns = {}
		end
		-- (pos/pline: where reading stopped — a reader that takes over the rest of the
		-- input line by line, for command history, resumes there)
		-- (rline: the line bash's reader reads next after the previous group ran — where it
		-- notifies of jobs that ended meanwhile: rt.jobs_line)
		local rline = prev_end and prev_end + 1
		prev_end = eline
		return { stmts = stmts, pos = i, pline = line, src = src, spos = gstart, sline = gline, eline = eline,
			jcx = jcx, rline = rline }
	end
	-- a syntax error also reports the offending input line (bash's second message line)
	return function()
		local lg = next_line()
		if lg and xg_guess then
			lg.xg_guess, xg_guess = true, false
		end
		if lg and lg.perr and #warns > 0 then -- (warnings read before the error still show)
			lg.perr.warns = warns
			warns = {}
		end
		if lg and lg.perr then
			local m = tostring(lg.perr.msg or "")
			if m:find("unexpected end of file", 1, true) or (m:find("matching `)'", 1, true) and comsub_eof) then
				lg.perr.line = firstline - 1 + select(2, src:gsub("\n", "")) + (src:sub(-1) == "\n" and 1 or 2)
					+ (((src:match("(\\*)$") or ""):len() % 2 == 1) and 1 or 0) -- (a trailing `\` continues)
					+ (((src:match("(\\*)\n$") or ""):len() % 2 == 1) and 1 or 0) -- (…as does a last `\<newline>`)
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
-- (bq: `src` is a `…` body; cs: a $(…) body)
function M.parse(src, sh, aenv, noalias, posix, line0, line1, xg, bq, cs)
	local saved_env, sprex, spdq, sltr = ALIAS_ENV, COMSUB_PREX, POSIX_DQ, LTR_SEEN
	LTR_SEEN = false
	local nextf = make_parser(src, sh, aenv, noalias, posix, line0, line1, xg, bq, cs) -- yields logical-line groups { stmts, perr }
	local stmts, lines, xgg = {}, {}, nil
	while true do
		local lg = nextf()
		if not lg then
			break
		end
		lines[#lines + 1] = lg
		xgg = xgg or lg.xg_guess
		-- A syntax error on a line means the WHOLE line runs nothing (bash parses the
		-- line before executing any of it), so the parse_error goes BEFORE the line's
		-- own statements: a non-recoverable error then aborts (exit 2) before they run,
		-- and a recoverable one (bad array literal) reports + continues to them — the
		-- same order run_lazy uses, so the compiler and interpreter agree.
		local first = #stmts + 1
		if lg.perr then
			stmts[#stmts + 1] = lg.perr
		end
		for _, st in ipairs(lg.stmts) do
			stmts[#stmts + 1] = st
		end
		if stmts[first] then -- (the first statement of a line group: where a line abort resumes)
			stmts[first].lgstart = true
			stmts[first].lgread = lg.rline -- (rt.jobs_line's line)
			stmts[first].lgeline = lg.eline -- (the reader's line after it: rt.compound_line)
			if lg.eline and lg.sline and lg.eline > lg.sline then -- (its lines: rt.line_drift)
				stmts[first].lgspan = { lg.sline, lg.eline }
			end
		end
	end
	ALIAS_ENV, COMSUB_PREX, POSIX_DQ = saved_env, sprex, spdq
	-- (ltrans: a $"…" may be translated — by the live reader, as each line is read)
	local ltrans = LTR_SEEN or nil
	LTR_SEEN = sltr or LTR_SEEN
	local last = lines[#lines]
	return { stmts = stmts, lines = lines, ltrans = ltrans, xg_guess = xgg,
		eofline = last and last.eline and last.eline + 1 } -- (the reader's line at end of input)
end

-- Lazy/incremental parse: returns an iterator yielding one top-level statement
-- per call (nil at EOF). The interpreter uses this for instant start on large
-- scripts and to never tokenize past an `exit` (hybrid installers). `sh` (present
-- when interpreting) makes alias expansion use the live runtime alias table.
-- `line1`: the line the text's first line is (eval: the eval command's own line — bash
-- numbers eval'd code, and functions it defines, from there)
-- THE ONE ENTRY for text re-read at EXPANSION time (a ${…} operand, a subscript, a redirect
-- target, a case pattern, an arithmetic text's $…, a nameref's element, a prompt — raw text the
-- parser stored instead of a word tree). Every scanner here raises a syntax error as a Lua
-- string; at parse time the reader turns it into bash's syntax error, but a re-read happens
-- while a command RUNS, where a raw string error would escape as a Lua error (fuzz F2, F5, F48,
-- F53-F55: each was one more re-read site guarded on its own, the next one left open). So a
-- run-time re-read never calls parse_word/parse_default_quoted/parse_heredoc itself: it calls
-- this, which never raises a string — a construct the re-read finds left open becomes an error
-- PART, raised when the word expands after what precedes it (bash expands left to right):
-- extract_dollar_brace_string's "bad substitution: no closing `}' in WORD" (`]' for a $[),
-- else the scanner's own message. how: nil (a plain word), "dq" (a ${…} operand inside "…":
-- parse_default_quoted), "hd" (here-document-style text: parse_heredoc). …: the parse
-- function's further arguments.
function M.reword(txt, how, ...)
	local ok, w = pcall(how == "dq" and M.parse_default_quoted or how == "hd" and M.parse_heredoc or M.parse_word,
		txt, ...)
	if ok then
		return w
	end
	if type(w) ~= "string" then
		error(w, 0)
	end
	local m = unpos(w)
	local close = m:match("^unexpected EOF while looking for matching `([}%]])'$")
	return { k = "word", src = txt, parts = { close and { nulcut = txt, nocl = close == "]" and "]" or nil, q = true }
		or { xperr = m, q = true } } }
end

function M.open(src, sh, line1)
	return make_parser(src, sh, nil, nil, nil, nil, line1)
end
function M.open_full(...) -- (M.parse's arguments, read lazily: rt capture_src)
	return make_parser(...)
end

do -- (loaded after the locale was set: runtime's lc_commit keeps it current from here)
	local rt = package.loaded.runtime
	MBX = rt and rt.lc_mb_cur_max() > 1 and not rt.lc_utf8() and (rt.lc_state[0] or "?") or false
end

return M
