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

  -- binary operators by precedence (higher binds tighter)
  local BIN = {
    ["||"] = 1, ["&&"] = 2,
    ["=="] = 3, ["!="] = 3, ["<"] = 4, ["<="] = 4, [">"] = 4, [">="] = 4,
    ["+"] = 5, ["-"] = 5, ["*"] = 6, ["/"] = 6, ["%"] = 6,
  }
  -- longest-match order so "<=" beats "<", "==" beats "="
  local OPS = { "||", "&&", "==", "!=", "<=", ">=", "<", ">", "+", "-", "*", "/", "%" }

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
      local right = parseExpr(prec + 1)
      left = { k = "bin", op = op, l = left, r = right }
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

-- A word is a list of parts: {lit=s} | {var=name} | {arith=src}.
local function parse_word(w)
  local parts, i = {}, 1
  while i <= #w do
    local c = w:sub(i, i)
    if c == "$" then
      if w:sub(i + 1, i + 2) == "((" then
        local body, ni = grab_dparen(w, i + 3)
        parts[#parts + 1] = { arith = body }; i = ni
      elseif w:sub(i + 1, i + 1) == "{" then
        local e = w:find("}", i + 2, true)
        parts[#parts + 1] = { var = w:sub(i + 2, e - 1) }; i = e + 1
      else
        local s, e = w:find("^%$([%a_][%w_]*)", i)
        if s then parts[#parts + 1] = { var = w:sub(s + 1, e) }; i = e + 1
        else parts[#parts + 1] = { lit = "$" }; i = i + 1 end
      end
    else
      local s, e = w:find("^[^$]+", i)
      parts[#parts + 1] = { lit = w:sub(s, e) }; i = e + 1
    end
  end
  return { k = "word", parts = parts }
end
M.parse_word = parse_word

-- strip surrounding quotes from a raw shell word (subset: whole-word "…" or '…')
local function unquote(w)
  if #w >= 2 and ((w:sub(1, 1) == '"' and w:sub(-1) == '"') or (w:sub(1, 1) == "'" and w:sub(-1) == "'")) then
    return w:sub(2, -2)
  end
  return w
end

function M.parse(src)
  local i, n, line = 1, #src, 1
  local loopId = 0
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
  local function word()  -- read one shell word, keeping quotes and $(( )) / ${ } / $( ) balanced
    ws()
    local start = i
    while i <= n do
      local c = src:sub(i, i)
      if c == '"' or c == "'" then
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

  local function parse_stmt()
    ws()
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
        words[#words + 1] = parse_word(unquote(w))
      end
      loopId = loopId + 1; local id = loopId
      skipsep()
      if peekword() == "do" then i = i + 2 end
      local body_stmts = parse_stmts({ done = true })
      return { t = "forin", id = id, line = ln, name = name, words = words, body = body_stmts }
    end
    -- while (( cond )); do BODY done
    if peekword() == "while" then
      local ln = line; ws(); i = i + 5; ws()
      if src:sub(i, i + 1) ~= "((" then error("subset: while needs (( ))") end
      local body, ni = grab_dparen(src, i + 2); i = ni
      loopId = loopId + 1; local id = loopId
      skipsep()
      if peekword() == "do" then i = i + 2 end
      local body_stmts = parse_stmts({ done = true })
      return { t = "whilec", id = id, line = ln, cond = arith(body), body = body_stmts }
    end
    -- if (( cond )); then BODY [elif (( c )); then BODY]* [else BODY] fi
    if peekword() == "if" then
      local ln = line; ws(); i = i + 2
      local function cond()
        ws()
        if src:sub(i, i + 1) ~= "((" then error("subset: if needs (( ))") end
        local body, ni = grab_dparen(src, i + 2); i = ni
        return arith(body)
      end
      local clauses = {}
      while true do
        local c = cond()
        parse_stmts({ ["then"] = true }) -- skip to 'then'
        local body, term = parse_stmts({ elif = true, ["else"] = true, fi = true })
        clauses[#clauses + 1] = { cond = c, body = body }
        if term == "else" then
          local eb = parse_stmts({ fi = true })
          clauses[#clauses + 1] = { cond = nil, body = eb }
          break
        elseif term == "fi" then break
        elseif term ~= "elif" then error("if: missing fi") end
      end
      return { t = "if", line = ln, clauses = clauses }
    end
    -- assignment: NAME=RHS
    do
      local s, e = src:find("^[%a_][%w_]*=", i)
      if s then
        local ln = line
        local name = src:sub(s, e - 1); i = e + 1 -- skip past '='
        local raw = word()
        if raw:sub(1, 3) == "$((" and raw:sub(-2) == "))" then
          return { t = "assign", name = name, line = ln, arith = arith(raw:sub(4, -3)) }
        end
        return { t = "assign", name = name, line = ln, rhs = parse_word(unquote(raw)) }
      end
    end
    -- simple command: WORD WORD ...
    local ln = line
    local words = {}
    while i <= n do
      local c = src:sub(i, i)
      if c == "\n" or c == ";" or c == "#" then break end
      if c:match("[ \t]") then ws()
      else
        local w = word()
        if w == "" then break end
        if w == "done" or w == "do" then i = i - #w; break end
        words[#words + 1] = parse_word(unquote(w))
      end
    end
    if #words == 0 then return nil end
    return { t = "simple", line = ln, words = words }
  end

  -- Parse statements until a terminator keyword in `stopset` (consumed and
  -- returned) or EOF. Returns (stmts, terminator-or-nil).
  parse_stmts = function(stopset)
    stopset = stopset or {}
    local stmts = {}
    while true do
      skipsep()
      if i > n then return stmts, nil end
      local pw = peekword()
      if pw and stopset[pw] then i = i + #pw; return stmts, pw end
      local st = parse_stmt()
      if st then stmts[#stmts + 1] = st end
    end
  end

  return { stmts = (parse_stmts({})) }
end

return M
