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
local function arith(src)
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

  local function primary()
    skip()
    local c = src:sub(i, i)
    if c == "(" then
      i = i + 1
      local e = parseExpr(0)
      if not eat(")") then error("arith: expected )") end
      return e
    end
    if eat("++") then return { k = "pre", name = ident(), d = 1 } end
    if eat("--") then return { k = "pre", name = ident(), d = -1 } end
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
      local s, e = src:find("^%d+", i); i = e + 1
      return { k = "num", v = src:sub(s, e) }
    end
    -- a name: could be a var, an assignment (name=…, name+=…), or i++/i--
    local name = ident()
    -- post ++/--
    if starts("++") then i = i + 2; return { k = "post", name = name, d = 1 } end
    if starts("--") then i = i + 2; return { k = "post", name = name, d = -1 } end
    -- assignment operators
    for _, op in ipairs({ "+=", "-=", "*=", "/=", "%=" }) do
      if starts(op) then i = i + #op; return { k = "asgn", name = name, op = op, e = parseExpr(0) } end
    end
    if starts("=") and src:sub(i + 1, i + 1) ~= "=" then
      i = i + 1; return { k = "asgn", name = name, op = "=", e = parseExpr(0) }
    end
    return { k = "var", name = name }
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

  local e = parseExpr(0)
  skip()
  if i <= n then error("arith: trailing input '" .. src:sub(i) .. "'") end
  return e
end
M.arith = arith

-- ---- statement parser ----
-- Captures a balanced `((` … `))` starting just after the opening `((`.
local function grab_dparen(src, i)
  local depth, start = 1, i
  while i <= #src do
    local two = src:sub(i, i + 1)
    if two == "((" then depth = depth + 1; i = i + 2
    elseif two == "))" then depth = depth - 1; if depth == 0 then return src:sub(start, i - 1), i + 2 end; i = i + 2
    elseif src:sub(i, i) == "(" then depth = depth + 1; i = i + 1
    elseif src:sub(i, i) == ")" then depth = depth - 1; i = i + 1
    else i = i + 1 end
  end
  error("unterminated ((")
end

-- Parse the inside of ${ … } into a word part. Plain forms stay {var}/{param}/
-- {special}; anything with an operator becomes {pexp={name, op, arg, arg2}} which
-- Shell:expand_param interprets. `arg`/`arg2` are raw text (the caller expands
-- them before applying the operator, so ${v:-$x} and pattern vars work).
local function split_subst(s) -- "pat/repl" or "pat" -> pat, repl
  local slash = s:find("/", 1, true)
  if slash then return s:sub(1, slash - 1), s:sub(slash + 1) end
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
    local close = rest:find("]", 2, true)
    if close then index = rest:sub(2, close - 1); rest = rest:sub(close + 1) end
  end
  if indices then return { pexp = { name = name, op = "indices", index = index } } end
  if lenpfx then return { pexp = { name = name, op = "len", index = index } } end
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
  elseif two == "^^" then return P { op = "^^" }
  elseif one == "^" then return P { op = "^" }
  elseif two == ",," then return P { op = ",," }
  elseif one == "," then return P { op = "," }
  elseif one == ":" then
    local body = rest:sub(2)
    local off, len = body:match("^(.-):(.+)$")
    if off then return P { op = "sub", arg = off, arg2 = len } end
    return P { op = "sub", arg = body }
  end
  return { var = name }
end
M.parse_paramexp = parse_paramexp

