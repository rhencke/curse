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

-- A word is a list of parts:
--   {lit=s} | {var=name} | {arith=src} | {param=n} | {special=c} | {pexp=…}
local function parse_word(w)
  local parts, i = {}, 1
  while i <= #w do
    local c = w:sub(i, i)
    if c == "$" then
      local n = w:sub(i + 1, i + 1)
      if w:sub(i + 1, i + 2) == "((" then
        local body, ni = grab_dparen(w, i + 3)
        parts[#parts + 1] = { arith = body }; i = ni
      elseif n == "(" then -- $( … ) command substitution
        local depth, j = 1, i + 2
        while j <= #w do
          local c2 = w:sub(j, j)
          if c2 == "(" then depth = depth + 1
          elseif c2 == ")" then depth = depth - 1; if depth == 0 then break end end
          j = j + 1
        end
        parts[#parts + 1] = { cmdsub = w:sub(i + 2, j - 1) }; i = j + 1
      elseif n == "{" then
        local e = w:find("}", i + 2, true)
        parts[#parts + 1] = parse_paramexp(w:sub(i + 2, e - 1)); i = e + 1
      elseif n:match("%d") then
        parts[#parts + 1] = { param = tonumber(n) }; i = i + 2 -- $1..$9 (single digit)
      elseif n == "#" or n == "@" or n == "*" or n == "?" then
        parts[#parts + 1] = { special = n }; i = i + 2
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
      if src:sub(q, q + 1) == "<<" then return nil end -- heredoc/herestring: not here
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
        words[#words + 1] = parse_word(unquote(w))
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
    -- case WORD in  PAT|PAT) BODY ;;  … esac
    if peekword() == "case" then
      local ln = line; i = i + 4; ws()
      local subject = parse_word(unquote(word()))
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
              else local w = word(true); if w == "" then break end; elems[#elems + 1] = parse_word(unquote(w)) end
            end
            return { t = "arrayassign", name = name, line = ln, elems = elems, append = (op == "+=") }
          end
          local raw = word()
          if not subidx and op == "=" and raw:sub(1, 3) == "$((" and raw:sub(-2) == "))" then
            return { t = "assign", name = name, line = ln, arith = arith(raw:sub(4, -3)) }
          end
          return { t = "assign", name = name, line = ln, index = subidx,
            append = (op == "+="), rhs = parse_word(unquote(raw)) }
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
        words[#words + 1] = parse_word(unquote(w))
      end
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

  return { stmts = (parse_stmts({})) }
end

return M
