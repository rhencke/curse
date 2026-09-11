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
  if not nodefer and (src:find("%${") or src:find("%$%(") or src:find("`")
      or src:find("[%w_]%$") or src:find("%$[^%w_{]")) then
    return { k = "xpand", raw = src }
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
local function parse_paramexp(inner)
  if inner == "" then return { lit = "" } end
  if inner == "#" then return { special = "#" } end
  local indices, lenpfx = false, false
  if inner:sub(1, 1) == "!" then indices = true; inner = inner:sub(2)     -- ${!a[@]}
  elseif inner:sub(1, 1) == "#" then lenpfx = true; inner = inner:sub(2) end -- ${#v} / ${#a[@]}
  local name, rest = inner:match("^([%a_][%w_]*)(.*)$")
  if not name then name, rest = inner:match("^(%d+)(.*)$") end
  if not name then name, rest = inner:match("^([@*])(.*)$") end
  if not name then return { var = inner } end
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
  end
  if indices then
    -- ${!a[@]}/${!a[*]} = keys; ${!pfx@}/${!pfx*} = var names with that prefix;
    -- ${!name} = indirect (value of the var named by name)
    -- ${!a[@]@X}: a transform after the keys yields empty in bash (assoc); mark it.
    if index == "@" or index == "*" then return { pexp = { name = name, op = "indices", index = index, drop = (rest ~= "" or nil) } } end
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
    -- split off the FIRST colon: ${x:off:len}; ${x::} means off=0, len=0 (empty).
    local colon = body:find(":", 1, true)
    if colon then return P { op = "sub", arg = body:sub(1, colon - 1), arg2 = body:sub(colon + 1) } end
    return P { op = "sub", arg = body }
  end
  -- Any trailing text that is not a recognized modifier is a bad substitution
  -- (e.g. `${x|html}`, `${1abc}`, `${a b}`) — bash aborts with status 1.
  return P { op = "badsubst", raw = name .. rest }
end
M.parse_paramexp = parse_paramexp

-- Parse a $… expansion at position i of string w; add(part) tagging it with the
-- quoted flag q; returns the next index. (q drives word-splitting downstream.)
local function parse_dollar(w, i, add, q)
  local nx = w:sub(i + 1, i + 1)
  if w:sub(i + 1, i + 2) == "((" then
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
    local depth, j = 1, i + 2
    while j <= #w do
      local c2 = w:sub(j, j)
      if c2 == "(" then depth = depth + 1
      elseif c2 == ")" then depth = depth - 1; if depth == 0 then break end end
      j = j + 1
    end
    add({ cmdsub = w:sub(i + 2, j - 1), q = q }); return j + 1
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
    -- find the MATCHING } (nested ${…} inside a default/operator value)
    local depth, j = 1, i + 2
    while j <= #w do
      local ch = w:sub(j, j)
      if ch == "{" then depth = depth + 1
      elseif ch == "}" then depth = depth - 1; if depth == 0 then break end end
      j = j + 1
    end
    local part = parse_paramexp(w:sub(i + 2, j - 1)); part.q = q; add(part); return j + 1
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
      if nx == "$" or (nx == '"' and not heredoc) or nx == "\\" or nx == "`" then add({ lit = nx, q = true }); i = i + 2
      else add({ lit = "\\", q = true }); i = i + 1 end
    elseif c == "$" then
      i = parse_dollar(inner, i, add, true)
    elseif c == "`" then -- `cmd` command substitution inside "…"
      local j, buf = i + 1, {}
      while j <= #inner and inner:sub(j, j) ~= "`" do
        if inner:sub(j, j) == "\\" and inner:sub(j + 1, j + 1):match("[`$\\]") then buf[#buf + 1] = inner:sub(j + 1, j + 1); j = j + 2
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
local function parse_word(w)
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
        elseif d == "$" and w:sub(j + 1, j + 1) == "{" then -- ${...}: inner " isn't the close
          j = j + 2; local dep = 1
          while j <= #w and dep > 0 do
            local cc = w:sub(j, j)
            if cc == "{" then dep = dep + 1 elseif cc == "}" then dep = dep - 1 end
            j = j + 1
          end
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
  local parse_or
  local function primary()
    local t = peek()
    if t == nil then serr = true; return { kind = "str", word = parse_word("") } end -- expected an operand
    if t == "!" then pos = pos + 1; return { kind = "not", e = primary() } end
    if t == "(" then pos = pos + 1; local e = parse_or(); if peek() == ")" then pos = pos + 1 else serr = true end; return e end
    if t and t:match("^%-[a-zA-Z]$") then -- unary file/string test
      if toks[pos + 1] == nil then serr = true end -- a unary op needs an operand
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
    if c == "'" or c == '"' then
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

local function make_parser(src)
  local i, n, line = 1, #src, 1
  local loopId = 0
  local heredocs_pending = {} -- heredoc redirs awaiting their body (filled at line end)
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
  local function word(stop_paren, stop_cmp)  -- read one shell word, keeping quotes and $(( )) / ${ } / $( ) balanced
    ws()
    local start = i
    while i <= n do
      local c = src:sub(i, i)
      if c == "\\" then i = i + 2 -- backslash escapes the next char (incl. metachars/space)
      elseif stop_paren and (c == ")" or c == "(") then break
      elseif c == '"' then -- double quotes: honor \" and skip $(..)/$((..))/`..`
        i = i + 1                                        -- (their inner " are not the close)
        while i <= n and src:sub(i, i) ~= '"' do
          local d = src:sub(i, i)
          if d == "\\" then i = i + 2
          elseif d == "$" and src:sub(i + 1, i + 2) == "((" then local _, ni = grab_dparen(src, i + 3); i = ni
          elseif d == "$" and src:sub(i + 1, i + 1) == "(" then
            i = i + 2; local dep = 1
            while i <= n and dep > 0 do
              local cc = src:sub(i, i)
              if cc == "(" then dep = dep + 1 elseif cc == ")" then dep = dep - 1 end
              i = i + 1
            end
          elseif d == "$" and src:sub(i + 1, i + 1) == "{" then
            -- ${…} brace-matched: its inner " / nested ${} are NOT the outer close
            i = i + 2; local dep = 1
            while i <= n and dep > 0 do
              local cc = src:sub(i, i)
              if cc == "\\" then i = i + 1
              elseif cc == "{" then dep = dep + 1
              elseif cc == "}" then dep = dep - 1 end
              i = i + 1
            end
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
      elseif c == "$" and src:sub(i + 1, i + 2) == "((" then
        local _, ni = grab_dparen(src, i + 3); i = ni
      elseif c == "$" and src:sub(i + 1, i + 1) == "[" then -- $[expr]: keep whole (spaces inside)
        i = i + 2; local d = 1
        while i <= n and d > 0 do
          local cc = src:sub(i, i)
          if cc == "[" then d = d + 1 elseif cc == "]" then d = d - 1 end
          i = i + 1
        end
      elseif c == "$" and src:sub(i + 1, i + 1) == "(" then
        i = i + 2; local d = 1
        while i <= n and d > 0 do
          local cc = src:sub(i, i)
          if cc == "(" then d = d + 1 elseif cc == ")" then d = d - 1 end
          i = i + 1
        end
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
      elseif stop_cmp and (c == "<" or c == ">") then break -- [[ ]]: <,> are operators
      elseif c == "$" and src:sub(i + 1, i + 1) == "{" then
        local e = src:find("}", i + 2, true); i = (e or n) + 1
      elseif c == "`" then -- `…` command sub: keep it whole (spaces inside included)
        i = i + 1
        while i <= n and src:sub(i, i) ~= "`" do
          if src:sub(i, i) == "\\" then i = i + 2 else i = i + 1 end
        end
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
  local function funcdef_node(nm)
    local body = func_body()
    local redirs = {}
    while true do ws(); local r = parse_redir(); if r then redirs[#redirs + 1] = r else break end end
    return { t = "funcdef", name = nm, body = body, redirs = (#redirs > 0 and redirs or nil) }
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
        local quoted = draw:sub(1, 1) == "'" or draw:sub(1, 1) == '"'
        local r = { op = "heredoc", fd = fd and tonumber(fd) or 0, delim = unquote(draw), expand = not quoted, strip = strip, fdvar = fdvar }
        heredocs_pending[#heredocs_pending + 1] = r
        return r
      end
      if src:sub(q, q + 1) == "<>" then op = "rw"; tfd = fd and tonumber(fd) or 0; q = q + 2 -- open for read+write
      elseif src:sub(q, q + 1) == "<&" then op = "dupin"; tfd = fd and tonumber(fd) or 0; q = q + 2
      else op = "in"; tfd = fd and tonumber(fd) or 0; q = q + 1 end
    elseif c == "&" and src:sub(q, q + 2) == "&>>" then op = "appboth"; tfd = 1; q = q + 3
    elseif c == "&" and src:sub(q, q + 1) == "&>" then op = "outboth"; tfd = 1; q = q + 2
    else return nil end
    i = q; ws()
    local target = unquote(word())
    return { fd = tfd, op = op, target = target, fdvar = fdvar }
  end

  local function parse_command()
    ws()
    -- function NAME [()] { … }   or   NAME() { … }
    -- Function names may contain far more than identifier chars (bash: `show-len`,
    -- `git-foo`, `a.b`), so match a run of non-metacharacter word bytes here.
    if peekword() == "function" then
      ws(); i = i + 8; ws()
      local s, e = src:find("^[%w_][%w_%.%-:+@/]*", i)
      if not s then error("function needs a name") end
      local nm = src:sub(s, e); i = e + 1; ws()
      -- optional `( )` (bash: `function f () { … }`, spaces allowed between parens)
      if src:sub(i, i) == "(" then
        local k = i + 1; while src:sub(k, k):match("[ \t]") do k = k + 1 end
        if src:sub(k, k) == ")" then i = k + 1 end
      end
      return funcdef_node(nm)
    end
    do
      local s, e = src:find("^[%w_][%w_%.%-:+@/]*", i)
      if s then
        local j = e + 1
        while src:sub(j, j):match("[ \t]") do j = j + 1 end
        -- NAME ( ) — a space is allowed between the parens (bash: `fun ( ) { … }`)
        if src:sub(j, j) == "(" then
          local k = j + 1; while src:sub(k, k):match("[ \t]") do k = k + 1 end
          if src:sub(k, k) == ")" then
            local nm = src:sub(s, e); i = k + 1
            return funcdef_node(nm)
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
        return { t = "forc", id = id, line = ln,
          init = a:match("%S") and arith(a) or nil,
          cond = b:match("%S") and arith(b) or nil,
          step = c:match("%S") and arith(c) or nil,
          body = body_stmts, redirs = tail_redirs() }
      end
      -- for NAME in WORDS
      local s, e = src:find("^[%a_][%w_]*", i)
      if not s then error("subset: for needs a name or ((") end
      local name = src:sub(s, e); i = e + 1
      ws()
      local words = {}
      if peekword() == "in" then
        i = i + 2
        while true do
          ws()
          local c = src:sub(i, i)
          if c == ";" or c == "\n" or c == "" or c == "#" then break end
          if peekword() == "do" then break end
          local w = word(); if w == "" then break end
          add_word(words, w)
        end
      else
        words = { parse_word('"$@"') } -- `for NAME; do …` iterates the positional params
      end
      loopId = loopId + 1; local id = loopId
      skipsep()
      if peekword() == "do" then i = i + 2 end
      local body_stmts = parse_stmts({ done = true })
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
        clauses[#clauses + 1] = { cond = cond, body = body }
        if term == "else" then
          local eb = parse_stmts({ fi = true })
          clauses[#clauses + 1] = { cond = nil, body = eb }
          break
        elseif term == "fi" then break
        elseif term ~= "elif" then error("if: missing fi") end
      end
      return { t = "if", line = ln, clauses = clauses, redirs = tail_redirs() }
    end
    -- (( expr )) arithmetic command: exit status 0 if expr != 0, else 1.
    if src:sub(i, i + 1) == "((" then
      local body, ni = grab_dparen(src, i + 2); i = ni
      -- a malformed `(( expr ))` (bad lvalue) is a NON-fatal runtime error in bash,
      -- so defer the parse failure to eval (caught by the arithcmd handler) rather
      -- than aborting the whole parse.
      local ok, e = pcall(arith, body)
      return { t = "arithcmd", line = line, expr = ok and e or { k = "matherr" }, redirs = tail_redirs() }
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
          -- the =~ operand is ONE regex word: raw text up to unquoted whitespace at
          -- bracket/paren depth 0 (so `(a  b)` / `[a b]` keep their inner spaces).
          local rs, depth = i, 0
          while i <= n do
            if depth == 0 and (src:sub(i, i + 1) == "]]" or src:sub(i, i) == "\n"
                or src:sub(i, i) == " " or src:sub(i, i) == "\t") then break end
            local ch = src:sub(i, i)
            if ch == "\\" then i = i + 2
            elseif ch == "'" then i = i + 1; while i <= n and src:sub(i, i) ~= "'" do i = i + 1 end; i = i + 1
            elseif ch == '"' then i = i + 1
              while i <= n and src:sub(i, i) ~= '"' do i = i + (src:sub(i, i) == "\\" and 2 or 1) end; i = i + 1
            elseif ch == "(" or ch == "[" then depth = depth + 1; i = i + 1
            elseif (ch == ")" or ch == "]") and depth > 0 then depth = depth - 1; i = i + 1
            else i = i + 1 end
          end
          toks[#toks + 1] = src:sub(rs, i - 1); quoted[#toks] = false
        else
          local before = i
          local w = word(false, true) -- split on <,> operators (no spaces needed in [[ ]])
          if w == "" then
            -- word() stalled on a bare metacharacter (`;`, `)`, `<`, `>`, …) that
            -- is literal inside [[ ]] (e.g. part of a regex operand). Consume it as
            -- its own token so the tokenizer makes progress instead of looping.
            if i == before then w = src:sub(i, i); i = i + 1 else break end
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
      local subject = parse_word(word())
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
          if c == "\n" then line = line + 1; i = i + 1
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
          if not st or i == before then break end -- no progress (e.g. a stray `)`): stop, don't spin
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

    -- leading assignments: prefix env for a following command, else statements
    local ln = line
    local assigns = {}
    while true do
      local a = try_assign()
      if not a then break end
      a.line = ln; assigns[#assigns + 1] = a
      ws()
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
    local redirs = {}
    local arrayargs = nil -- `NAME=(...)` args to a declaration builtin
    while i <= n do
      local c = src:sub(i, i)
      local r = parse_redir() -- also catches &> before the & break below
      if r then redirs[#redirs + 1] = r
      elseif c == "\n" or c == ";" or c == "#" or c == "&" or c == "|"
        or c == "(" or c == ")" then break -- ( ) are metacharacters (subshell bounds)
      elseif c:match("[ \t]") then ws()
      else
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
    return { t = "simple", line = ln, words = words, redirs = (#redirs > 0 and redirs or nil),
      assigns = (#assigns > 0 and assigns or nil), arrayargs = arrayargs }
  end

  -- pipeline: cmd [ | cmd ]*   (optional leading `!` negates the exit status)
  local function parse_pipeline()
    ws()
    local negate = false
    if src:sub(i, i + 1) == "! " then negate = true; i = i + 2; ws() end
    local first = parse_command()
    local cmds = { first }
    while true do
      ws()
      -- a single `|` (not `||`) chains another command into the pipeline
      if src:sub(i, i) == "|" and src:sub(i + 1, i + 1) ~= "|" then
        i = i + 1
        -- bash allows spaces, a comment, and newlines after `|` before the next cmd
        while true do
          ws()
          if src:sub(i, i) == "#" then while i <= n and src:sub(i, i) ~= "\n" do i = i + 1 end
          elseif src:sub(i, i) == "\n" then line = line + 1; i = i + 1
          else break end
        end
        cmds[#cmds + 1] = parse_command()
      else
        break
      end
    end
    if #cmds == 1 and not negate then return first end
    return { t = "pipeline", cmds = cmds, negate = negate }
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
      skipsep()
      if i > n then return stmts, nil end
      if stopset["}"] and src:sub(i, i) == "}" then i = i + 1; return stmts, "}" end
      if stopset[")"] and src:sub(i, i) == ")" then i = i + 1; return stmts, ")" end
      local pw = peekword()
      if pw and stopset[pw] then i = i + #pw; return stmts, pw end
      local before = i
      local st = parse_stmt()
      if st then stmts[#stmts + 1] = st
      elseif i == before then
        -- no progress: a stray metacharacter/keyword in command position (`)`, `}`,
        -- `;;`, `do`, …) — a syntax error, and a guard against an infinite loop.
        error("syntax error near `" .. src:sub(i, i) .. "'")
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
  local queue, qi = {}, 0 -- statements from a heredoc-bearing line, drained in order
  local function next_toplevel()
    if qi < #queue then qi = qi + 1; return queue[qi] end
    if done then return nil end
    while true do
      skipsep()
      if i > n then done = true; return nil end
      local start, startline = i, line
      local ok, st = pcall(parse_stmt)
      if not ok then done = true; return { t = "parse_error", line = startline, msg = tostring(st) } end
      -- Lazy mode executes each statement before parsing the next, but a heredoc's
      -- body follows the whole LINE's newline. So if this statement opened one,
      -- parse the rest of the physical line's `;`-separated statements first, then
      -- collect every body in order — and hand them back one at a time.
      if ok and #heredocs_pending > 0 then
        local stmts = { st }
        while true do
          while i <= n and src:sub(i, i):match("[ \t;]") do i = i + 1 end
          if i > n or src:sub(i, i) == "\n" then break end
          local ok2, st2 = pcall(parse_stmt)
          if not ok2 or st2 == nil then break end
          stmts[#stmts + 1] = st2
        end
        collect_heredocs() -- now at the newline: reads all pending bodies in order
        queue, qi = stmts, 1
        return stmts[1]
      end
      -- No progress (a stray `)`/`}` etc. yields an empty node or nil without
      -- advancing): stop, so the lazy top-level loop can't spin forever.
      if i <= start then done = true; return nil end
      if st ~= nil then return st end
    end
  end
  return next_toplevel
end

-- Eager full parse -> { stmts } (used by the compiler, which needs the whole
-- program, and by callers that want the AST).
function M.parse(src)
  local nextf = make_parser(src)
  local stmts = {}
  while true do local s = nextf(); if not s then break end; stmts[#stmts + 1] = s end
  return { stmts = stmts }
end

-- Lazy/incremental parse: returns an iterator yielding one top-level statement
-- per call (nil at EOF). The interpreter uses this for instant start on large
-- scripts and to never tokenize past an `exit` (hybrid installers).
function M.open(src) return make_parser(src) end

return M
