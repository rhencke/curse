-- Minimal bash parser for the initial LuaJIT-backend subset: assignments,
-- simple commands (echo …), `for (( init; cond; step ))`, `while (( cond ))`,
-- and arithmetic expressions. Produces an AST consumed by BOTH interp.lua and
-- emit.lua. The full grammar stays in the TS parser (the reference); this one
-- grows toward it. Loops get a stable numeric `id` so the tier layer can name a
-- resume safepoint.
local M = {}

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
  if src:match("^%s*$") then return { k = "num", v = "0" } end
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
  if not nodefer and (src:find("%${") or src:find("%$%(") or src:find("`")
      or src:find("[%w_]%$") or src:find("%$[^%w_{]")) then
    return { k = "xpand", raw = src }
  end
  -- bash strips matched double-quote PAIRS inside arithmetic (`$(( "1+2" * 3 ))`
  -- -> 1+2*3), keeping the content; a lone unmatched `"` is left in place so the
  -- tokenizer reports the error bash does. (Single quotes are never stripped.)
  if src:find('"', 1, true) then
    local o, open = {}, false
    for k = 1, #src do
      local ch = src:sub(k, k)
      if ch == '"' then
        if open then open = false          -- close of a pair: drop it
        elseif src:find('"', k + 1, true) then open = true -- open of a pair: drop it
        else o[#o + 1] = ch end            -- unmatched: keep (-> tokenizer errors)
      else o[#o + 1] = ch end
    end
    src = table.concat(o)
  end
  local i, n = 1, #src
  local function skip() while i <= n and src:sub(i, i):match("%s") do i = i + 1 end end
  local function peek() skip(); return src:sub(i, i) end
  local function starts(s) skip(); return src:sub(i, i + #s - 1) == s end
  local function eat(s) if starts(s) then i = i + #s; return true end return false end
  local parseExpr

  local function ident()
    skip()
    local s, e = src:find("^[%a_][%w_]*", i)
    if not s then error("arith: expected name at '" .. src:sub(i) .. "'") end
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
    local nm = ident()
    if starts("[") then
      local rs = i + 1
      local depth, j = 1, i + 1
      while j <= n and depth > 0 do
        local ch = src:sub(j, j)
        if ch == "[" then depth = depth + 1
        elseif ch == "]" then depth = depth - 1; if depth == 0 then break end end
        j = j + 1
      end
      if depth ~= 0 then error("arith: expected ]") end
      local raw = src:sub(rs, j - 1)
      i = j + 1 -- past the ]
      local ok, idx = pcall(arith, raw) -- may fail for a quoted/non-arith key
      return nm, (ok and idx) or nil, raw
    end
    return nm, nil, nil
  end

  local function primary()
    skip()
    local c = src:sub(i, i)
    if c == "(" then
      i = i + 1
      local e = parseComma()
      if not eat(")") then error("arith: expected )") end
      return e
    end
    if eat("++") then local nm, idx, ir = nameSub(); return { k = "pre", name = nm, idx = idx, idxraw = ir, d = 1 } end
    if eat("--") then local nm, idx, ir = nameSub(); return { k = "pre", name = nm, idx = idx, idxraw = ir, d = -1 } end
    if c == "-" then i = i + 1; return { k = "un", op = "-", e = primary() } end
    if c == "+" then i = i + 1; return primary() end
    if c == "!" then i = i + 1; return { k = "un", op = "!", e = primary() } end
    if c == "~" then i = i + 1; return { k = "un", op = "~", e = primary() } end
    if c == "$" then
      i = i + 1
      local d = src:sub(i, i)
      if d:match("%d") then i = i + 1; return { k = "param", n = tonumber(d) } end
      if d == "{" then
        local e = src:find("}", i + 1, true); local nm = src:sub(i + 1, e - 1); i = e + 1
        return { k = "var", name = nm }
      end
      return { k = "var", name = ident() } -- $name same as name in arith
    end
    if c:match("%d") then
      -- base#digits / 0xHEX / decimal-or-octal
      local s, e = src:find("^%d+#[%w@_]+", i)
      if not s then s, e = src:find("^0[xX]%x+", i) end
      if not s then s, e = src:find("^%d+", i) end
      local v = src:sub(s, e)
      -- a leading-0 literal is octal, so a digit 8/9 is invalid (bash: "value too
      -- great for base"); reject it here so $(( 083 )) is a syntax error, not 83.
      if v:match("^0%d") and not v:lower():match("^0x") and v:find("[89]") then
        error("arith: invalid octal constant '" .. v .. "'")
      end
      i = e + 1
      return { k = "num", v = v }
    end
    -- a name (optionally subscripted): a var, an assignment, or ++/--
    local name, idx, ir = nameSub()
    -- post ++/--
    if starts("++") then i = i + 2; return { k = "post", name = name, idx = idx, idxraw = ir, d = 1 } end
    if starts("--") then i = i + 2; return { k = "post", name = name, idx = idx, idxraw = ir, d = -1 } end
    -- assignment operators (3-char shifts before their 2-char prefixes)
    for _, op in ipairs({ "<<=", ">>=", "+=", "-=", "*=", "/=", "%=", "&=", "^=", "|=" }) do
      if starts(op) then i = i + #op; return { k = "asgn", name = name, idx = idx, idxraw = ir, op = op, e = parseExpr(0) } end
    end
    if starts("=") and src:sub(i + 1, i + 1) ~= "=" then
      i = i + 1; return { k = "asgn", name = name, idx = idx, idxraw = ir, op = "=", e = parseExpr(0) }
    end
    return { k = "var", name = name, idx = idx, idxraw = ir }
  end

  -- binary operators by precedence (higher binds tighter), matching bash
  local BIN = {
    ["||"] = 1, ["&&"] = 2,
    ["|"] = 3, ["^"] = 4, ["&"] = 5,
    ["=="] = 6, ["!="] = 6,
    ["<"] = 7, ["<="] = 7, [">"] = 7, [">="] = 7,
    ["<<"] = 8, [">>"] = 8,
    ["+"] = 9, ["-"] = 9, ["*"] = 10, ["/"] = 10, ["%"] = 10,
    ["**"] = 11,
  }
  -- longest-match order: multi-char ops before the single-char ones they prefix
  local OPS = { "**", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||",
    "<", ">", "+", "-", "*", "/", "%", "&", "^", "|" }

  local function nextOp()
    skip()
    for _, op in ipairs(OPS) do
      if src:sub(i, i + #op - 1) == op then
        -- don't consume assignment "=" as comparison; "=" alone handled in primary
        return op
      end
    end
    return nil
  end

  parseExpr = function(minprec)
    local left = primary()
    while true do
      local op = nextOp()
      if op == nil then break end
      local prec = BIN[op]
      if prec == nil or prec < minprec then break end
      i = i + #op
      local right = parseExpr(op == "**" and prec or prec + 1) -- ** is right-assoc
      left = { k = "bin", op = op, l = left, r = right }
    end
    -- ternary c ? a : b (lowest precedence, right-assoc) — only at the top level
    if minprec == 0 and peek() == "?" then
      i = i + 1
      local a = parseExpr(0)
      if not eat(":") then error("arith: expected : in ?:") end
      local b = parseExpr(0)
      left = { k = "tern", c = left, a = a, b = b }
    end
    return left
  end

  -- comma operator: evaluate left-to-right, value is the last (bash/C semantics)
  parseComma = function()
    local e = parseExpr(0)
    while peek() == "," do i = i + 1; e = { k = "comma", l = e, r = parseExpr(0) } end
    return e
  end

  local e = parseComma()
  skip()
  if i <= n then error("arith: trailing input '" .. src:sub(i) .. "'") end
  return e
end
M.arith = arith

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
    if c == "(" then d = d + 1; i = i + 1
    elseif c == ")" then
      if d == 0 then return src:sub(start, i - 1), i + 2 end -- the closing `))`
      d = d - 1; i = i + 1
    else i = i + 1 end
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
    if c == "\\" then i = i + 2
    elseif q then if c == q then q = nil end; i = i + 1
    elseif c == "'" or c == '"' then q = c; i = i + 1
    elseif c == "/" and i > 1 then return s:sub(1, i - 1), s:sub(i + 1)
    else i = i + 1 end
  end
  return s, ""
end
-- Scan a ${…} starting at the `{` (index `bi`) in `s`, returning the index just
-- past the matching `}`. Respects backslash escapes, '…'/"…" quoting (so a `}`
-- inside quotes doesn't close), and nested `{…}` — unlike a naive find("}").
local function scan_braces(s, bi)
  local i, ns, depth = bi + 1, #s, 1
  while i <= ns and depth > 0 do
    local c = s:sub(i, i)
    if c == "\\" then i = i + 2
    elseif c == "'" then
      i = i + 1; while i <= ns and s:sub(i, i) ~= "'" do i = i + 1 end; i = i + 1
    elseif c == '"' then
      i = i + 1
      while i <= ns and s:sub(i, i) ~= '"' do i = i + (s:sub(i, i) == "\\" and 2 or 1) end
      i = i + 1
    elseif c == "{" then depth = depth + 1; i = i + 1
    elseif c == "}" then depth = depth - 1; i = i + 1
    else i = i + 1 end
  end
  return i
end

local function parse_paramexp(inner)
  if inner == "" then return { lit = "" } end
  -- ${ …}/${\t…}/${|…}/${(…}: whitespace, `|`, or `(` right after `{` is a bad
  -- substitution in bash 5.2 (ksh93 funsub `${ cmd;}`/`${|cmd;}` and zsh flag
  -- `${(m)x}`/`${(@k)a}` syntax, none of which this bash supports). Non-fatal
  -- (status 1), matching bash. (A `(` in a default VALUE like ${x:-(a)} is fine —
  -- only a `(` as the very first inner char is rejected.)
  do local c1 = inner:sub(1, 1)
    if c1 == " " or c1 == "\t" or c1 == "\n" or c1 == "|" or c1 == "(" then
      return { pexp = { op = "badsubst", raw = inner } }
    end
  end
  if inner == "#" then return { special = "#" } end
  -- ${-} ${?} ${$} ${!}: the special one-char parameters (like their bare $-, $?,
  -- $$, $! forms). Handled here so `!` isn't mistaken for the indirect prefix.
  if inner == "-" or inner == "?" or inner == "$" or inner == "!" then return { special = inner } end
  local indices, lenpfx, sharp_op = false, false, nil
  if inner:sub(1, 1) == "!" then indices = true; inner = inner:sub(2)     -- ${!a[@]}
    -- after `!` (indirect/keys) another prefix operator is a bad substitution
    -- (`${!!x}`, `${!#x}` are not valid — bash errors).
    if inner:sub(1, 1) == "!" or inner:sub(1, 1) == "#" then
      return { pexp = { op = "badsubst", raw = "!" .. inner } }
    end
  elseif inner:sub(1, 2) == "##" and #inner > 2 then
    -- ${##X…}: two leading #, then more → the parameter is `#` ($#) and the rest
    -- is an operator (strip etc.) applied to its value (`${##2}` = ${#} with `#2`
    -- prefix-strip = 5). ${##} alone is length-of-$# (the `#`-prefix branch below).
    sharp_op = inner:sub(2)
  elseif inner:sub(1, 1) == "#" then lenpfx = true; inner = inner:sub(2) -- ${#v} / ${#a[@]}
    -- ${#@}/${#*} are the positional-parameter COUNT, same as ${#}/$#.
    if inner == "@" or inner == "*" then return { special = "#" } end
    -- ${##} ${#?} ${#-} ${#$} ${#!}: the LENGTH of a special one-char parameter.
    if inner == "#" or inner == "?" or inner == "-" or inner == "$" or inner == "!" then
      return { special = inner, lenof = true }
    end
  end
  local name, rest
  if sharp_op then name, rest = "#", sharp_op
  else name, rest = inner:match("^([%a_][%w_]*)(.*)$") end
  if not name then name, rest = inner:match("^(%d+)(.*)$") end
  if not name then name, rest = inner:match("^([@*])(.*)$") end
  if not name then
    -- a lone invalid parameter char (${%}, ${.}, ${+}) is a bad substitution in
    -- bash (fails the command, status 1). Multi-char inners are left to the
    -- lenient var fallback (ksh funsubs `${ …}`/`${| …}`, special-param-plus-op
    -- like ${?@a} tolerated as empty), to match curse's prior behavior.
    if #inner == 1 then return { pexp = { op = "badsubst", raw = inner } } end
    return { var = inner }
  end
  -- optional [subscript]
  local index = nil
  if rest:sub(1, 1) == "[" then
    -- balance nested brackets so `${a[a[0]]}` takes `a[0]` as the subscript, not `a[0`
    local depth, close = 0, nil
    for k = 1, #rest do
      local ch = rest:sub(k, k)
      if ch == "[" then depth = depth + 1
      elseif ch == "]" then depth = depth - 1; if depth == 0 then close = k; break end end
    end
    if close then index = rest:sub(2, close - 1); rest = rest:sub(close + 1) end
    if index == "" then return { pexp = { op = "badsubst", raw = name .. "[]" } } end -- ${a[]} is invalid (bash)
  end
  if indices then
    -- ${!a[@]}/${!a[*]} = keys; ${!pfx@}/${!pfx*} = var names with that prefix;
    -- ${!name} = indirect (value of the var named by name)
    -- ${!a[@]OP}: a suffix operator flips this from "keys" to INDIRECT — bash uses
    -- ${a[@]} (space-joined) as the reference name, derefs it, then applies OP.
    if index == "@" or index == "*" then
      if rest ~= "" then return { pexp = { name = name, op = "indirect", index = index, iop = rest } } end
      return { pexp = { name = name, op = "indices", index = index } }
    end
    if rest == "*" or rest == "@" then return { pexp = { name = name, op = "prefix", star = (rest == "*") } } end
    -- ${!ref OP arg}: capture the trailing operator to apply to the resolved target
    return { pexp = { name = name, op = "indirect", index = index, iop = (rest ~= "" and rest or nil) } }
  end
  if lenpfx then
    -- ${#x} / ${#a[@]} only; a trailing operator (${#a[0]/1/x}) can't combine with
    -- the length prefix — bash rejects it as a bad substitution.
    if rest ~= "" then return { pexp = { name = name, op = "badsubst", raw = "#" .. inner } } end
    return { pexp = { name = name, op = "len", index = index } }
  end
  if rest == "" then
    if index then return { pexp = { name = name, index = index } } end -- ${a[i]}
    if name:match("^%d+$") then return { param = tonumber(name) } end
    if name == "@" or name == "*" then return { special = name } end
    return { var = name }
  end
  local two, one = rest:sub(1, 2), rest:sub(1, 1)
  local function P(t) t.name = name; t.index = index; return { pexp = t } end
  if two == ":-" or two == ":=" or two == ":+" or two == ":?" then
    return P { op = two, arg = rest:sub(3) }
  elseif one == "-" or one == "=" or one == "+" or one == "?" then
    return P { op = one, arg = rest:sub(2) }
  elseif two == "##" then return P { op = "##", arg = rest:sub(3) }
  elseif one == "#" then return P { op = "#", arg = rest:sub(2) }
  elseif two == "%%" then return P { op = "%%", arg = rest:sub(3) }
  elseif one == "%" then return P { op = "%", arg = rest:sub(2) }
  elseif two == "//" then
    local p, r = split_subst(rest:sub(3)); return P { op = "//", arg = p, arg2 = r }
  elseif one == "/" then
    local p, r = split_subst(rest:sub(2)); return P { op = "/", arg = p, arg2 = r }
  elseif two == "^^" then return P { op = "^^", arg = rest:sub(3) } -- optional fold pattern
  elseif one == "^" then return P { op = "^", arg = rest:sub(2) }
  elseif two == ",," then return P { op = ",,", arg = rest:sub(3) }
  elseif one == "," then return P { op = ",", arg = rest:sub(2) }
  elseif one == "@" then return P { op = "@", arg = rest:sub(2) } -- ${x@Q/U/u/L/E}
  elseif one == ":" then
    local body = rest:sub(2)
    if body == "" then return P { op = "badsubst", raw = name .. rest } end -- ${x:} empty offset
    -- ${x:off:len}: split off from len at the `:` that is NOT a ternary colon.
    -- The offset is arithmetic and may contain `? :` ternaries (`${s: a?2:0 :1}`),
    -- so track the ternary depth as bash does (subst.c skip_to_delim SD_ARITHEXP:
    -- each `?` raises the skip count, each `:` while it is positive belongs to
    -- that ternary). `${x::}` -> off="" (0), len="" (0). `\` escapes the next char.
    local colon, skipcol, k = nil, 0, 1
    while k <= #body do
      local ch = body:sub(k, k)
      if ch == "\\" then k = k + 2
      elseif ch == "?" then skipcol = skipcol + 1; k = k + 1
      elseif ch == ":" and skipcol > 0 then skipcol = skipcol - 1; k = k + 1
      elseif ch == ":" then colon = k; break
      else k = k + 1 end
    end
    if colon then return P { op = "sub", arg = body:sub(1, colon - 1), arg2 = body:sub(colon + 1) } end
    return P { op = "sub", arg = body }
  end
  -- Any trailing text that is not a recognized modifier is a bad substitution
  -- (e.g. `${x|html}`, `${1abc}`, `${a b}`) — bash aborts with status 1.
  return P { op = "badsubst", raw = name .. rest }
end
M.parse_paramexp = parse_paramexp

-- Find the `)` that closes a `$( … )` command substitution. `j` is the index of
-- the first char INSIDE the parens (just past "$("); returns the index just PAST
-- the closing `)`. Understands single/double/ANSI-C quotes, backslash escapes,
-- nested $()/${ }/$(( ))/backticks, and — crucially — `case … esac`, whose
-- pattern-terminating `)` does NOT close the substitution (`$(case x in x) …;; esac)`).
local scan_cmdsub
scan_cmdsub = function(src, j)
  local n = #src
  local pdepth = 0            -- nested subshell / group / extglob paren depth
  local cst = {}              -- stack of enclosing `case` phases: "in"|"pat"|"body"
  local patp = 0              -- paren depth WITHIN the current case pattern
  local patstart = false      -- at the very start of a pattern (a leading `(` is optional)
  local wstart = true         -- next char begins a word (for `#` comments and keywords)
  local i = j
  local function skipq(close) -- skip from a quote at i to just past `close`, honoring `\`
    local k = i + 1
    while k <= n and src:sub(k, k) ~= close do
      if src:sub(k, k) == "\\" then k = k + 2 else k = k + 1 end
    end
    return k + 1
  end
  while i <= n do
    local c = src:sub(i, i)
    if c == " " or c == "\t" or c == "\n" then i = i + 1; wstart = true
    elseif c == "\\" then i = i + 2; wstart = false
    elseif c == ";" then
      if src:sub(i, i + 1) == ";;" then
        if cst[#cst] == "body" then cst[#cst] = "pat"; patstart = true end
        i = i + 2
      else i = i + 1 end
      wstart = true
    elseif c == "&" then i = i + (src:sub(i, i + 1) == "&&" and 2 or 1); wstart = true
    elseif c == "|" then
      if cst[#cst] == "pat" then i = i + 1 -- `|` is pattern alternation, not a pipe
      else i = i + (src:sub(i, i + 1) == "|&" and 2 or 1); wstart = true end
    elseif c == "'" then i = skipq("'"); wstart = false; patstart = false
    elseif c == "$" and src:sub(i + 1, i + 1) == "'" then i = i + 1; i = skipq("'"); wstart = false; patstart = false
    elseif c == '"' then
      i = i + 1
      while i <= n and src:sub(i, i) ~= '"' do
        local d = src:sub(i, i)
        if d == "\\" then i = i + 2
        elseif d == "$" and src:sub(i + 1, i + 2) == "((" then local _, ni = grab_dparen(src, i + 3); i = ni
        elseif d == "$" and src:sub(i + 1, i + 1) == "(" then i = scan_cmdsub(src, i + 2)
        elseif d == "$" and src:sub(i + 1, i + 1) == "{" then i = scan_braces(src, i + 1)
        elseif d == "`" then i = i + 1; while i <= n and src:sub(i, i) ~= "`" do i = i + (src:sub(i, i) == "\\" and 2 or 1) end; i = i + 1
        else i = i + 1 end
      end
      i = i + 1; wstart = false; patstart = false
    elseif c == "`" then
      i = i + 1; while i <= n and src:sub(i, i) ~= "`" do i = i + (src:sub(i, i) == "\\" and 2 or 1) end; i = i + 1
      wstart = false; patstart = false
    elseif c == "$" and src:sub(i + 1, i + 2) == "((" then local _, ni = grab_dparen(src, i + 3); i = ni; wstart = false; patstart = false
    elseif c == "$" and src:sub(i + 1, i + 1) == "(" then i = scan_cmdsub(src, i + 2); wstart = false; patstart = false
    elseif c == "$" and src:sub(i + 1, i + 1) == "{" then i = scan_braces(src, i + 1); wstart = false; patstart = false
    elseif c == "#" and wstart then
      while i <= n and src:sub(i, i) ~= "\n" do i = i + 1 end -- comment to end of line
    elseif c == "(" then
      if cst[#cst] == "pat" then
        if patstart then patstart = false else patp = patp + 1 end -- leading `(` is optional; else extglob/group
        wstart = false
      else pdepth = pdepth + 1; wstart = true end
      i = i + 1
    elseif c == ")" then
      if cst[#cst] == "pat" then
        if patp > 0 then patp = patp - 1; i = i + 1
        else cst[#cst] = "body"; patstart = false; i = i + 1; wstart = true end -- pattern terminator
      elseif pdepth > 0 then pdepth = pdepth - 1; i = i + 1; wstart = false
      else return i + 1 end -- the `)` that closes the $(
    elseif c == "<" or c == ">" then i = i + 1; wstart = false
    else
      local a, b = src:find("^[^ \t\n;&|()<>'\"`$#\\]+", i)
      if not a then i = i + 1
      else
        local wd, was = src:sub(a, b), wstart
        wstart = false; if cst[#cst] == "pat" then patstart = false end
        if was and wd == "case" then cst[#cst + 1] = "in"
        elseif wd == "in" and cst[#cst] == "in" then cst[#cst] = "pat"; patstart = true
        elseif was and wd == "esac" and #cst > 0 then table.remove(cst) end
        i = b + 1
      end
    end
  end
  error("syntax error: unexpected end of file") -- unclosed $(
end

-- `$((` is arithmetic ONLY when it's a balanced `$(( expr ))` — the paren balance
-- first returns to 0 at a `)` immediately followed by another `)`. Otherwise the
-- first `(` opened a subshell (`$( (…) )`, #2337). Quote-aware.
local function dparen_is_arith(w, j0)
  local depth, j, n = 0, j0, #w
  while j <= n do
    local c = w:sub(j, j)
    if c == "\\" then j = j + 2
    elseif c == "'" or c == '"' then
      local q = c; j = j + 1
      while j <= n and w:sub(j, j) ~= q do
        if w:sub(j, j) == "\\" and q == '"' then j = j + 2 else j = j + 1 end
      end
      j = j + 1
    elseif c == "(" then depth = depth + 1; j = j + 1
    elseif c == ")" then
      if depth == 0 then return w:sub(j + 1, j + 1) == ")" end
      depth = depth - 1; j = j + 1
    else j = j + 1 end
  end
  return false
end

-- Parse a $… expansion at position i of string w; add(part) tagging it with the
-- quoted flag q; returns the next index. (q drives word-splitting downstream.)
local function parse_dollar(w, i, add, q)
  local nx = w:sub(i + 1, i + 1)
  if w:sub(i + 1, i + 2) == "((" and dparen_is_arith(w, i + 3) then
    local body, ni = grab_dparen(w, i + 3); add({ arith = body, q = q }); return ni
  elseif nx == "[" then -- $[expr]: deprecated arithmetic, an alias of $(( ))
    local depth, j = 1, i + 2
    while j <= #w do
      local c2 = w:sub(j, j)
      if c2 == "[" then depth = depth + 1
      elseif c2 == "]" then depth = depth - 1; if depth == 0 then break end end
      j = j + 1
    end
    add({ arith = w:sub(i + 2, j - 1), q = q }); return j + 1
  elseif nx == "(" then
    local je = scan_cmdsub(w, i + 2) -- index just past the closing `)` (case/quote/nesting aware)
    add({ cmdsub = w:sub(i + 2, je - 2), q = q }); return je
  elseif nx == '"' then
    -- $"…" locale translation: with no catalog it's just the double-quoted string.
    return i + 1 -- skip the `$`; the caller parses the following "…" normally
  elseif nx == "'" then
    -- $'…' ANSI-C quoting: a literal string with backslash escapes, no expansion.
    local j, buf = i + 2, {}
    while j <= #w do
      local c2 = w:sub(j, j)
      if c2 == "\\" then buf[#buf + 1] = w:sub(j, j + 1); j = j + 2
      elseif c2 == "'" then break
      else buf[#buf + 1] = c2; j = j + 1 end
    end
    add({ lit = require("runtime").ansi_unescape(table.concat(buf), true), q = true }); return j + 1
  elseif nx == "{" then
    -- find the MATCHING } — honoring \-escapes, '…'/"…" quoting, and nested ${…}
    -- so `${var#\}}`, `${var-'}'}`, `${a:-${b}}` take the right inner text.
    local endp = scan_braces(w, i + 1) -- index just past the closing }
    local part = parse_paramexp(w:sub(i + 2, endp - 2)); part.q = q; add(part); return endp
  elseif nx:match("%d") then
    add({ param = tonumber(nx), q = q }); return i + 2
  elseif nx == "#" or nx == "@" or nx == "*" or nx == "?" or nx == "$" or nx == "!" or nx == "-" then
    add({ special = nx, q = q }); return i + 2
  else
    local s, e = w:find("^%$([%a_][%w_]*)", i)
    if s then add({ var = w:sub(s + 1, e), q = q }); return e + 1
    else add({ lit = "$", q = q }); return i + 1 end
  end
end

-- Parse the inside of a "…" (everything is quoted): $ expansions + literals,
-- honoring \$ \" \\ \` escapes.
local function parse_dquote(inner, add, heredoc)
  local i = 1
  while i <= #inner do
    local c = inner:sub(i, i)
    if c == "\\" then
      -- `\` escapes $ ` \ (and " in a real "…", but NOT in a heredoc body where
      -- " is an ordinary char, so `\"` stays literal there).
      local nx = inner:sub(i + 1, i + 1)
      if nx == "\n" and not heredoc then i = i + 2 -- backslash-newline: line continuation (removed)
      elseif nx == "$" or (nx == '"' and not heredoc) or nx == "\\" or nx == "`" then add({ lit = nx, q = true }); i = i + 2
      else add({ lit = "\\", q = true }); i = i + 1 end
    elseif c == "$" then
      i = parse_dollar(inner, i, add, true)
    elseif c == "`" then -- `cmd` command substitution inside "…"
      -- within a backtick INSIDE double quotes, `\` also escapes `"` (unlike the
      -- `$()` form) — bash unwraps `\"`→`"`, so `"`echo \"hi\"`"` runs `echo "hi"`.
      local j, buf = i + 1, {}
      while j <= #inner and inner:sub(j, j) ~= "`" do
        if inner:sub(j, j) == "\\" and inner:sub(j + 1, j + 1):match("[`$\\\"]") then buf[#buf + 1] = inner:sub(j + 1, j + 1); j = j + 2
        else buf[#buf + 1] = inner:sub(j, j); j = j + 1 end
      end
      add({ cmdsub = table.concat(buf), q = true }); i = j + 1
    else
      local s, e = inner:find("^[^$\\`]+", i); add({ lit = inner:sub(s, e), q = true }); i = e + 1
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
  if not w:find("\\\n", 1, true) then return w end
  local o, i, n = {}, 1, #w
  while i <= n do
    local c = w:sub(i, i)
    if c == "'" then -- single quotes: literal, keep verbatim (incl. any \<nl>)
      local e = w:find("'", i + 1, true) or n
      o[#o + 1] = w:sub(i, e); i = e + 1
    elseif c == "\\" then
      if w:sub(i + 1, i + 1) == "\n" then i = i + 2 -- continuation: drop both
      else o[#o + 1] = w:sub(i, i + 1); i = i + 2 end -- escaped char: keep the pair
    else o[#o + 1] = c; i = i + 1 end
  end
  return table.concat(o)
end

local function parse_word(w)
  w = strip_contin(w)
  local parts = {}
  local function add(p) parts[#parts + 1] = p end
  local i = 1
  while i <= #w do
    local c = w:sub(i, i)
    if c == "'" then -- single quotes: literal, no expansion
      local e = w:find("'", i + 1, true) or #w + 1
      add({ lit = w:sub(i + 1, e - 1), q = true }); i = e + 1
    elseif c == '"' then -- double quotes: expand inside; skip $(..)/$((..))/${..}/`..`
      local j = i + 1                              -- so their inner " isn't the close
      while j <= #w and w:sub(j, j) ~= '"' do
        local d = w:sub(j, j)
        if d == "\\" then j = j + 2
        elseif d == "$" and w:sub(j + 1, j + 2) == "((" then local _, nj = grab_dparen(w, j + 3); j = nj
        elseif d == "$" and w:sub(j + 1, j + 1) == "(" then
          j = j + 2; local dep = 1
          while j <= #w and dep > 0 do
            local cc = w:sub(j, j)
            if cc == "(" then dep = dep + 1 elseif cc == ")" then dep = dep - 1 end
            j = j + 1
          end
        elseif d == "$" and w:sub(j + 1, j + 1) == "{" then -- ${...}: inner \ ' " and {} nesting
          j = scan_braces(w, j + 1)
        elseif d == "`" then
          j = j + 1
          while j <= #w and w:sub(j, j) ~= "`" do if w:sub(j, j) == "\\" then j = j + 2 else j = j + 1 end end
          j = j + 1
        else j = j + 1 end
      end
      local before = #parts
      parse_dquote(w:sub(i + 1, j - 1), add)
      if #parts == before then add({ lit = "", q = true }) end -- empty "" is still a field
      i = j + 1
    elseif c == "$" then
      i = parse_dollar(w, i, add, false)
    elseif c == "`" then -- `cmd` command substitution
      local j, buf = i + 1, {}
      while j <= #w and w:sub(j, j) ~= "`" do
        if w:sub(j, j) == "\\" and w:sub(j + 1, j + 1):match("[`$\\]") then buf[#buf + 1] = w:sub(j + 1, j + 1); j = j + 2
        else buf[#buf + 1] = w:sub(j, j); j = j + 1 end
      end
      add({ cmdsub = table.concat(buf), q = false }); i = j + 1
    elseif (c == "<" or c == ">") and w:sub(i + 1, i + 1) == "(" then
      -- <(cmd) / >(cmd) process substitution: capture the balanced inner command.
      local j, d = i + 2, 1
      while j <= #w and d > 0 do
        local cc = w:sub(j, j)
        if cc == "(" then d = d + 1 elseif cc == ")" then d = d - 1; if d == 0 then break end end
        j = j + 1
      end
      add({ procsub = w:sub(i + 2, j - 1), dir = c, q = false }); i = j + 1
    elseif c == "\\" then -- backslash escape: literal next char (newline = continuation)
      local nx = w:sub(i + 1, i + 1)
      if nx == "\n" or nx == "" then -- line continuation / trailing backslash: drop
      else add({ lit = nx, q = true }) end
      i = i + 2
    else
      local s, e = w:find("^[^$'\"`\\<>]+", i)
      if not s then add({ lit = w:sub(i, i), q = false }); i = i + 1
      else add({ lit = w:sub(s, e), q = false }); i = e + 1 end
    end
  end
  return { k = "word", parts = parts }
end
M.parse_word = parse_word

-- Parse a heredoc body as double-quote content: $… expands, but quotes are
-- literal (a heredoc doesn't treat ' or " specially). Used when the delimiter
-- was unquoted; a quoted delimiter means no expansion (raw body).
-- `is_body` true for a real heredoc body (where " is an ordinary char, so `\"`
-- stays literal); false/omitted for a double-quoted-context reuse (a quoted
-- ${x-default} word), where `\"` escapes to " like inside "…".
function M.parse_heredoc(body, is_body)
  local parts = {}
  parse_dquote(body, function(p) parts[#parts + 1] = p end, is_body)
  return { k = "word", parts = parts }
end

-- Parse a [[ … ]] token list into a boolean-expression AST:
--   {kind="and"/"or", l, r} | {kind="not", e} | {kind="str", word}
--   {kind="unary", op, word} | {kind="binary", op, l, r, rq}
-- `rq` marks the RHS of ==/!= as fully-quoted (literal, not a glob).
local function parse_dbracket(toks, quoted)
  local pos, serr = 1, false
  local function peek() return toks[pos] end
  -- `<` `>` `&&` `||` can't stand where an operand is expected (`[[ -f < ]]` is a
  -- parse error). Note `=`/`==`/`!=`/`=~` ARE accepted there as literal strings.
  local function is_op(tok)
    return tok == "<" or tok == ">" or tok == "&&" or tok == "||"
  end
  local parse_or
  local function primary()
    local t = peek()
    if t == nil then serr = true; return { kind = "str", word = parse_word("") } end -- expected an operand
    if t == "&&" or t == "||" then serr = true; pos = pos + 1; return { kind = "str", word = parse_word("") } end -- operator with no left operand
    if t == ")" then serr = true; pos = pos + 1; return { kind = "str", word = parse_word("") } end -- unmatched `)` (a matched one is consumed after `(`)
    if t == "!" then pos = pos + 1; return { kind = "not", e = primary() } end
    if t == "(" then pos = pos + 1; local e = parse_or(); if peek() == ")" then pos = pos + 1 else serr = true end; return e end
    if t and t:match("^%-[a-zA-Z]$") then -- unary file/string test
      if toks[pos + 1] == nil or is_op(toks[pos + 1]) then serr = true end -- needs a (non-operator) operand
      pos = pos + 2; return { kind = "unary", op = t, word = parse_word(toks[pos - 1] or "") }
    end
    pos = pos + 1 -- consume lhs
    local op = peek()
    if op == "==" or op == "!=" or op == "=~" or op == "=" or op == "<" or op == ">"
      or (op and op:match("^%-[a-z][a-z]$")) then
      if toks[pos + 1] == nil then serr = true end -- a binary op needs a rhs
      pos = pos + 1
      local r = toks[pos]; pos = pos + 1
      return { kind = "binary", op = op, l = parse_word(t), r = parse_word(r or ""),
        rq = quoted[pos - 1] }
    end
    return { kind = "str", word = parse_word(t or "") }
  end
  local function parse_and()
    local l = primary()
    while peek() == "&&" do pos = pos + 1; l = { kind = "and", l = l, r = primary() } end
    return l
  end
  parse_or = function()
    local l = parse_and()
    while peek() == "||" do pos = pos + 1; l = { kind = "or", l = l, r = parse_and() } end
    return l
  end
  local ast = parse_or()
  -- empty `[[ ]]`, a dangling/extra operand, or a leftover token is a syntax error
  if serr or #toks == 0 or pos <= #toks then return { kind = "syntaxerr" } end
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

local function split_top_comma(inner)
  local parts, depth, start = {}, 0, 1
  for i = 1, #inner do
    local c = inner:sub(i, i)
    if c == "{" then depth = depth + 1
    elseif c == "}" then depth = depth - 1
    elseif c == "," and depth == 0 then parts[#parts + 1] = inner:sub(start, i - 1); start = i + 1 end
  end
  parts[#parts + 1] = inner:sub(start)
  return parts
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
local function classify_brace(inner)
  local a2, b2, s2 = inner:match("^(-?%d+)%.%.(-?%d+)%.%.(-?%d+)$")
  if a2 then return { range = { a = tonumber(a2), b = tonumber(b2), step = math.max(1, math.abs(tonumber(s2))), char = false, width = num_pad_width(a2, b2) } } end
  local a, b = inner:match("^(-?%d+)%.%.(-?%d+)$")
  if a then return { range = { a = tonumber(a), b = tonumber(b), step = 1, char = false, width = num_pad_width(a, b) } } end
  local ca3, cb3, cs3 = inner:match("^(%a)%.%.(%a)%.%.(-?%d+)$")
  if ca3 then return { range = { a = ca3:byte(), b = cb3:byte(), step = math.max(1, math.abs(tonumber(cs3))), char = true } } end
  local ca, cb = inner:match("^(%a)%.%.(%a)$")
  if ca then return { range = { a = ca:byte(), b = cb:byte(), step = 1, char = true } } end
  local parts = split_top_comma(inner)
  if #parts > 1 then return { list = parts } end
  return nil
end
-- Parse a raw word into factors, or nil if it has no expandable brace.
local function brace_factors(s)
  local factors, litbuf, any = {}, {}, false
  local function flush() if #litbuf > 0 then factors[#factors + 1] = { lit = table.concat(litbuf) }; litbuf = {} end end
  local i = 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == "\\" then -- a backslash escapes the next char, so `\{` isn't a brace open
      litbuf[#litbuf + 1] = c; if i + 1 <= #s then litbuf[#litbuf + 1] = s:sub(i + 1, i + 1) end; i = i + 2
    elseif c == "'" or c == '"' then
      litbuf[#litbuf + 1] = c; i = i + 1
      while i <= #s and s:sub(i, i) ~= c do litbuf[#litbuf + 1] = s:sub(i, i); i = i + 1 end
      if i <= #s then litbuf[#litbuf + 1] = c; i = i + 1 end
    elseif c == "$" and s:sub(i + 1, i + 1) == "{" then
      -- ${…} is a parameter expansion, NOT brace expansion — copy it verbatim.
      local e = s:find("}", i + 2, true) or #s
      litbuf[#litbuf + 1] = s:sub(i, e); i = e + 1
    elseif c == "$" and s:sub(i + 1, i + 1) == "(" then
      -- $(…) / $((…)): copy verbatim (balancing parens).
      local d, j = 0, i + 1
      while j <= #s do
        local cc = s:sub(j, j)
        if cc == "(" then d = d + 1 elseif cc == ")" then d = d - 1; if d == 0 then break end end
        j = j + 1
      end
      litbuf[#litbuf + 1] = s:sub(i, j); i = j + 1
    elseif c == "{" then
      local d, j = 1, i + 1
      while j <= #s and d > 0 do
        local cc = s:sub(j, j)
        if cc == "{" then d = d + 1 elseif cc == "}" then d = d - 1 end
        if d == 0 then break end
        j = j + 1
      end
      if d == 0 then
        local f = classify_brace(s:sub(i + 1, j - 1))
        if f then flush(); factors[#factors + 1] = f; any = true
        else litbuf[#litbuf + 1] = s:sub(i, j) end
        i = j + 1
      else litbuf[#litbuf + 1] = c; i = i + 1 end
    else litbuf[#litbuf + 1] = c; i = i + 1 end
  end
  flush()
  return any and factors or nil
end
M.brace_factors = brace_factors

local brace_stream -- forward (mutually recursive with itself over nested alts)
local function range_count(r) return math.floor(math.abs(r.b - r.a) / r.step) + 1 end
local function pad_num(v, w) -- zero-pad |v| to width w digits, keeping the sign
  local d = tostring(math.abs(v))
  if #d < w then d = string.rep("0", w - #d) .. d end
  return (v < 0 and "-" or "") .. d
end
-- Stream every expansion of `factors` to emit(str); ranges iterate symbolically
-- (never materialized). If emit returns true the stream STOPS — this is how a
-- consumer bounds a pathological expansion after N results without iterating the
-- rest (so a {1..1e9} range costs O(N), not O(1e9)).
local function stream_factors(factors, emit)
  local stopped = false
  local function go(idx, acc)
    if stopped then return end
    if idx > #factors then if emit(acc) then stopped = true end return end
    local f = factors[idx]
    if f.lit then go(idx + 1, acc .. f.lit)
    elseif f.range then
      local r = f.range
      for k = 0, range_count(r) - 1 do
        local v = (r.a <= r.b) and (r.a + k * r.step) or (r.a - k * r.step)
        go(idx + 1, acc .. (r.char and string.char(v) or (r.width and pad_num(v, r.width) or tostring(v))))
        if stopped then return end
      end
    else -- list: each alt may itself contain braces -> stream recursively
      for _, alt in ipairs(f.list) do
        brace_stream(alt, function(x) go(idx + 1, acc .. x); return stopped end)
        if stopped then return end
      end
    end
  end
  go(1, "")
end
brace_stream = function(s, emit)
  local f = brace_factors(s)
  if not f then emit(s) else stream_factors(f, emit) end
end
M.brace_stream = brace_stream
M.stream_factors = stream_factors

-- Cheap count of a factor list's total expansions, capped (returns >BRACE_CAP as
-- soon as it's known to exceed, without building anything).
local function count_str(s)
  local f = brace_factors(s); if not f then return 1 end
  local total = 1
  for _, fac in ipairs(f) do
    local c
    if fac.lit then c = 1
    elseif fac.range then c = range_count(fac.range)
    else c = 0; for _, alt in ipairs(fac.list) do c = c + count_str(alt); if c > BRACE_CAP then break end end end
    total = total * c
    if total > BRACE_CAP then return total end
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

local function add_word(words, w)
  local factors = brace_factors(w)
  if not factors then words[#words + 1] = parse_word(w); return end
  local n = 0
  stream_factors(factors, function(x)
    words[#words + 1] = parse_word(x); n = n + 1
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
    if c == "\\" then out[#out + 1] = w:sub(i + 1, i + 1); i = i + 2
    elseif c == "'" then
      i = i + 1; while i <= len and w:sub(i, i) ~= "'" do out[#out + 1] = w:sub(i, i); i = i + 1 end; i = i + 1
    elseif c == '"' then
      i = i + 1
      while i <= len and w:sub(i, i) ~= '"' do
        if w:sub(i, i) == "\\" then out[#out + 1] = w:sub(i + 1, i + 1); i = i + 2
        else out[#out + 1] = w:sub(i, i); i = i + 1 end
      end
      i = i + 1
    else out[#out + 1] = c; i = i + 1 end
  end
  return table.concat(out)
end

local function make_parser(src, sh)
  local i, n, line = 1, #src, 1
  local loopId = 0
  local heredocs_pending = {} -- heredoc redirs awaiting their body (filled at line end)
  -- Alias expansion, done here in the PARSER as a deterministic function of the
  -- source text (recognizing `shopt -s/-u expand_aliases`, `alias`, `unalias` as
  -- they are parsed), so the interpreter and the behind-the-scenes compiler both
  -- consume the identical expanded tree — an alias is a "baby source": its value
  -- is spliced into the token stream and re-tokenized IN CONTEXT, so a `{`/`(`
  -- pairs with a later `}`/`)`, `|` forms a real pipeline, and a trailing blank
  -- makes the following word alias-eligible too.
  local alias_on = false             -- shopt expand_aliases state (from source)
  local aliases = {}                 -- name -> value (from parsed `alias` commands)
  local alias_seen                   -- names being expanded now (recursion guard)
  local alias_next = false           -- next word is eligible (prev value ended blank)
  local alias_tail = nil             -- byte position just past the current expansion
  -- The static (fully-literal, unquoted) text of a word, or nil if any part is an
  -- expansion/quoted-out — used to read alias/shopt/unalias operands from source.
  local function static_word(w)
    if not w or not w.parts then return nil end
    local out = {}
    for _, p in ipairs(w.parts) do
      if p.lit == nil then return nil end
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
    if sh then return sh.shopt and sh.shopt.expand_aliases, sh.aliases end
    return alias_on, aliases
  end
  -- Record alias-affecting builtins as they are parsed so later words expand
  -- (source-tracking; only needed for the sh-less compile path).
  local function record_alias_state(node)
    if sh then return end
    if not (node and node.t == "simple" and node.words and node.words[1]) then return end
    local w1 = node.words[1].parts
    local cmd = (#w1 == 1 and not w1[1].q and w1[1].lit) or nil
    if cmd == "shopt" then
      local set = nil
      for k = 2, #node.words do
        local a = static_word(node.words[k])
        if a == "-s" then set = true elseif a == "-u" then set = false
        elseif a == "-q" or a == "-p" or a == "-o" then -- flags, ignore
        elseif a == "expand_aliases" and set ~= nil then alias_on = set end
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
              if w.parts[p].lit == nil then ok = false; break end
              rest[#rest + 1] = w.parts[p].lit
            end
            if ok and name ~= "" then aliases[name] = table.concat(rest) end
          end
        end
      end
    elseif cmd == "unalias" then
      for k = 2, #node.words do
        local a = static_word(node.words[k])
        if a == "-a" then aliases = {} elseif a and not a:match("^%-") then aliases[a] = nil end
      end
    end
  end
  -- Try to expand an alias at the current position. `cmdpos` = command position
  -- (always eligible); otherwise eligible only via trailing-blank chaining, and
  -- only once the parser has consumed past the value that set the flag.
  local function try_alias(cmdpos)
    local on, tab = alias_state()
    if not on then return end
    if not cmdpos then
      if not (alias_next and alias_tail and i >= alias_tail) then return end
      -- Now past the previous value: this is a fresh input word, so the guard
      -- resets (bash only blocks an alias WITHIN its own value's expansion, not a
      -- separate later occurrence — `echo-x echo-x` expands both). The word's own
      -- value recursion below still accumulates into the fresh guard.
      alias_seen = {}
    end
    local expanded = false
    while true do
      local rs, re = src:find("^[^ \t\n|&;()<>'\"`\\$]+", i)
      if not rs then break end
      local nextch = src:sub(re + 1, re + 1)
      if nextch ~= "" and nextch:match("['\"`\\$]") then break end -- not a pure literal word
      local cand = src:sub(rs, re)
      local val = tab and tab[cand]
      if val == nil or alias_seen[cand] then break end
      alias_seen[cand] = true
      local L = re - rs + 1
      src = src:sub(1, rs - 1) .. val .. src:sub(re + 1); n = #src
      if alias_tail == nil then alias_tail = rs + #val
      else alias_tail = alias_tail + (#val - L) end
      alias_next = val:match("[ \t]$") ~= nil
      expanded = true
      -- recurse: the value's first word (now at i) is itself command-position
    end
    -- A chained (argument-position) word that turned out NOT to be an alias ends
    -- the chain. A command-position miss must NOT clear a chain a prior expansion
    -- set (the command word is re-checked here after being expanded at dispatch).
    if not expanded and not cmdpos then alias_next = false end
  end
  -- Collect the bodies of any heredocs opened on the just-parsed line. Called
  -- after a simple command AND after a compound command's redirs (group,
  -- subshell, etc.), since `{ ...; } <<EOF` also opens a heredoc.
  local function collect_heredocs()
    if #heredocs_pending == 0 then return end
    while i <= n and src:sub(i, i) ~= "\n" do i = i + 1 end -- to end of command line
    if i <= n then i = i + 1; line = line + 1 end
    for _, hd in ipairs(heredocs_pending) do
      local blines = {}
      while i <= n do
        local le = src:find("\n", i, true) or (n + 1)
        local lstr = src:sub(i, le - 1)
        if hd.strip then lstr = lstr:gsub("^\t+", "") end
        i = le + 1; line = line + 1
        if lstr == hd.delim then break end
        blines[#blines + 1] = lstr
      end
      hd.body = #blines > 0 and (table.concat(blines, "\n") .. "\n") or ""
    end
    heredocs_pending = {}
  end
  local function ws()  -- skip spaces/tabs (not newlines)
    while i <= n and src:sub(i, i):match("[ \t]") do i = i + 1 end
  end
  local parse_redir -- forward (defined in make_parser body)
  -- Redirections trailing a compound command (loop/if/case): `done < f`,
  -- `done <<EOF … EOF`. Collect them and any heredoc bodies they open.
  local function tail_redirs()
    local redirs = {}
    while true do ws(); local r = parse_redir(); if r then redirs[#redirs + 1] = r else break end end
    return #redirs > 0 and redirs or nil
  end
  local function skipsep()  -- skip separators: whitespace, newlines, ;, comments
    while i <= n do
      local c = src:sub(i, i)
      if c == "\n" then
        -- heredoc bodies opened earlier on this logical line follow this newline,
        -- in the order the `<<` operators appeared — collect them all here.
        if #heredocs_pending > 0 then collect_heredocs() -- consumes the newline + bodies
        else line = line + 1; i = i + 1 end
      elseif c:match("[ \t;]") then i = i + 1
      elseif c == "#" then while i <= n and src:sub(i, i) ~= "\n" do i = i + 1 end
      else break end
    end
  end
  -- Like skipsep but STOPS at a statement separator (; & |) instead of eating it,
  -- so the statement loops can tell a *trailing* separator (fine) from one in
  -- command position (a syntax error — see bare_sep_tok).
  local function skipblank()
    while i <= n do
      local c = src:sub(i, i)
      if c == "\n" then
        if #heredocs_pending > 0 then collect_heredocs()
        else line = line + 1; i = i + 1 end
      elseif c == " " or c == "\t" then i = i + 1
      elseif c == "#" then while i <= n and src:sub(i, i) ~= "\n" do i = i + 1 end
      else break end
    end
  end
  -- At a command-expected position a control operator means an empty command,
  -- which bash rejects as a syntax error (status 2): a leading/doubled `;`, `;;`,
  -- `&`, `&&`, `||`, `|`, or `|&`. Returns the offending token, or nil.
  local function bare_sep_tok()
    local c2 = src:sub(i, i + 1)
    if c2 == ";;" or c2 == "&&" or c2 == "||" or c2 == "|&" then return c2 end
    local c = src:sub(i, i)
    if c == ";" or c == "&" or c == "|" then return c end
    return nil
  end
  local function word(stop_paren, stop_cmp)  -- read one shell word, keeping quotes and $(( )) / ${ } / $( ) balanced
    ws()
    local start = i
    while i <= n do
      local c = src:sub(i, i)
      if c == "\\" then -- backslash escapes the next char (incl. metachars/space)
        if src:sub(i + 1, i + 1) == "\n" then line = line + 1 end -- `\<newline>` line continuation
        i = i + 2
      elseif stop_paren and (c == ")" or c == "(") then break
      elseif c == '"' then -- double quotes: honor \" and skip $(..)/$((..))/`..`
        i = i + 1                                        -- (their inner " are not the close)
        while i <= n and src:sub(i, i) ~= '"' do
          local d = src:sub(i, i)
          if d == "\\" then i = i + 2
          elseif d == "$" and src:sub(i + 1, i + 2) == "((" then local _, ni = grab_dparen(src, i + 3); i = ni
          elseif d == "$" and src:sub(i + 1, i + 1) == "(" then
            i = scan_cmdsub(src, i + 2) -- case/quote/nesting-aware boundary
          elseif d == "$" and src:sub(i + 1, i + 1) == "{" then
            i = scan_braces(src, i + 1) -- ${…}: inner \ ' " and nested {} don't close it
          elseif d == "`" then
            i = i + 1
            while i <= n and src:sub(i, i) ~= "`" do if src:sub(i, i) == "\\" then i = i + 2 else i = i + 1 end end
            i = i + 1
          else i = i + 1 end
        end
        i = i + 1 -- past closing quote
      elseif c == "'" then -- single quotes: everything literal, no escapes
        i = i + 1
        while i <= n and src:sub(i, i) ~= "'" do i = i + 1 end
        i = i + 1 -- past closing quote
      elseif c == "$" and src:sub(i + 1, i + 1) == "'" then
        -- $'…' ANSI-C quote: scan to the close honoring \' \\
        i = i + 2
        while i <= n and src:sub(i, i) ~= "'" do
          if src:sub(i, i) == "\\" then i = i + 2 else i = i + 1 end
        end
        i = i + 1
      elseif c == "$" and src:sub(i + 1, i + 2) == "((" and dparen_is_arith(src, i + 3) then
        local _, ni = grab_dparen(src, i + 3); i = ni
      elseif c == "$" and src:sub(i + 1, i + 1) == "[" then -- $[expr]: keep whole (spaces inside)
        i = i + 2; local d = 1
        while i <= n and d > 0 do
          local cc = src:sub(i, i)
          if cc == "[" then d = d + 1 elseif cc == "]" then d = d - 1 end
          i = i + 1
        end
      elseif c == "$" and src:sub(i + 1, i + 1) == "(" then
        i = scan_cmdsub(src, i + 2) -- case/quote/nesting-aware boundary (errors if unclosed)
      elseif (c == "<" or c == ">") and src:sub(i + 1, i + 1) == "(" then
        -- <(cmd) / >(cmd) process substitution: part of the word (balanced parens)
        i = i + 2; local d = 1
        while i <= n and d > 0 do
          local cc = src:sub(i, i)
          if cc == "(" then d = d + 1 elseif cc == ")" then d = d - 1 end
          i = i + 1
        end
      elseif c:match("[?*+@!]") and src:sub(i + 1, i + 1) == "(" then
        -- extglob ?(..) *(..) +(..) @(..) !(..): part of the word, not a subshell
        i = i + 2; local d = 1
        while i <= n and d > 0 do
          local cc = src:sub(i, i)
          if cc == "(" then d = d + 1 elseif cc == ")" then d = d - 1 end
          i = i + 1
        end
      elseif c == "<" or c == ">" or c == "|" or c == "&" then break -- metacharacters end a word: redirs (procsub <(/>( handled above), `|`/`&` pipelines/lists & `&&`/`||`/`>&` need no surrounding space
      elseif c == "$" and src:sub(i + 1, i + 1) == "{" then
        i = scan_braces(src, i + 1) -- ${…}: match the close, honoring \ ' " and nesting
      elseif c == "`" then -- `…` command sub: keep it whole (spaces inside included)
        i = i + 1
        while i <= n and src:sub(i, i) ~= "`" do
          if src:sub(i, i) == "\\" then i = i + 2 else i = i + 1 end
        end
        if i > n then error("syntax error: unexpected end of file") end -- unclosed backtick
        i = i + 1
      elseif c:match("[ \t\n;]") then break
      else i = i + 1 end
    end
    return src:sub(start, i - 1)
  end

  local parse_stmts
  local function peekword()
    local save = i; ws(); local s, e = src:find("^[%a_][%w_]*", i)
    local w = s and src:sub(s, e) or nil; i = save; return w
  end

  local function brace_group() -- parse `{ stmts }` (a function body / group)
    ws()
    if src:sub(i, i) ~= "{" then error("expected { for function body") end
    i = i + 1
    local stmts = parse_stmts({ ["}"] = true })
    return stmts
  end

  -- A function body is usually a `{ … }` group but may be a `( … )` subshell
  -- (bash: `f() ( ... )`). Return a stmt list either way — the subshell form
  -- yields a one-statement list holding a subshell node, so it runs isolated.
  local function func_body()
    ws()
    while src:sub(i, i) == "\n" do line = line + 1; i = i + 1; ws() end -- bash allows newlines before the body
    if src:sub(i, i) == "(" then
      local ln = line; i = i + 1
      local body = parse_stmts({ [")"] = true })
      return { { t = "subshell", line = ln, body = body } }
    end
    return brace_group()
  end
  -- A function definition, with any trailing redirects (`f() { … } >&2`) that apply
  -- to the whole body on every call.
  local function funcdef_node(nm, dstart, dline)
    local body = func_body()
    -- capture the definition's exact source text (name/`function` through the
    -- closing `}`) so `declare -f`/`type`/`command -V` can recover it verbatim,
    -- no deparser needed. `src` here is the whole script or the -c/stdin string.
    local deftext = dstart and src:sub(dstart, i - 1) or nil
    local redirs = {}
    while true do ws(); local r = parse_redir(); if r then redirs[#redirs + 1] = r else break end end
    return { t = "funcdef", name = nm, body = body, deftext = deftext, line = dline,
      redirs = (#redirs > 0 and redirs or nil) }
  end

  local parse_stmt -- forward: the and-or wrapper (used by case bodies below)

  -- Try to read a redirection at the current position; returns a redir table and
  -- advances i, or nil (leaving i put) if there isn't one. Handles
  -- [N]> [N]>> [N]< >&M N>&M &> [N]>&- ; heredocs (<<) are left to parse_command.
  parse_redir = function()
    local p = i
    -- `<(…)` / `>(…)` are process substitutions (word parts), not redirections.
    if src:sub(p, p + 1) == "<(" or src:sub(p, p + 1) == ">(" then return nil end
    -- `{var}>…` names a fd: bash allocates a fd (>=10) and stores it in `var`.
    -- Only when `{var}` is immediately followed by a redirection operator.
    local fdvar = src:match("^{([%a_][%w_]*)}[<>]", p)
    local fd = not fdvar and src:match("^%d+", p) or nil
    local q = fdvar and (p + #fdvar + 2) or (fd and (p + #fd) or p)
    local c = src:sub(q, q)
    local op, tfd
    if c == ">" then
      if src:sub(q, q + 1) == ">&" then op = "dup"; tfd = fd and tonumber(fd) or 1; q = q + 2
      elseif src:sub(q, q + 1) == ">>" then op = "app"; tfd = fd and tonumber(fd) or 1; q = q + 2
      elseif src:sub(q, q + 1) == ">|" then op = "clobber"; tfd = fd and tonumber(fd) or 1; q = q + 2
      else op = "out"; tfd = fd and tonumber(fd) or 1; q = q + 1 end
    elseif c == "<" then
      if src:sub(q, q + 2) == "<<<" then -- herestring: [N]<<< word
        i = q + 3; ws()
        return { op = "herestring", fd = fd and tonumber(fd) or 0, word = word(), fdvar = fdvar } -- raw word (expanded at runtime)
      end
      if src:sub(q, q + 1) == "<<" then -- heredoc: [N]<<[-] DELIM  (body collected after the line)
        local strip = false; q = q + 2
        if src:sub(q, q) == "-" then strip = true; q = q + 1 end
        i = q; ws()
        local draw = word()
        -- ANY quoting anywhere in the delimiter word makes the body literal (bash);
        -- the delimiter itself is the word with all quotes removed.
        local quoted = draw:find('[\'"\\]') ~= nil
        local r = { op = "heredoc", fd = fd and tonumber(fd) or 0, delim = dequote_word(draw), expand = not quoted, strip = strip, fdvar = fdvar }
        heredocs_pending[#heredocs_pending + 1] = r
        return r
      end
      if src:sub(q, q + 1) == "<>" then op = "rw"; tfd = fd and tonumber(fd) or 0; q = q + 2 -- open for read+write
      elseif src:sub(q, q + 1) == "<&" then op = "dupin"; tfd = fd and tonumber(fd) or 0; q = q + 2
      else op = "in"; tfd = fd and tonumber(fd) or 0; q = q + 1 end
    -- `&>`/`&>>` (redirect both stdout+stderr) take NO fd prefix: a digit before
    -- them (`2&>1`) is a command word, not an fd, so leave it (parse_redir re-runs
    -- on the `&>` after the word is read).
    elseif c == "&" and not fd and src:sub(q, q + 2) == "&>>" then op = "appboth"; tfd = 1; q = q + 3
    elseif c == "&" and not fd and src:sub(q, q + 1) == "&>" then op = "outboth"; tfd = 1; q = q + 2
    else return nil end
    i = q; ws()
    local raw = word()
    -- a redirection with NO word (`echo >`, `cmd <;`) is a syntax error in bash
    -- (status 2). A quoted empty target (`> ''`) is a real, empty filename — that's
    -- a runtime failure, not a parse error — so key on the raw word being absent.
    if raw == "" then error("syntax error near `" .. (src:sub(i, i) == "" and "newline" or src:sub(i, i)) .. "'") end
    return { fd = tfd, op = op, target = unquote(raw), fdvar = fdvar }
  end

  local function parse_command()
    ws()
    -- reset the per-command alias recursion guard, then expand a leading alias in
    -- place (handles a compound-command alias like LEFT='{' before dispatch; the
    -- command-word case with leading assignments/redirects re-runs in the simple
    -- loop, sharing this guard so a self-referential alias can't loop).
    alias_seen = {}; alias_next = false; alias_tail = nil
    try_alias(true)
    local dstart, dline = i, line -- byte offset + line where this command (hence a funcdef) begins
    -- function NAME [()] { … }   or   NAME() { … }
    -- Function names may contain far more than identifier chars (bash: `show-len`,
    -- `git-foo`, `a.b`), so match a run of non-metacharacter word bytes here.
    if peekword() == "function" then
      ws(); i = i + 8; ws()
      local s, e = src:find("^[%w_][%w_%.%-:+@/!#]*", i)
      if not s then error("function needs a name") end
      local nm = src:sub(s, e); i = e + 1; ws()
      -- optional `( )` (bash: `function f () { … }`, spaces allowed between parens)
      if src:sub(i, i) == "(" then
        local k = i + 1; while src:sub(k, k):match("[ \t]") do k = k + 1 end
        if src:sub(k, k) == ")" then i = k + 1 end
      end
      return funcdef_node(nm, dstart, dline)
    end
    do
      local s, e = src:find("^[%w_][%w_%.%-:+@/!#]*", i)
      if s then
        local j = e + 1
        while src:sub(j, j):match("[ \t]") do j = j + 1 end
        -- NAME ( ) — a space is allowed between the parens (bash: `fun ( ) { … }`)
        if src:sub(j, j) == "(" then
          local k = j + 1; while src:sub(k, k):match("[ \t]") do k = k + 1 end
          if src:sub(k, k) == ")" then
            local nm = src:sub(s, e); i = k + 1
            return funcdef_node(nm, dstart, dline)
          end
        end
      end
    end
    -- A funcdef whose "name" is an EXPANSION (`$foo-bar()`, `foo-$(x)()`): bash
    -- parses it and reports "not a valid identifier" at RUNTIME (status 1), not a
    -- parse error. Scan the word (balancing $()); if it's `$`-bearing and followed
    -- by `()`, treat it as a funcdef with that (invalid) name.
    do
      local j, depth = i, 0
      while j <= n do
        local c = src:sub(j, j)
        if c == "$" and src:sub(j + 1, j + 1) == "(" then depth = depth + 1; j = j + 2
        elseif c == "(" and depth > 0 then depth = depth + 1; j = j + 1
        elseif c == ")" and depth > 0 then depth = depth - 1; j = j + 1
        elseif depth == 0 and (c == "" or c:match("[ \t\n(;&|<>]")) then break
        else j = j + 1 end
      end
      if j > i and src:sub(i, j - 1):find("$", 1, true) then
        local k = j; while src:sub(k, k):match("[ \t]") do k = k + 1 end
        if src:sub(k, k) == "(" then
          local m = k + 1; while src:sub(m, m):match("[ \t]") do m = m + 1 end
          if src:sub(m, m) == ")" then
            local nm = src:sub(i, j - 1); i = m + 1
            return funcdef_node(nm, dstart, dline)
          end
        end
      end
    end
    -- for (( init; cond; step )) ; do BODY done   OR   for NAME in WORDS; do … done
    if peekword() == "for" then
      local ln = line
      ws(); i = i + 3; ws()
      if src:sub(i, i + 1) == "((" then
        local body, ni = grab_dparen(src, i + 2); i = ni
        local a, b, c = body:match("^(.-);(.-);(.-)$")
        if not a then error("for ((;;)) needs two ';'") end
        loopId = loopId + 1; local id = loopId
        skipsep()
        if peekword() == "do" then i = i + 2 end
        local body_stmts = parse_stmts({ done = true })
        -- Parse each arith slot eagerly, but a SYNTAX ERROR in a slot (`i='3'`,
        -- `++'i'`) is deferred to runtime — bash reports such an error when the loop
        -- executes and runs zero iterations non-fatally, rather than failing to parse
        -- the whole script (same rule as `$((…))`). A clean parse is unchanged.
        local function parith(s)
          if not s:match("%S") then return nil end
          local ok, ast = pcall(arith, s)
          if ok then return ast end
          return { k = "arith_perr", raw = s }
        end
        return { t = "forc", id = id, line = ln,
          init = parith(a), cond = parith(b), step = parith(c),
          body = body_stmts, redirs = tail_redirs() }
      end
      -- for NAME in WORDS. Capture NAME as a whole token (not just a valid
      -- identifier): bash accepts `for i.j`/`for -` at PARSE time and reports the
      -- invalid name as a non-fatal RUNTIME error (status 1), so the interp checks.
      local s, e = src:find("^[^%s;#()]+", i)
      if not s then error("subset: for needs a name or ((") end
      local name = src:sub(s, e); i = e + 1
      -- bash allows blank lines / comments between the loop var and `in` (but a
      -- `;` terminates the header — `for i;` iterates "$@").
      while true do
        ws()
        local c = src:sub(i, i)
        if c == "\n" then line = line + 1; i = i + 1
        elseif c == "#" then while i <= n and src:sub(i, i) ~= "\n" do i = i + 1 end
        else break end
      end
      local words = {}
      if peekword() == "in" then
        i = i + 2
        while true do
          ws()
          local c = src:sub(i, i)
          if c == ";" or c == "\n" or c == "" or c == "#" then break end
          if peekword() == "do" then break end
          -- an unquoted bare `(` in word position is a syntax error (`for x in a=()`,
          -- `for x in (`); extglob/$()/<() are consumed inside word(true).
          if c == "(" or c == ")" then error("syntax error near `" .. c .. "'") end
          local w = word(true); if w == "" then break end
          add_word(words, w)
        end
      else
        words = { parse_word('"$@"') } -- `for NAME; do …` iterates the positional params
      end
      loopId = loopId + 1; local id = loopId
      skipsep()
      if peekword() == "do" then i = i + 2 end
      local body_stmts = parse_stmts({ done = true })
      if #body_stmts == 0 then error("syntax error near `done'") end -- bash: empty do/done is invalid
      return { t = "forin", id = id, line = ln, name = name, words = words, body = body_stmts, redirs = tail_redirs() }
    end
    -- while/until COND; do BODY; done  — COND is a command list; the loop runs
    -- while its exit status is 0 (until: while it's non-zero). `while (( expr ))`
    -- works because (( )) parses as an arithcmd statement inside COND.
    if peekword() == "while" or peekword() == "until" then
      local kind = peekword(); local ln = line; i = i + #kind
      loopId = loopId + 1; local id = loopId
      local cond, t1 = parse_stmts({ ["do"] = true })
      if t1 ~= "do" then error("syntax error: `" .. kind .. "' expected `do'") end
      local body_stmts, t2 = parse_stmts({ done = true })
      if t2 ~= "done" then error("syntax error: `" .. kind .. "' expected `done'") end
      if #body_stmts == 0 then error("syntax error near `done'") end -- bash: empty do/done is invalid
      return { t = "whilec", id = id, line = ln, cond = cond, body = body_stmts,
        negate = (kind == "until"), redirs = tail_redirs() }
    end
    -- if COND; then BODY [elif COND; then BODY]* [else BODY] fi — COND is a
    -- command list; the branch is taken when its exit status is 0.
    if peekword() == "if" then
      local ln = line; i = i + 2
      local clauses = {}
      while true do
        local cond = parse_stmts({ ["then"] = true })
        local body, term = parse_stmts({ elif = true, ["else"] = true, fi = true })
        if #body == 0 then error("syntax error near `" .. term .. "'") end -- bash: empty then/elif body
        clauses[#clauses + 1] = { cond = cond, body = body }
        if term == "else" then
          local eb = parse_stmts({ fi = true })
          if #eb == 0 then error("syntax error near `fi'") end -- bash: empty else body
          clauses[#clauses + 1] = { cond = nil, body = eb }
          break
        elseif term == "fi" then break
        elseif term ~= "elif" then error("if: missing fi") end
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
        if c == "\\" then j = j + 2
        elseif c == "'" or c == '"' then
          local q = c; j = j + 1
          while j <= n and src:sub(j, j) ~= q do
            if src:sub(j, j) == "\\" and q == '"' then j = j + 2 else j = j + 1 end
          end
          j = j + 1
        elseif c == "(" then d = d + 1; j = j + 1
        elseif c == ")" then
          if d == 0 then isarith = (src:sub(j + 1, j + 1) == ")"); break end
          d = d - 1; j = j + 1
        else j = j + 1 end
      end
      if isarith then
        local body, ni = grab_dparen(src, i + 2); i = ni
        -- a malformed `(( expr ))` (bad lvalue) is a NON-fatal runtime error in bash,
        -- so defer the parse failure to eval (caught by the arithcmd handler) rather
        -- than aborting the whole parse.
        local ok, e = pcall(arith, body)
        return { t = "arithcmd", line = line, expr = ok and e or { k = "matherr" }, redirs = tail_redirs() }
      end
      -- not arith: fall through to the subshell parser below (i still at the first `(`)
    end
    -- [[ EXPR ]] conditional (no word-splitting; == is glob, =~ is regex)
    if src:sub(i, i + 1) == "[[" and src:sub(i + 2, i + 2):match("[ \t]") then
      i = i + 2
      local toks, quoted = {}, {}
      while true do
        ws()
        if src:sub(i, i) == "\n" then line = line + 1; i = i + 1 -- continuation inside [[ ]]
        elseif i > n or src:sub(i, i + 1) == "]]" then if src:sub(i, i + 1) == "]]" then i = i + 2 end; break
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
            if depth == 0 and src:sub(i, i + 1) == "]]" then break end
            if pd == 0 and (c0 == "\n" or c0 == " " or c0 == "\t" or c0 == ")") then break end
            if pd == 0 and depth == 0 and (c0 == ";" or c0 == "&" or c0 == "<" or c0 == ">") then break end
            if c0 == "\\" then i = i + 2
            elseif c0 == "'" then i = i + 1; while i <= n and src:sub(i, i) ~= "'" do i = i + 1 end; i = i + 1
            elseif c0 == '"' then i = i + 1
              while i <= n and src:sub(i, i) ~= '"' do i = i + (src:sub(i, i) == "\\" and 2 or 1) end; i = i + 1
            elseif c0 == "(" then pd = pd + 1; depth = depth + 1; i = i + 1
            elseif c0 == ")" then if pd > 0 then pd = pd - 1 end; if depth > 0 then depth = depth - 1 end; i = i + 1
            elseif c0 == "[" then depth = depth + 1; i = i + 1
            elseif c0 == "]" then if depth > 0 then depth = depth - 1 end; i = i + 1
            else i = i + 1 end
          end
          toks[#toks + 1] = src:sub(rs, i - 1); quoted[#toks] = false
        else
          local before = i
          local w = word(true, true) -- split on <,>,(,) operators (no spaces needed in [[ ]])
          if w == "" then
            -- word() stalled on a self-delimiting metacharacter. `&&`/`||` are
            -- two-char operator tokens; `(`, `)`, `<`, `>`, `;`, … are one char
            -- (each becomes its own token so the tokenizer makes progress).
            if i == before then
              local two = src:sub(i, i + 1)
              if two == "&&" or two == "||" then w = two; i = i + 2
              else w = src:sub(i, i); i = i + 1 end
            else break end
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
      local body = parse_stmts({ ["}"] = true })
      local redirs = {}
      while true do ws(); local r = parse_redir(); if r then redirs[#redirs + 1] = r else break end end
      return { t = "group", line = line, body = body, redirs = (#redirs > 0 and redirs or nil) }
    end
    if src:sub(i, i) == "(" then
      i = i + 1
      local body = parse_stmts({ [")"] = true })
      local redirs = {}
      while true do ws(); local r = parse_redir(); if r then redirs[#redirs + 1] = r else break end end
      return { t = "subshell", line = line, body = body, redirs = (#redirs > 0 and redirs or nil) }
    end
    -- case WORD in  PAT|PAT) BODY ;;  … esac
    if peekword() == "case" then
      local ln = line; i = i + 4; ws()
      -- bash requires the case subject on the same line as `case`; a newline or
      -- separator before any word (`case\nin esac`, `case;`) is a syntax error.
      -- word(true) also stops at a bare `(` so `case a=() in` errors (expected in).
      local subw = word(true)
      if subw == "" then
        local c = src:sub(i, i)
        error("syntax error near `" .. (c == "\n" and "newline" or (c == "" and "esac" or c)) .. "'")
      end
      local subject = parse_word(subw)
      while src:sub(i, i):match("[ \t\n]") do if src:sub(i, i) == "\n" then line = line + 1 end; i = i + 1 end
      if peekword() == "in" then i = i + 2
      else error("syntax error: `case' expected `in'") end -- ysh `case (x) { }` etc. rejected
      -- separator skipper that STOPS at ;; (so a clause body ends there)
      local function skip_sep()
        while i <= n do
          if src:sub(i, i + 2) == ";;&" then return "dsemi_amp" end -- ;;& (test next patterns)
          if src:sub(i, i + 1) == ";;" then return "dsemi" end       -- ;; (stop)
          if src:sub(i, i + 1) == ";&" then return "semi_amp" end     -- ;& (fall through)
          local c = src:sub(i, i)
          if c == "\n" then
            -- a heredoc opened by a command in this arm has its body after the
            -- newline (like the shared skipsep) — collect it, else it leaks as
            -- commands (`x) cat <<EOF … EOF ;;`).
            if #heredocs_pending > 0 then collect_heredocs()
            else line = line + 1; i = i + 1 end
          elseif c:match("[ \t;]") then i = i + 1
          elseif c == "#" then while i <= n and src:sub(i, i) ~= "\n" do i = i + 1 end
          else return nil end
        end
        return "eof"
      end
      local clauses = {}
      while true do
        skip_sep()
        if peekword() == "esac" then i = i + 4; break end
        if i > n then break end
        if src:sub(i, i) == "(" then i = i + 1 end -- optional leading (
        -- read to the clause-terminating ), balancing extglob parens @(a|b) and
        -- copying quoted sections verbatim (their ) / | are not structural).
        local patstr, depth = {}, 0
        while i <= n do
          local c = src:sub(i, i)
          if c == ")" and depth == 0 then break end
          if c == "'" or c == '"' then
            patstr[#patstr + 1] = c; i = i + 1
            while i <= n and src:sub(i, i) ~= c do patstr[#patstr + 1] = src:sub(i, i); i = i + 1 end
            patstr[#patstr + 1] = src:sub(i, i); i = i + 1
          else
            if c == "(" then depth = depth + 1 elseif c == ")" then depth = depth - 1 end
            patstr[#patstr + 1] = c; i = i + 1
          end
        end
        i = i + 1 -- skip the terminating )
        -- split on top-level | (extglob's internal | is protected by parens)
        local pats, d2, cur = {}, 0, {}
        local full = table.concat(patstr)
        for k = 1, #full do
          local ch = full:sub(k, k)
          if ch == "(" then d2 = d2 + 1; cur[#cur + 1] = ch
          elseif ch == ")" then d2 = d2 - 1; cur[#cur + 1] = ch
          elseif ch == "|" and d2 == 0 then pats[#pats + 1] = table.concat(cur); cur = {}
          else cur[#cur + 1] = ch end
        end
        pats[#pats + 1] = table.concat(cur)
        for k = 1, #pats do pats[k] = (pats[k]:gsub("^%s+", ""):gsub("%s+$", "")) end
        local body, term = {}, "break"
        while true do
          local s = skip_sep()
          if s == "dsemi" then i = i + 2; term = "break"; break end
          if s == "dsemi_amp" then i = i + 3; term = "test"; break end -- ;;&
          if s == "semi_amp" then i = i + 2; term = "fall"; break end  -- ;&
          if s == "eof" or peekword() == "esac" then break end
          local before = i
          local st = parse_stmt()
          if not st or i == before then
            -- a stray `)` here means a case clause had no `;;` before the next
            -- pattern (`a) b) …`) — bash rejects that as a syntax error.
            if src:sub(i, i) == ")" then error("syntax error near `)'") end
            break -- other no-progress (guard against spinning)
          end
          body[#body + 1] = st
        end
        clauses[#clauses + 1] = { pats = pats, body = body, term = term }
      end
      return { t = "case", line = ln, subject = subject, clauses = clauses, redirs = tail_redirs() }
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
      while i <= n do
        ws()
        local c = src:sub(i, i)
        if c == ")" then i = i + 1; break end
        if c == "\n" then line = line + 1; i = i + 1
        elseif c == "" then break
        else
          local w = word(true); if w == "" then break end
          local keyraw, eop, rhs = nil, "=", w
          if w:sub(1, 1) == "[" then
            local depth, close = 0, nil
            for j = 1, #w do
              local ch = w:sub(j, j)
              if ch == "[" then depth = depth + 1
              elseif ch == "]" then depth = depth - 1; if depth == 0 then close = j; break end end
            end
            if close then
              local after = w:sub(close + 1)
              if after:sub(1, 2) == "+=" then keyraw = w:sub(2, close - 1); eop = "+="; rhs = after:sub(3)
              elseif after:sub(1, 1) == "=" then keyraw = w:sub(2, close - 1); eop = "="; rhs = after:sub(2) end
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
            elems[#elems + 1] = { key = keyraw, op = eop, word = parse_word(rhs) }
          end
        end
      end
      return elems
    end

    local function try_assign()
      local name = src:match("^([%a_][%w_]*)", i)
      if not name then return nil end
      local p = i + #name
      local subidx = nil
      if src:sub(p, p) == "[" then
        -- find the MATCHING ] (subscript may contain nested [ ] via ${a[i]})
        local depth, q = 1, p + 1
        while q <= n and depth > 0 do
          local ch = src:sub(q, q)
          if ch == "[" then depth = depth + 1 elseif ch == "]" then depth = depth - 1 end
          if depth == 0 then break end
          q = q + 1
        end
        if depth == 0 and src:sub(q + 1, q + 1):match("[+=]") then subidx = src:sub(p + 1, q - 1); p = q + 1 end
      end
      local op = nil
      if src:sub(p, p + 1) == "+=" then op = "+="; p = p + 2
      elseif src:sub(p, p) == "=" then op = "="; p = p + 1 end
      if not op then return nil end
      i = p
      if src:sub(i, i) == "(" then -- array literal
        local pstart = i
        local elems = parse_array_elems()
        -- raw parenthesized text: a NAME=(…) used as a command PREFIX is a literal
        -- string in bash (arrays can't be env bindings), decided at exec time.
        return { t = "arrayassign", name = name, elems = elems, append = (op == "+="), raw = src:sub(pstart, i - 1), index = subidx }
      end
      -- The value is read from right after `=` with NO leading-whitespace skip: an
      -- empty value (`X= cmd`) must stay empty, not absorb the next word as `word()`
      -- (which skips blanks) would. Only read when a value actually follows.
      local c0 = src:sub(i, i)
      if c0 == "" or c0:match("[ \t\n;&|)#]") then
        return { t = "assign", name = name, index = subidx, append = (op == "+="), rhs = parse_word("") }
      end
      local raw = word(true) -- stop at unquoted ) so `(x=2)` closes the subshell
      if not subidx and op == "=" and raw:sub(1, 3) == "$((" and raw:sub(-2) == "))" then
        return { t = "assign", name = name, arith = arith(raw:sub(4, -3)) }
      end
      return { t = "assign", name = name, index = subidx, append = (op == "+="), rhs = parse_word(raw) }
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
      if r then redirs[#redirs + 1] = r
      else
        local a = try_assign()
        if not a then break end
        a.line = ln; assigns[#assigns + 1] = a
      end
    end

    -- a keyword that only closes/continues a compound command, reaching command
    -- position on its own (or a bare `}`), is a misplaced-token syntax error.
    do
      local MISPLACED = { ["then"] = 1, ["else"] = 1, ["elif"] = 1, ["fi"] = 1,
        ["do"] = 1, ["done"] = 1, ["esac"] = 1 }
      local pwm = peekword()
      if MISPLACED[pwm]
          or (src:sub(i, i) == "}" and (i + 1 > n or src:sub(i + 1, i + 1):match("[ \t\n;)]"))) then
        error("syntax error near `" .. (pwm ~= "" and pwm or "}") .. "'")
      end
    end
    -- simple command: WORD WORD ...
    local words = {}
    local arrayargs = nil -- `NAME=(...)` args to a declaration builtin
    while i <= n do
      local c = src:sub(i, i)
      local r = parse_redir() -- also catches &> before the & break below
      if r then redirs[#redirs + 1] = r
      elseif c == "(" and src:sub(i + 1, i + 1) ~= "(" and (#words > 0 or #assigns > 0) then
        -- a bare single `(` after a command word isn't a subshell — `ls foo=(1 2)`,
        -- `builtin typeset a=(…)`, `echo a(b)` are syntax errors in bash. Likewise a
        -- `(` after an assignment prefix with a space: `a= (1 2)` is a syntax error
        -- (the `(` can't be a command word there; `a=(1 2)` with no space is an
        -- array assignment, parsed earlier). (extglob @(…), $(…), <(…) are consumed
        -- inside word(); `((` is left to break so `a (( … ))` reaches arith.)
        error("syntax error near `('")
      elseif c == "\n" or c == ";" or c == "#" or c == "&" or c == "|"
        or c == "(" or c == ")" then break -- ( ) are metacharacters (subshell bounds)
      elseif c:match("[ \t]") then ws()
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
          i = i + #an + #ap + 1 -- past NAME (+) = ; now on `(`
          arrayargs = arrayargs or {}
          arrayargs[#arrayargs + 1] = { name = an, elems = parse_array_elems(), append = (ap == "+") }
        else
          local w = word(true) -- stop at unquoted ( ) so `cmd)` ends at the subshell close
          if w == "" then break end
          add_word(words, w)
        end
      end
    end
    if #words == 0 and #redirs == 0 then
      -- no command: the leading assignments are plain (persistent) statements
      if #assigns == 0 then return nil end
      if #assigns == 1 then return assigns[1] end
      return { t = "assignlist", line = ln, list = assigns }
    end
    -- a command follows: any leading assignments are its temporary (exported) env
    local node = { t = "simple", line = ln, words = words, redirs = (#redirs > 0 and redirs or nil),
      assigns = (#assigns > 0 and assigns or nil), arrayargs = arrayargs }
    record_alias_state(node) -- note shopt/alias/unalias so later words expand
    return node
  end

  -- pipeline: cmd [ | cmd ]*   (optional leading `!` negates the exit status)
  local function parse_pipeline()
    ws()
    local ln = line
    local negate = false
    -- `time [-p]` reserved word may precede the (optionally `!`-negated) pipeline;
    -- it's a keyword only as a standalone word (followed by whitespace/newline).
    local timed, timed_p = false, false
    if src:sub(i, i + 3) == "time" and src:sub(i + 4, i + 4):match("[ \t\n]") then
      timed = true; i = i + 4; ws()
      while src:sub(i, i + 1) == "-p" and src:sub(i + 2, i + 2):match("[ \t\n]") do timed_p = true; i = i + 2; ws() end
    end
    if src:sub(i, i + 1) == "! " then negate = true; i = i + 2; ws() end
    local first = parse_command()
    local cmds = { first }
    while true do
      ws()
      -- a `\<newline>` line continuation may sit between a stage and the `|` (e.g.
      -- `{ …; } \<nl> | cat`); a simple command absorbs its own trailing one via
      -- word(), but a compound stage does not, so skip it here before the `|` test.
      while src:sub(i, i) == "\\" and src:sub(i + 1, i + 1) == "\n" do i = i + 2; line = line + 1; ws() end
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
          if src:sub(i, i) == "#" then while i <= n and src:sub(i, i) ~= "\n" do i = i + 1 end
          elseif src:sub(i, i) == "\n" then
            -- a heredoc opened by the stage before this `|` has its body on the
            -- following lines (`cat <<EOF |` <newline> body EOF <newline> next) —
            -- consume it here before the next stage, else the body parses as cmds.
            if #heredocs_pending > 0 then collect_heredocs()
            else line = line + 1; i = i + 1 end
          else break end
        end
        cmds[#cmds + 1] = parse_command()
      else
        break
      end
    end
    local pipe = (#cmds == 1 and not negate) and first
      or { t = "pipeline", cmds = cmds, negate = negate, line = ln }
    if timed then pipe.timed = true; pipe.timed_p = timed_p end -- `time` prefix: measure this pipeline
    return pipe
  end

  -- and-or list: pipeline [ (&& | ||) pipeline ]*  ; a lone `&` (background) is
  -- accepted and run in the foreground for now.
  parse_stmt = function()
    local head = parse_pipeline()
    local items, bg = nil, false
    while true do
      ws()
      local two = src:sub(i, i + 1)
      if two == "&&" or two == "||" then
        i = i + 2
        items = items or { { op = nil, cmd = head } }
        items[#items + 1] = { op = two, cmd = parse_pipeline() }
      elseif src:sub(i, i) == "&" and src:sub(i + 1, i + 1) ~= "&" then
        i = i + 1; bg = true; break -- background job
      else
        break
      end
    end
    local node = items and { t = "andor", items = items } or head
    if bg then return { t = "background", cmd = node } end
    return node
  end

  -- Parse statements until a terminator keyword in `stopset` (consumed and
  -- returned) or EOF. Returns (stmts, terminator-or-nil).
  parse_stmts = function(stopset)
    stopset = stopset or {}
    local stmts = {}
    while true do
      skipblank()
      if i > n then return stmts, nil end
      if stopset["}"] and src:sub(i, i) == "}" then i = i + 1; return stmts, "}" end
      if stopset[")"] and src:sub(i, i) == ")" then i = i + 1; return stmts, ")" end
      local pw = peekword()
      if pw and stopset[pw] then i = i + #pw; return stmts, pw end
      -- a control operator in command position is an empty command (bash: error)
      local bs = bare_sep_tok()
      if bs then error("syntax error near `" .. bs .. "'") end
      local before = i
      local st = parse_stmt()
      if st then stmts[#stmts + 1] = st
      elseif i == before then
        -- no progress: a stray metacharacter/keyword in command position (`)`, `}`,
        -- `do`, …) — a syntax error, and a guard against an infinite loop.
        error("syntax error near `" .. src:sub(i, i) .. "'")
      end
      -- consume this statement's single trailing `;` (its terminator), so the next
      -- iteration lands on a genuine command position; `&`/newlines are handled by
      -- parse_stmt/skipblank. A following `;` is then a bare separator (error).
      ws()
      if src:sub(i, i) == ";" and src:sub(i + 1, i + 1) ~= ";" then i = i + 1 end
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
      if c == " " or c == "\t" then i = i + 1
      elseif c == "\\" and src:sub(i + 1, i + 1) == "\n" then i = i + 2; line = line + 1
      else break end
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
    if done then return nil end
    skipblank() -- blank lines, comments, and pending heredocs
    if i > n then done = true; return nil end
    local bs = bare_sep_tok() -- a leading control op (`;`, `&`, `||`, …) is an error
    if bs then done = true; return { stmts = {}, perr = { t = "parse_error", line = line, msg = "syntax error near `" .. bs .. "'" } } end
    local stmts = {}
    while true do
      local start, startline = i, line
      local ok, st = pcall(parse_stmt)
      if not ok then return { stmts = stmts, perr = { t = "parse_error", line = startline, msg = tostring(st) } } end
      -- No progress: a stray metacharacter/keyword in command position (`)`, `}`,
      -- `done`, `fi`, …). Report a syntax error (and guard against spinning).
      if i <= start then
        local tok = peekword() or src:sub(i, i)
        return { stmts = stmts, perr = { t = "parse_error", line = line, msg = "syntax error near `" .. tok .. "'" } }
      end
      stmts[#stmts + 1] = st
      skip_inline()
      local c = src:sub(i, i)
      if st.t ~= "background" then
        -- foreground: a single `;` continues the line; `\n`/EOF/`#` end it cleanly.
        -- A bare separator here (`;;`, `|`) is a syntax error ON the line — bash runs
        -- nothing on it (`echo 1 ;; echo 2`). Anything else (`(`, `((`, `)`, `}`, a
        -- stray keyword) is left to the existing statement-boundary handling.
        if c == ";" and src:sub(i + 1, i + 1) ~= ";" then i = i + 1; skip_inline()
        elseif i > n or c == "\n" or c == "#" then break
        else
          local bsx = bare_sep_tok()
          if bsx then return { stmts = stmts, perr = { t = "parse_error", line = line, msg = "syntax error near `" .. bsx .. "'" } } end
          break
        end
      elseif i > n or c == "\n" or c == "#" then break -- background & already separated; line may end
      end
      -- now at a command position for the next statement; a bare sep here is an error
      if i > n then break end
      c = src:sub(i, i)
      if c == "\n" or c == "#" then break end -- end of the logical line
      local bs2 = bare_sep_tok() -- `;;`, `&&`, `||`, bare `;`/`&` with no command before them
      if bs2 then return { stmts = stmts, perr = { t = "parse_error", line = line, msg = "syntax error near `" .. bs2 .. "'" } } end
    end
    if #heredocs_pending > 0 then collect_heredocs() end -- read bodies after the line
    return { stmts = stmts }
  end
  return next_line
end

-- Eager full parse -> { stmts } (used by the compiler, which needs the whole
-- program, and by callers that want the AST). An optional `sh` makes alias
-- expansion consult the live runtime table (for eval/source/$() at runtime); the
-- compiler passes none, so it tracks aliases deterministically from source.
function M.parse(src, sh)
  local nextf = make_parser(src, sh) -- yields logical-line groups { stmts, perr }
  local stmts, lines = {}, {}
  while true do
    local lg = nextf(); if not lg then break end
    lines[#lines + 1] = lg
    for _, st in ipairs(lg.stmts) do stmts[#stmts + 1] = st end
    if lg.perr then stmts[#stmts + 1] = lg.perr end -- flatten for eager callers/compiler
  end
  return { stmts = stmts, lines = lines }
end

-- Lazy/incremental parse: returns an iterator yielding one top-level statement
-- per call (nil at EOF). The interpreter uses this for instant start on large
-- scripts and to never tokenize past an `exit` (hybrid installers). `sh` (present
-- when interpreting) makes alias expansion use the live runtime alias table.
function M.open(src, sh) return make_parser(src, sh) end

return M