-- Parse a $… expansion at position i of string w; add(part) tagging it with the
-- quoted flag q; returns the next index. (q drives word-splitting downstream.)
local function parse_dollar(w, i, add, q)
  local nx = w:sub(i + 1, i + 1)
  if w:sub(i + 1, i + 2) == "((" then
    local body, ni = grab_dparen(w, i + 3); add({ arith = body, q = q }); return ni
  elseif nx == "(" then
    local depth, j = 1, i + 2
    while j <= #w do
      local c2 = w:sub(j, j)
      if c2 == "(" then depth = depth + 1
      elseif c2 == ")" then depth = depth - 1; if depth == 0 then break end end
      j = j + 1
    end
    add({ cmdsub = w:sub(i + 2, j - 1), q = q }); return j + 1
  elseif nx == "{" then
    local e = w:find("}", i + 2, true) or #w
    local part = parse_paramexp(w:sub(i + 2, e - 1)); part.q = q; add(part); return e + 1
  elseif nx:match("%d") then
    add({ param = tonumber(nx), q = q }); return i + 2
  elseif nx == "#" or nx == "@" or nx == "*" or nx == "?" or nx == "$" or nx == "!" then
    add({ special = nx, q = q }); return i + 2
  else
    local s, e = w:find("^%$([%a_][%w_]*)", i)
    if s then add({ var = w:sub(s + 1, e), q = q }); return e + 1
    else add({ lit = "$", q = q }); return i + 1 end
  end
end

-- Parse the inside of a "…" (everything is quoted): $ expansions + literals,
-- honoring \$ \" \\ \` escapes.
local function parse_dquote(inner, add)
  local i = 1
  while i <= #inner do
    local c = inner:sub(i, i)
    if c == "\\" then
      local nx = inner:sub(i + 1, i + 1)
      if nx == "$" or nx == '"' or nx == "\\" or nx == "`" then add({ lit = nx, q = true }); i = i + 2
      else add({ lit = "\\", q = true }); i = i + 1 end
    elseif c == "$" then
      i = parse_dollar(inner, i, add, true)
    else
      local s, e = inner:find("^[^$\\]+", i); add({ lit = inner:sub(s, e), q = true }); i = e + 1
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
    elseif c == '"' then -- double quotes: expand inside, quoted
      local j = i + 1
      while j <= #w and w:sub(j, j) ~= '"' do
        if w:sub(j, j) == "\\" then j = j + 2 else j = j + 1 end
      end
      parse_dquote(w:sub(i + 1, j - 1), add); i = j + 1
    elseif c == "$" then
      i = parse_dollar(w, i, add, false)
    else
      local s, e = w:find("^[^$'\"]+", i)
      add({ lit = w:sub(s, e), q = false }); i = e + 1
    end
  end
  return { k = "word", parts = parts }
end
M.parse_word = parse_word

-- Parse a heredoc body as double-quote content: $… expands, but quotes are
-- literal (a heredoc doesn't treat ' or " specially). Used when the delimiter
-- was unquoted; a quoted delimiter means no expansion (raw body).
function M.parse_heredoc(body)
  local parts = {}
  parse_dquote(body, function(p) parts[#parts + 1] = p end)
  return { k = "word", parts = parts }
end

-- Parse a [[ … ]] token list into a boolean-expression AST:
--   {kind="and"/"or", l, r} | {kind="not", e} | {kind="str", word}
--   {kind="unary", op, word} | {kind="binary", op, l, r, rq}
-- `rq` marks the RHS of ==/!= as fully-quoted (literal, not a glob).
local function parse_dbracket(toks, quoted)
  local pos = 1
  local function peek() return toks[pos] end
  local parse_or
  local function primary()
    local t = peek()
    if t == "!" then pos = pos + 1; return { kind = "not", e = primary() } end
    if t == "(" then pos = pos + 1; local e = parse_or(); if peek() == ")" then pos = pos + 1 end; return e end
    if t and t:match("^%-[a-zA-Z]$") then -- unary file/string test
      pos = pos + 2; return { kind = "unary", op = t, word = parse_word(toks[pos - 1] or "") }
    end
    pos = pos + 1 -- consume lhs
    local op = peek()
    if op == "==" or op == "!=" or op == "=~" or op == "=" or op == "<" or op == ">"
      or (op and op:match("^%-[a-z][a-z]$")) then
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
  return parse_or()
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
local function classify_brace(inner)
  local a2, b2, s2 = inner:match("^(-?%d+)%.%.(-?%d+)%.%.(-?%d+)$")
  if a2 then return { range = { a = tonumber(a2), b = tonumber(b2), step = math.max(1, math.abs(tonumber(s2))), char = false } } end
  local a, b = inner:match("^(-?%d+)%.%.(-?%d+)$")
  if a then return { range = { a = tonumber(a), b = tonumber(b), step = 1, char = false } } end
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
        go(idx + 1, acc .. (r.char and string.char(v) or tostring(v)))
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
  local function ws()  -- skip spaces/tabs (not newlines)
    while i <= n and src:sub(i, i):match("[ \t]") do i = i + 1 end
  end
  local function skipsep()  -- skip separators: whitespace, newlines, ;, comments
    while i <= n do
      local c = src:sub(i, i)
      if c == "\n" then line = line + 1; i = i + 1
      elseif c:match("[ \t;]") then i = i + 1
      elseif c == "#" then while i <= n and src:sub(i, i) ~= "\n" do i = i + 1 end
      else break end
    end
  end
  local function word(stop_paren)  -- read one shell word, keeping quotes and $(( )) / ${ } / $( ) balanced
    ws()
    local start = i
    while i <= n do
      local c = src:sub(i, i)
      if stop_paren and (c == ")" or c == "(") then break
      elseif c == '"' or c == "'" then
        local q = c; i = i + 1
        while i <= n and src:sub(i, i) ~= q do i = i + 1 end
        i = i + 1 -- past closing quote
      elseif c == "$" and src:sub(i + 1, i + 2) == "((" then
        local _, ni = grab_dparen(src, i + 3); i = ni
      elseif c == "$" and src:sub(i + 1, i + 1) == "(" then
        i = i + 2; local d = 1
        while i <= n and d > 0 do
          local cc = src:sub(i, i)
          if cc == "(" then d = d + 1 elseif cc == ")" then d = d - 1 end
          i = i + 1
        end
      elseif c == "$" and src:sub(i + 1, i + 1) == "{" then
        local e = src:find("}", i + 2, true); i = (e or n) + 1
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

  local parse_stmt -- forward: the and-or wrapper (used by case bodies below)

  -- Try to read a redirection at the current position; returns a redir table and
  -- advances i, or nil (leaving i put) if there isn't one. Handles
  -- [N]> [N]>> [N]< >&M N>&M &> [N]>&- ; heredocs (<<) are left to parse_command.
  local function parse_redir()
    local p = i
    local fd = src:match("^%d+", p)
    local q = fd and (p + #fd) or p
    local c = src:sub(q, q)
    local op, tfd
    if c == ">" then
      if src:sub(q, q + 1) == ">&" then op = "dup"; tfd = fd and tonumber(fd) or 1; q = q + 2
      elseif src:sub(q, q + 1) == ">>" then op = "app"; tfd = fd and tonumber(fd) or 1; q = q + 2
      else op = "out"; tfd = fd and tonumber(fd) or 1; q = q + 1 end
    elseif c == "<" then
      if src:sub(q, q + 2) == "<<<" then -- herestring: <<< word
        i = q + 3; ws()
        return { op = "herestring", fd = 0, word = word() } -- raw word (expanded at runtime)
      end
      if src:sub(q, q + 1) == "<<" then -- heredoc: <<[-] DELIM  (body collected after the line)
        local strip = false; q = q + 2
        if src:sub(q, q) == "-" then strip = true; q = q + 1 end
        i = q; ws()
        local draw = word()
        local quoted = draw:sub(1, 1) == "'" or draw:sub(1, 1) == '"'
        local r = { op = "heredoc", fd = 0, delim = unquote(draw), expand = not quoted, strip = strip }
        heredocs_pending[#heredocs_pending + 1] = r
        return r
      end
      if src:sub(q, q + 1) == "<&" then op = "dupin"; tfd = fd and tonumber(fd) or 0; q = q + 2
      else op = "in"; tfd = fd and tonumber(fd) or 0; q = q + 1 end
    elseif c == "&" and src:sub(q, q + 1) == "&>" then op = "outboth"; tfd = 1; q = q + 2
    else return nil end
    i = q; ws()
    local target = unquote(word())
    return { fd = tfd, op = op, target = target }
  end

  local function parse_command()
    ws()
    -- function NAME [()] { … }   or   NAME() { … }
    if peekword() == "function" then
      ws(); i = i + 8; ws()
      local s, e = src:find("^[%a_][%w_]*", i)
      if not s then error("function needs a name") end
      local nm = src:sub(s, e); i = e + 1; ws()
      if src:sub(i, i + 1) == "()" then i = i + 2 end
      return { t = "funcdef", name = nm, body = brace_group() }
    end
    do
      local s, e = src:find("^[%a_][%w_]*", i)
      if s then
        local j = e + 1
        while src:sub(j, j):match("[ \t]") do j = j + 1 end
        if src:sub(j, j + 1) == "()" then
          local nm = src:sub(s, e); i = j + 2
          return { t = "funcdef", name = nm, body = brace_group() }
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
          body = body_stmts }
      end
      -- for NAME in WORDS
      local s, e = src:find("^[%a_][%w_]*", i)
      if not s then error("subset: for needs a name or ((") end
      local name = src:sub(s, e); i = e + 1
      ws()
      if peekword() == "in" then i = i + 2 else error("subset: for NAME needs 'in'") end
      local words = {}
      while true do
        ws()
        local c = src:sub(i, i)
        if c == ";" or c == "\n" or c == "" or c == "#" then break end
        if peekword() == "do" then break end
        local w = word(); if w == "" then break end
        add_word(words, w)
      end
      loopId = loopId + 1; local id = loopId
      skipsep()
      if peekword() == "do" then i = i + 2 end
      local body_stmts = parse_stmts({ done = true })
      return { t = "forin", id = id, line = ln, name = name, words = words, body = body_stmts }
    end
    -- while/until COND; do BODY; done  — COND is a command list; the loop runs
    -- while its exit status is 0 (until: while it's non-zero). `while (( expr ))`
    -- works because (( )) parses as an arithcmd statement inside COND.
    if peekword() == "while" or peekword() == "until" then
      local kind = peekword(); local ln = line; i = i + #kind
      loopId = loopId + 1; local id = loopId
      local cond = parse_stmts({ ["do"] = true })
      local body_stmts = parse_stmts({ done = true })
      return { t = "whilec", id = id, line = ln, cond = cond, body = body_stmts,
        negate = (kind == "until") }
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
      return { t = "if", line = ln, clauses = clauses }
    end
    -- (( expr )) arithmetic command: exit status 0 if expr != 0, else 1.
    if src:sub(i, i + 1) == "((" then
      local body, ni = grab_dparen(src, i + 2); i = ni
      return { t = "arithcmd", line = line, expr = arith(body) }
    end
    -- [[ EXPR ]] conditional (no word-splitting; == is glob, =~ is regex)
    if src:sub(i, i + 1) == "[[" and src:sub(i + 2, i + 2):match("[ \t]") then
      i = i + 2
      local toks, quoted = {}, {}
      while true do
        ws()
        if i > n or src:sub(i, i) == "\n" then break end
        if src:sub(i, i + 1) == "]]" then i = i + 2; break end
        local w = word()
        if w == "" then break end
        local c1 = w:sub(1, 1)
        toks[#toks + 1] = w
        quoted[#toks] = (c1 == '"' or c1 == "'")
      end
      return { t = "dbracket", line = line, expr = parse_dbracket(toks, quoted) }
    end
    -- case WORD in  PAT|PAT) BODY ;;  … esac
    if peekword() == "case" then
      local ln = line; i = i + 4; ws()
      local subject = parse_word(word())
      ws(); if peekword() == "in" then i = i + 2 end
      -- separator skipper that STOPS at ;; (so a clause body ends there)
      local function skip_sep()
        while i <= n do
          if src:sub(i, i + 1) == ";;" then return "dsemi" end
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
        local patstr = {}
        while i <= n and src:sub(i, i) ~= ")" do patstr[#patstr + 1] = src:sub(i, i); i = i + 1 end
        i = i + 1 -- skip )
        local pats = {}
        for p in table.concat(patstr):gmatch("[^|]+") do pats[#pats + 1] = (p:gsub("^%s+", ""):gsub("%s+$", "")) end
        local body = {}
        while true do
          local s = skip_sep()
          if s == "dsemi" then i = i + 2; break end
          if s == "eof" or peekword() == "esac" then break end
          local st = parse_stmt()
          if not st then break end
          body[#body + 1] = st
        end
        clauses[#clauses + 1] = { pats = pats, body = body }
      end
      return { t = "case", line = ln, subject = subject, clauses = clauses }
    end
    -- assignment: NAME=RHS, NAME[i]=RHS, NAME+=RHS, NAME=(array literal)
    do
      local name = src:match("^([%a_][%w_]*)", i)
      if name then
        local p = i + #name
        local subidx = nil
        if src:sub(p, p) == "[" then
          local close = src:find("]", p + 1, true)
          if close and src:sub(close + 1, close + 1):match("[+=]") then
            subidx = src:sub(p + 1, close - 1); p = close + 1
          end
        end
        local op = nil
        if src:sub(p, p + 1) == "+=" then op = "+="; p = p + 2
        elseif src:sub(p, p) == "=" then op = "="; p = p + 1 end
        if op then
          local ln = line; i = p
          if src:sub(i, i) == "(" then -- array literal
            i = i + 1
            local elems = {}
            while i <= n do
              ws()
              local c = src:sub(i, i)
              if c == ")" then i = i + 1; break end
              if c == "\n" then line = line + 1; i = i + 1
              elseif c == "" then break
              else local w = word(true); if w == "" then break end; elems[#elems + 1] = parse_word(w) end
            end
            return { t = "arrayassign", name = name, line = ln, elems = elems, append = (op == "+=") }
          end
          local raw = word()
          if not subidx and op == "=" and raw:sub(1, 3) == "$((" and raw:sub(-2) == "))" then
            return { t = "assign", name = name, line = ln, arith = arith(raw:sub(4, -3)) }
          end
          return { t = "assign", name = name, line = ln, index = subidx,
            append = (op == "+="), rhs = parse_word(raw) }
        end
      end
    end
    -- simple command: WORD WORD ...
    local ln = line
    local words = {}
    local redirs = {}
    while i <= n do
      local c = src:sub(i, i)
      local r = parse_redir() -- also catches &> before the & break below
      if r then redirs[#redirs + 1] = r
      elseif c == "\n" or c == ";" or c == "#" or c == "&" or c == "|" then break
      elseif c:match("[ \t]") then ws()
      else
        local w = word()
        if w == "" then break end
        add_word(words, w)
      end
    end
    -- collect any heredoc bodies (they follow this command's line)
    if #heredocs_pending > 0 then
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
    if #words == 0 and #redirs == 0 then return nil end
    return { t = "simple", line = ln, words = words, redirs = (#redirs > 0 and redirs or nil) }
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
    local items = nil
    while true do
      ws()
      local two = src:sub(i, i + 1)
      if two == "&&" or two == "||" then
        i = i + 2
        items = items or { { op = nil, cmd = head } }
        items[#items + 1] = { op = two, cmd = parse_pipeline() }
      elseif src:sub(i, i) == "&" then
        i = i + 1 -- background: run in foreground (stdout comparison unaffected)
      else
        break
      end
    end
    if items then return { t = "andor", items = items } end
    return head
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
      local pw = peekword()
      if pw and stopset[pw] then i = i + #pw; return stmts, pw end
      local st = parse_stmt()
      if st then stmts[#stmts + 1] = st end
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
  local function next_toplevel()
    if done then return nil end
    while true do
      skipsep()
      if i > n then done = true; return nil end
      local start, startline = i, line
      local ok, st = pcall(parse_stmt)
      if not ok then done = true; return { t = "parse_error", line = startline, msg = tostring(st) } end
      if st == nil then
        if i <= start then done = true; return nil end -- no progress: stop
      else
        return st
      end
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
