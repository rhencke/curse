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

local CMP = { ["=="] = "==", ["!="] = "~=", ["<"] = "<", ["<="] = "<=", [">"] = ">", [">="] = ">=" }
local function lname(n) return "v_" .. n end
-- A valid Lua identifier for the closure of shell function `n`. bash function names
-- may hold -/./=/! etc. (`foo-bar`, `my.helper`), which can't spell a Lua local, so
-- escape every non-identifier byte as `_XX_`. sh.functions is still keyed by the
-- original name (the dispatch key); only the generated identifier is mangled.
local function fnlname(n) return "fn_" .. n:gsub("[^%w_]", function(c) return ("_%02x_"):format(c:byte()) end) end

-- Does the program create an ATTRIBUTED variable — one whose later plain `name=value`
-- assignment isn't a simple string set: readonly (reject), an array (write [0]), or
-- declare -i/-l/-u (arith / case-fold)? Detects the attribute BUILTINS and array
-- assignments. When false, compiled scalar assignments are a bare sh:set_str (zero
-- hot-path cost); when true they route through I.assign_scalar. A var attributed via
-- eval is rare and simply unguarded — no worse than before.
local emit_has_attr = false
local function makes_attr(st)
  if st.t == "arrayassign" then return true end        -- a=(…) makes an array
  if st.t == "assign" and st.index then return true end -- a[i]=… makes/extends an array
  if st.t ~= "simple" or not st.words[1] then return false end
  local c = st.words[1].parts[1] and #st.words[1].parts == 1 and st.words[1].parts[1].lit
  if c == "readonly" or c == "declare" or c == "typeset" or c == "local" or c == "export" then return true end
  if c == "set" then -- `set -a` / `set -o allexport` makes later plain assigns auto-export
    for j = 2, #st.words do
      local l = st.words[j].parts[1] and st.words[j].parts[1].lit
      if l == "-a" or l == "allexport" or (l and l:match("^%-%a*a")) then return true end
    end
  end
  return false
end
local function scan_attr(stmts)
  for _, st in ipairs(stmts or {}) do
    if makes_attr(st) then return true end
    if st.body and scan_attr(st.body) then return true end
    if st.clauses then for _, cl in ipairs(st.clauses) do if scan_attr(cl.body) then return true end end end
  end
  return false
end
-- Does the program install a `trap … SIG` for one of `sigs` (a set of names)? Used
-- to gate per-command trap hooks (ERR/DEBUG) so a trap-free script pays nothing.
local function scan_trap(stmts, sigs)
  for _, st in ipairs(stmts or {}) do
    if st.t == "simple" and st.words[1] and st.words[1].parts[1]
        and st.words[1].parts[1].lit == "trap" then
      for j = 2, #st.words do
        local l = st.words[j].parts[1] and st.words[j].parts[1].lit
        if l and sigs[l] then return true end
      end
    end
    if st.body and scan_trap(st.body, sigs) then return true end
    if st.clauses then for _, cl in ipairs(st.clauses) do if scan_trap(cl.body, sigs) then return true end end end
  end
  return false
end

-- serialize a {int->int} pc map to a Lua table literal
local function serialize(t)
  local parts = {}
  for k, v in pairs(t) do parts[#parts + 1] = ("[%d]=%d"):format(k, v) end
  return "{" .. table.concat(parts, ", ") .. "}"
end

-- Serialize an arbitrary AST node (plain tables of strings/numbers/bools) to a
-- Lua literal, so a cold statement can be baked into the compiled source and run
-- by the shared interpreter (delegation). No cycles/functions in the AST.
local function ser(v)
  local t = type(v)
  if t == "string" then return ("%q"):format(v) end
  if t == "number" then return tostring(v) end
  if t == "boolean" then return tostring(v) end
  if t ~= "table" then return "nil" end
  local parts, n = {}, #v
  for i = 1, n do parts[#parts + 1] = ser(v[i]) end
  for k, val in pairs(v) do
    if type(k) ~= "number" or k < 1 or k > n or k ~= math.floor(k) then
      parts[#parts + 1] = ("[%s]=%s"):format(ser(k), ser(val))
    end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- Arith with a side effect (assignment / ++ / --) can't sit in a Lua expression
-- position, so a word containing one must be run by the interpreter, not compiled.
local function arith_side_effect(e)
  if type(e) ~= "table" then return false end
  if e.k == "asgn" or e.k == "post" or e.k == "pre" then return true end
  -- xpand (embedded $-expansion), comma, and array-subscripted operands aren't
  -- compiled natively — treat like a side effect so the word/stmt delegates.
  if e.k == "xpand" or e.k == "comma" or e.idx then return true end
  return arith_side_effect(e.e) or arith_side_effect(e.l) or arith_side_effect(e.r)
    or arith_side_effect(e.c) or arith_side_effect(e.a) or arith_side_effect(e.b)
end
-- Arith the CFG codegen cannot render at all (embedded $-expansion, comma, or
-- array-subscripted operands) — distinct from a mere side effect, which forc
-- init/step legitimately have. Such loops/statements delegate to the interpreter.
local function not_compilable(e)
  if type(e) ~= "table" then return false end
  if e.k == "xpand" or e.k == "comma" or e.idx then return true end
  return not_compilable(e.e) or not_compilable(e.l) or not_compilable(e.r)
    or not_compilable(e.c) or not_compilable(e.a) or not_compilable(e.b)
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
  elseif t == "background" then return stmt_runs_set(st.cmd)
  elseif t == "pipeline" then
    for _, c in ipairs(st.cmds) do if stmt_runs_set(c) then return true end end
  elseif t == "andor" then
    for _, it in ipairs(st.items) do if stmt_runs_set(it.cmd) then return true end end
  elseif t == "if" or t == "case" then
    for _, cl in ipairs(st.clauses) do
      for _, s in ipairs(cl.body) do if stmt_runs_set(s) then return true end end
    end
  elseif st.body then
    for _, s in ipairs(st.body) do if stmt_runs_set(s) then return true end end
  end
  return false
end
local function body_runs_set(list)
  for _, st in ipairs(list) do if stmt_runs_set(st) then return true end end
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
local ERREXIT_TYPES = { simple = 1, pipeline = 1, arithcmd = 1, assign = 1,
  assignlist = 1, subshell = 1, dbracket = 1 }
local ERRCHK = "if sh.opt_e and sh.noerr == 0 and sh.status ~= 0 then error({ __curse_exit = sh.status }) end"
local emit_has_err = false -- program installs an ERR trap → fire it after a failing command
local emit_toplevel = false -- current build_cfg is the top level (ERR only fires there; a
-- compiled function body doesn't track calldepth so it would wrongly fire ERR — bash needs
-- errtrace for that. Subshell bodies live in the top-level CFG but fire_err_trap's runtime
-- in_subprogram check keeps ERR from firing in the forked child.)
local function errchk(st) -- the guard statement for `st`, or "" when errexit never applies
  if not (st and ERREXIT_TYPES[st.t] and not st.negate) then return "" end
  if emit_has_err and emit_toplevel then -- ERR trap fires on the same condition as errexit;
    -- set $LINENO to this command's line for the handler, fire ERR, THEN errexit (bash order).
    return ("if sh.noerr == 0 and sh.status ~= 0 then sh.cur_line = %d; I.fire_err_trap(sh); if sh.opt_e then error({ __curse_exit = sh.status }) end end")
      :format(st.line or 0)
  end
  return ERRCHK
end
local emit_has_debug = false -- program installs a DEBUG trap → fire it before each command
-- The DEBUG-trap prefix for a natively-compiled command (else ""). DEBUG fires BEFORE
-- the command with $LINENO = its line. Top-level only (a compiled function body would
-- wrongly fire without functrace — bash fires DEBUG once at the CALL site, which is a
-- top-level command). Delegated commands fire DEBUG via interp's exec_stmt, so this is
-- prepended ONLY to native blocks (exactly one fires).
local function dbg(st)
  if emit_has_debug and emit_toplevel then return ("I.run_debug(sh, %d); "):format(st.line or 0) end
  return ""
end
-- Special params emit_word knows how to render; any OTHER `$special` (e.g. `$-`,
-- the option string) must delegate, or emit_word would silently render it empty.
local RENDERABLE_SPECIAL = { ["#"] = 1, ["@"] = 1, ["*"] = 1, ["?"] = 1, ["$"] = 1, ["!"] = 1 }
-- A word emit_word can render (no ${..op..} pexp, no side-effecting arith, no
-- unhandled special param).
local function emitable_word(w)
  for _, p in ipairs(w.parts) do
    if p.pexp then return false end
    if p.procsub then return false end -- <(cmd)/>(cmd): needs the interp's temp-file setup
    if p.special and not RENDERABLE_SPECIAL[p.special] then return false end -- e.g. $-
    if p.arith and arith_side_effect(require("parser").arith(p.arith)) then return false end
    if p.arithast and arith_side_effect(p.arithast) then return false end -- inlined arith
  end
  return true
end
-- A word that a compiled command can use directly: emit_word-able AND with no
-- unquoted expansion (would word-split) or unquoted glob char (would path-expand)
-- — those need the interpreter's field engine, so the command is delegated.
local function word_safe(w)
  if not emitable_word(w) then return false end -- pexp / side-effecting arith
  for _, p in ipairs(w.parts) do
    if p.special == "@" or p.special == "*" then return false end -- multi-element (even quoted)
    if not p.q then
      if p.var or p.param or p.special or p.cmdsub then return false end -- unquoted -> splits
      if p.lit and (p.lit:find("[*?%[]") or p.lit:find("[@!+?*]%(")) then return false end -- unquoted glob / extglob
    end
  end
  return true
end

-- How a NON-lifted arith var read is emitted. Default `sh:aget` parses the value's
-- immediate number (fast, used by whilec/forc/arith-word conditions). Inside a
-- (( )) command the arithcmd codegen swaps in I.arith_read, which matches interp
-- exactly (nounset + recursive-name-eval + array decay); codegen is synchronous, so
-- this scoped toggle needs no threading through emit_value's recursion.
local arith_varread = "sh:aget(%q)"

-- The whole word as one literal string when every part is literal — sees through a
-- \-escaped name (`\return` parses as parts "r".."eturn"). nil if any part expands.
local function full_lit(w)
  local s = {}
  for _, p in ipairs(w.parts) do if p.lit == nil then return nil end; s[#s + 1] = p.lit end
  return table.concat(s)
end
-- Recognize a control-flow command (break/continue/return) even when written with a
-- \-escaped name or a `builtin`/`command` prefix (`\return`, `builtin return 3`).
-- Returns op, argoffset (index of the first argument), or nil.
local function resolve_cf(st)
  if st.t ~= "simple" or not st.words[1] or st.redirs then return nil end
  local c, off = full_lit(st.words[1]), 1
  if (c == "builtin" or c == "command") and st.words[2] then c = full_lit(st.words[2]); off = 2 end
  if c == "break" or c == "continue" or c == "return" then return c, off + 1 end
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
      if in_cond then return true end
      local lvlw = st.words[argoff]
      if lvlw and (not (function() local wl = full_lit(lvlw); return wl and wl:match("^%d+$") end)() or st.words[argoff + 1]) then
        return true
      end
    end
    if st.t == "if" then
      for _, cl in ipairs(st.clauses) do if hard_cf(cl.body, in_cond) then return true end end
    elseif st.t == "group" then
      if hard_cf(st.body, in_cond) then return true end
    end
  end
  return false
end

local emit_value
emit_value = function(e, lifted)
  local k = e.k
  if k == "num" then
    if e.v:match("^%d+$") and (e.v == "0" or e.v:sub(1, 1) ~= "0") then return e.v .. "LL" end
    return ("rt.arith_num(%q)"):format(e.v) -- 0x.. / 010 octal / N#.. bases
  end
  if k == "raw" then return e.code end -- a pre-computed Lua expr (inlined param binding)
  if k == "var" then return lifted[e.name] and lname(e.name) or (arith_varread):format(e.name) end
  if k == "param" then return ("rt.str_to_i64(sh:param(%d))"):format(e.n) end
  if k == "un" then
    if e.op == "-" then return "(-(" .. emit_value(e.e, lifted) .. "))" end
    if e.op == "!" then return "((" .. emit_value(e.e, lifted) .. ") == 0LL and 1LL or 0LL)" end
    if e.op == "~" then return "bit.bnot(" .. emit_value(e.e, lifted) .. ")" end
  end
  if k == "tern" then
    return ("((( %s ) ~= 0LL) and ( %s ) or ( %s ))"):format(
      emit_value(e.c, lifted), emit_value(e.a, lifted), emit_value(e.b, lifted))
  end
  if k == "bin" then
    local l, r = emit_value(e.l, lifted), emit_value(e.r, lifted)
    local op = e.op
    if op == "+" or op == "-" or op == "*" then
      return "(" .. l .. " " .. op .. " " .. r .. ")"
    end
    if op == "/" then return ("rt.idiv(%s, %s)"):format(l, r) end -- fatal on /0
    if op == "%" then return ("rt.imod(%s, %s)"):format(l, r) end
    if CMP[op] then return "((" .. l .. " " .. CMP[op] .. " " .. r .. ") and 1LL or 0LL)" end
    if op == "&&" then return "(((" .. l .. ") ~= 0LL and (" .. r .. ") ~= 0LL) and 1LL or 0LL)" end
    if op == "||" then return "(((" .. l .. ") ~= 0LL or (" .. r .. ") ~= 0LL) and 1LL or 0LL)" end
    if op == "&" then return ("bit.band(%s, %s)"):format(l, r) end
    if op == "|" then return ("bit.bor(%s, %s)"):format(l, r) end
    if op == "^" then return ("bit.bxor(%s, %s)"):format(l, r) end
    if op == "<<" then return ("bit.lshift(%s, tonumber(%s) %% 64)"):format(l, r) end
    if op == ">>" then return ("bit.arshift(%s, tonumber(%s) %% 64)"):format(l, r) end
    if op == "**" then return ("rt.ipow(%s, %s)"):format(l, r) end
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
  if lifted[name] then return lname(name) .. " = " .. valexpr end
  return ("sh:aset(%q, %s)"):format(name, valexpr)
end

local function emit_arith_stmt(e, lifted)
  if e.k == "asgn" then
    local v = emit_value(e.e, lifted)
    if e.op == "=" then return emit_set(e.name, v, lifted) end
    local cur = lifted[e.name] and lname(e.name) or ("sh:aget(%q)"):format(e.name)
    return emit_set(e.name, ("(%s %s (%s))"):format(cur, e.op:sub(1, 1), v), lifted)
  end
  if e.k == "post" or e.k == "pre" then
    local cur = lifted[e.name] and lname(e.name) or ("sh:aget(%q)"):format(e.name)
    return emit_set(e.name, ("(%s + %dLL)"):format(cur, e.d), lifted)
  end
  error("emit: statement position not supported for arith node " .. tostring(e.k))
end

local function emit_word(w, lifted)
  local parts = {}
  for i, p in ipairs(w.parts) do
    if i == 1 and p.lit and not p.q and p.lit:sub(1, 1) == "~" then
      -- word-initial unquoted literal tilde (~, ~/…, ~user, ~+/~-): expanded at
      -- runtime ($HOME/getpwnam/$PWD). Only a genuine LITERAL leading ~ triggers —
      -- a tilde from a variable's value never expands (bash), and this part is a
      -- literal, so there's no over-expansion. Other tilde positions (NAME=…:~,
      -- ~ mid-word) stay literal for now (interp handles them; no regression).
      parts[#parts + 1] = ("I.tilde_word_initial(sh, %q)"):format(p.lit)
    elseif p.lit then parts[#parts + 1] = ("%q"):format(p.lit)
    elseif p.raw then parts[#parts + 1] = p.raw -- pre-computed Lua string expr (inlined param)
    elseif p.var then
      parts[#parts + 1] = lifted[p.var] and ("rt.i64_to_str(%s)"):format(lname(p.var)) or ("sh:get_u(%q)"):format(p.var)
    elseif p.param then parts[#parts + 1] = ("sh:param(%d)"):format(p.param)
    elseif p.special then
      if p.special == "#" then parts[#parts + 1] = "tostring(sh.nparams)"
      elseif p.special == "@" or p.special == "*" then parts[#parts + 1] = 'sh:paramsJoin(" ")'
      elseif p.special == "?" then parts[#parts + 1] = "tostring(sh.status)"
      elseif p.special == "$" then parts[#parts + 1] = "tostring(sh:pid())"
      elseif p.special == "!" then parts[#parts + 1] = '(sh.last_bg_pid or "")' end
    elseif p.arithast then -- a pre-parsed+substituted arith AST (inlined word)
      local saved = arith_varread; arith_varread = "I.arith_read(sh, %q)" -- $(()) reads recursively (bar=foo;$((bar)))
      parts[#parts + 1] = "rt.i64_to_str(" .. emit_value(p.arithast, lifted) .. ")"
      arith_varread = saved
    elseif p.arith then
      local saved = arith_varread; arith_varread = "I.arith_read(sh, %q)" -- name/expr values re-parse as arith
      parts[#parts + 1] = "rt.i64_to_str(" .. emit_value(require("parser").arith(p.arith), lifted) .. ")"
      arith_varread = saved
    elseif p.cmdsub then -- $( … ): run the inner program capturing stdout (interpreted; I/O-bound)
      parts[#parts + 1] = ("sh:capture_src(%q)"):format(p.cmdsub)
    elseif p.pexp then
      error("curse-nocompile: ${..} operator") -- interp handles it; compiled falls back
    end
  end
  if #parts == 0 then return '""' end
  return "(" .. table.concat(parts, " .. ") .. ")"
end

-- The field engine (genuine compilation). A word that isn't word_safe still
-- compiles when it is a SINGLE unquoted source that split+glob can process at
-- runtime on a natively-computed value: either EVERY part is an unquoted expansion
-- (the whole concatenation word-splits then globs — `$x`, `$x$y`, `$(cmd)`), or the
-- word is an all-literal unquoted glob (no split — a literal is never word-split —
-- just glob: `*.txt`). Returns {expr, split} for rt.field_split, else nil. Mixed
-- literal+expansion (`dir/$x*`) needs the per-char quote mask → interp (delegate).
-- Dynamic special vars whose VALUE the compiled tier doesn't reproduce (it doesn't
-- track the current line or maintain $_ / the call stack): a word referencing one
-- must delegate so the interpreter computes it. `_` and `LINENO` are the tested
-- ones; the rest depend on execution state the CFG doesn't thread. (When $LINENO is
-- inlined as a compile-time literal and $_ is tracked natively, drop them here.)
local COMPILE_UNSAFE_VAR = {}
for _, n in ipairs({ "_", "LINENO", "SECONDS", "FUNCNAME", "BASH_SOURCE", "BASH_LINENO",
  "BASH_COMMAND", "RANDOM", "SRANDOM" }) do COMPILE_UNSAFE_VAR[n] = true end

local function field_word(w, lifted)
  if not emitable_word(w) then return nil end
  if #w.parts == 0 then return nil end
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
    if p.q then return nil end                 -- a quoted part needs the mask
    if p.special then return nil end           -- @/*/$?/... handled elsewhere
    if p.var and COMPILE_UNSAFE_VAR[p.var] then return nil end -- $LINENO/$_/… → interp
    if p.var or p.param or p.cmdsub or p.arith or p.arithast then alllit = false
    elseif p.lit then
      allexp = false
      if p.lit:find("[*?%[]") or p.lit:find("[@!+?*]%(") then hasglob = true end -- glob / extglob
    else return nil end
  end
  if allexp then return { expr = emit_word(w, lifted), split = true } end -- $x / $x$y
  if alllit and hasglob then
    return { expr = emit_word(w, lifted), split = false } -- *.txt (emit_word tilde-expands a leading ~)
  end
  return nil
end

-- Emit statement(s) appending word `w`'s final field(s) to Lua table `tbl`. A
-- word_safe word contributes one field (emit_word); a field_word splits+globs at
-- runtime via rt.field_split. `wrap` (e.g. "rt.cstr(%s)") wraps each final field.
local function emit_fields_into(tbl, w, lifted, wrap)
  local function W(x) return wrap and wrap:format(x) or x end
  local fw = not word_safe(w) and field_word(w, lifted)
  if word_safe(w) or (fw and fw.scalar) then -- one field, no runtime split/glob
    return ("%s[#%s+1] = %s"):format(tbl, tbl, W(word_safe(w) and emit_word(w, lifted) or fw.expr))
  end
  return ("do local __f = rt.field_split(sh, %s, %s); for __i=1,#__f do %s[#%s+1]=%s end end")
    :format(fw.expr, tostring(fw.split), tbl, tbl, W("__f[__i]"))
end

-- Build a `local __a = {...}` argv table for words[from..#words] (each field
-- split+globbed), or nil if any word needs the interpreter. `wrap` is applied to
-- each final field. Used for commands whose args word-split/glob.
local function field_argv(words, from, lifted, wrap, prefix)
  local out = { prefix and ("local __a = {" .. prefix .. "}") or "local __a = {}" }
  for j = from, #words do
    local w = words[j]
    if not word_safe(w) and not field_word(w, lifted) then return nil end
    out[#out + 1] = emit_fields_into("__a", w, lifted, wrap)
  end
  return table.concat(out, "; ")
end

-- Arith usable in a VALUE position (what emit_value renders): pure, no side effect,
-- no array subscript / embedded $-expansion / dynamic-special var.
local function arith_value_ok(e)
  if type(e) ~= "table" then return false end
  local k = e.k
  if k == "num" or k == "param" then return true end
  if k == "var" then return not e.idx and not e.idxraw and not COMPILE_UNSAFE_VAR[e.name] end
  if k == "un" then return arith_value_ok(e.e) end
  if k == "bin" then return arith_value_ok(e.l) and arith_value_ok(e.r) end
  if k == "tern" then return arith_value_ok(e.c) and arith_value_ok(e.a) and arith_value_ok(e.b) end
  return false -- asgn/post/pre/comma/xpand/matherr are not values
end

-- Arith usable at STATEMENT position ((( … )) or forc init/step): a comma sequence,
-- a top-level assignment/inc/dec (with a value-position rhs), or a pure value. A
-- side effect nested in an operand, an array subscript, or a dynamic special var
-- ($LINENO/$_/…) delegates to the interpreter (the emitter renders none of those).
local function arith_stmt_ok(e)
  if type(e) ~= "table" then return false end
  local k = e.k
  if k == "comma" then return arith_stmt_ok(e.l) and arith_stmt_ok(e.r) end
  if k == "asgn" then
    return not e.idx and not e.idxraw and not COMPILE_UNSAFE_VAR[e.name] and arith_value_ok(e.e)
  end
  if k == "post" or k == "pre" then
    return not e.idx and not e.idxraw and not COMPILE_UNSAFE_VAR[e.name]
  end
  return arith_value_ok(e)
end

-- Emit statements that evaluate arith `e` WITH its side effects, leaving the
-- result int64 in Lua local `dst`. A lifted var is a native int64 local; a
-- non-lifted one goes through the sh:aget/aset int64 accessors (genuine primitive
-- calls on natively-computed values, not an AST re-walk). Compound ops reuse
-- emit_value's operator logic (div0, shifts, **) via a synthetic bin node.
local function emit_arith_into(dst, e, lifted)
  local k = e.k
  if k == "comma" then -- l for its side effect, r for the result
    return emit_arith_into(dst, e.l, lifted) .. "; " .. emit_arith_into(dst, e.r, lifted)
  end
  if k == "asgn" then
    local rhs
    if e.op == "=" then rhs = emit_value(e.e, lifted) -- pure define: no read of the target
    else
      local cur = lifted[e.name] and lname(e.name) or (arith_varread):format(e.name) -- compound reads first
      rhs = emit_value({ k = "bin", op = e.op:sub(1, #e.op - 1), l = { k = "raw", code = cur }, r = e.e }, lifted)
    end
    if lifted[e.name] then return ("%s = %s; %s = %s"):format(lname(e.name), rhs, dst, lname(e.name)) end
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
  if type(e) ~= "table" then return false end
  local k = e.k
  if k == "var" then return not lifted[e.name] end
  if k == "bin" and (e.op == "/" or e.op == "%" or e.op == "**") then return true end
  if k == "asgn" then
    if e.op == "/=" or e.op == "%=" then return true end
    if e.op ~= "=" and not lifted[e.name] then return true end -- compound reads the target
    return arith_can_error(e.e, lifted)
  end
  if (k == "post" or k == "pre") and not lifted[e.name] then return true end
  return arith_can_error(e.e, lifted) or arith_can_error(e.l, lifted) or arith_can_error(e.r, lifted)
    or arith_can_error(e.c, lifted) or arith_can_error(e.a, lifted) or arith_can_error(e.b, lifted)
end

-- Can this arith raise a THROWN error (as opposed to a flagged read fault)? Only
-- ÷0 / mod-0 / negative ** do — via rt.idiv/imod/ipow. Those need a pcall to catch;
-- everything else (non-lifted reads) records sh.arithfault without throwing, so the
-- common accumulator `(( sum += x ))` needs no per-iteration pcall/closure.
local function arith_can_div_fault(e)
  if type(e) ~= "table" then return false end
  local k = e.k
  if k == "bin" and (e.op == "/" or e.op == "%" or e.op == "**") then return true end
  if k == "asgn" and (e.op == "/=" or e.op == "%=") then return true end
  return arith_can_div_fault(e.e) or arith_can_div_fault(e.l) or arith_can_div_fault(e.r)
    or arith_can_div_fault(e.c) or arith_can_div_fault(e.a) or arith_can_div_fault(e.b)
end

-- The CFG compiler only understands ARITHMETIC conditions. A forc cond is
-- already an arith node; a while/if cond is now a command list, which we compile
-- only when it's exactly one `(( expr ))` — extract that arith node here (never
-- mutating the shared AST). Returns nil for a cond the compiler can't handle;
-- assert_compilable (below) has already thrown for those, so post-validation this
-- always yields the arith node for the conds that remain.
local function cond_arith(c)
  if type(c) ~= "table" then return nil end
  if c.k then return c end -- an arith node already (forc init/cond/step)
  if #c == 1 and c[1] and c[1].t == "arithcmd" then return c[1].expr end
  return nil
end

-- `[ A -op B ]` / `test A -op B` do an ARITHMETIC comparison. When both operands
-- are provably integer, the whole test is a native int64 compare — no do_test, no
-- per-iteration argv table. bash errors on a non-integer operand, so a plain string
-- var stays on the do_test path; only a lifted-int64 var, an integer literal, or an
-- arith $((…)) qualifies (quoting is irrelevant in arithmetic).
local TEST_ARITH_OP = { ["-eq"] = "==", ["-ne"] = "!=", ["-lt"] = "<", ["-le"] = "<=", ["-gt"] = ">", ["-ge"] = ">=" }
local function test_operand_arith(w, lifted)
  if #w.parts ~= 1 then return nil end
  local p = w.parts[1]
  if p.var and lifted[p.var] then return { k = "var", name = p.var } end
  if p.lit and p.lit:match("^[+-]?%d+$") then return { k = "num", v = p.lit } end
  if p.arithast then return p.arithast end
  if p.arith then return require("parser").arith(p.arith) end
  return nil
end
-- Returns the equivalent arith comparison node for a compilable `[ … ]`/test cond,
-- or nil (caller falls back to the do_test command path).
local function test_as_arith(cond, lifted)
  if type(cond) ~= "table" or cond.k or #cond ~= 1 then return nil end
  local st = cond[1]
  if not st or st.t ~= "simple" or st.redirs or st.assigns then return nil end
  local w = st.words
  local function lit1(x) return x and x.parts[1] and #x.parts == 1 and x.parts[1].lit end
  local cmd, A, opw, B = lit1(w[1]), nil, nil, nil
  if cmd == "[" then
    if #w ~= 5 or lit1(w[5]) ~= "]" then return nil end
    A, opw, B = w[2], w[3], w[4]
  elseif cmd == "test" then
    if #w ~= 4 then return nil end
    A, opw, B = w[2], w[3], w[4]
  else return nil end
  local op = TEST_ARITH_OP[lit1(opw) or ""]
  if not op then return nil end
  local l, r = test_operand_arith(A, lifted), test_operand_arith(B, lifted)
  if not l or not r or not_compilable(l) or not_compilable(r)
      or arith_side_effect(l) or arith_side_effect(r) then return nil end
  return { k = "bin", op = op, l = l, r = r }
end

-- a word that is exactly one numeric literal -> its digits (else nil)
local function numeric_word(w)
  if #w.parts == 1 and w.parts[1].lit and w.parts[1].lit:match("^[+-]?%d+$") then
    return w.parts[1].lit
  end
  return nil
end

-- collect every variable NAME referenced in an arith node / word / stmt list.
local function collect_arith(e, set)
  if type(e) ~= "table" then return end
  if e.k == "var" or e.k == "asgn" or e.k == "post" or e.k == "pre" then set[e.name] = true end
  collect_arith(e.e, set); collect_arith(e.l, set); collect_arith(e.r, set)
end
local function collect_word(w, set)
  for _, p in ipairs(w.parts) do
    if p.var then set[p.var] = true
    elseif p.arith then collect_arith(require("parser").arith(p.arith), set) end
  end
end
local function collect_names(stmts, set)
  for _, st in ipairs(stmts) do
    if st.t == "assign" then
      set[st.name] = true
      if st.arith then collect_arith(st.arith, set) elseif st.rhs then collect_word(st.rhs, set) end
    elseif st.t == "simple" then
      for j = 2, #st.words do collect_word(st.words[j], set) end
      local cmd = st.words[1] and st.words[1].parts[1] and st.words[1].parts[1].lit
      if cmd == "local" then
        for j = 2, #st.words do
          local p1 = st.words[j].parts[1]
          local nm = p1 and p1.lit and p1.lit:match("^([%a_][%w_]*)")
          if nm then set[nm] = true end
        end
      end
    elseif st.t == "forc" or st.t == "whilec" then
      collect_arith(st.init, set); collect_arith(cond_arith(st.cond), set); collect_arith(st.step, set)
      collect_names(st.body, set)
    elseif st.t == "forin" then
      set[st.name] = true
      for _, w in ipairs(st.words) do collect_word(w, set) end
      collect_names(st.body, set)
    elseif st.t == "if" then
      for _, cl in ipairs(st.clauses) do collect_arith(cond_arith(cl.cond), set); collect_names(cl.body, set) end
    elseif st.t == "funcdef" then
      collect_names(st.body, set)
    end
  end
end
-- every var touched by a NON-INLINABLE function body (those keep an out-of-line
-- closure, so a var they touch must be a shared upvalue, not a run-local).
-- Inlinable functions are spliced into run(), so their var access is run() access.
local function collect_funcvars(stmts, set, inlinable)
  for _, st in ipairs(stmts) do
    if st.t == "funcdef" then
      if not (inlinable and inlinable[st.name]) then collect_names(st.body, set) end
    elseif st.t == "forc" or st.t == "whilec" or st.t == "forin" then collect_funcvars(st.body, set, inlinable)
    elseif st.t == "if" then for _, cl in ipairs(st.clauses) do collect_funcvars(cl.body, set, inlinable) end end
  end
end

-- Which vars become native int64 MODULE-LEVEL locals (shared as upvalues by
-- run() and every function closure). A var qualifies if it is assigned somewhere,
-- every assignment is arithmetic or a numeric literal (reads never disqualify),
-- and it is never `local`'d in a function (that would need per-call shadowing,
-- which the sh scope handles instead). Scans EVERYWHERE, including function
-- bodies — a var shared between the top level and a function still lifts, because
-- the upvalue is one real variable both see (no hash lookup, no desync).
local function analyze_lift(ast)
  local assigned, disq, localed = {}, {}, {}
  local function scan(stmts)
    for _, st in ipairs(stmts) do
      if st.t == "assign" then
        assigned[st.name] = true
        if not st.arith and not (st.rhs and numeric_word(st.rhs)) then disq[st.name] = true end
      elseif st.t == "simple" then
        local cmd = st.words[1] and st.words[1].parts[1] and st.words[1].parts[1].lit
        if cmd == "local" then
          for j = 2, #st.words do
            local p1 = st.words[j].parts[1]
            local nm = p1 and p1.lit and p1.lit:match("^([%a_][%w_]*)")
            if nm then localed[nm] = true end
          end
        elseif cmd == "readonly" or cmd == "declare" or cmd == "typeset"
            or cmd == "export" or cmd == "unset" then
          -- these delegated builtins manage the var's BOX + attributes (ro/integer/
          -- exported) in sh.vars; a native-int64 local would desync, so never lift.
          for j = 2, #st.words do
            local p1 = st.words[j].parts[1]
            local nm = p1 and p1.lit and p1.lit:match("^([%a_][%w_]*)")
            if nm then disq[nm] = true end
          end
        end
      elseif st.t == "forc" or st.t == "whilec" then
        for _, e in ipairs({ st.init, cond_arith(st.cond), st.step }) do
          if e and (e.k == "asgn" or e.k == "post" or e.k == "pre") then assigned[e.name] = true end
        end
        scan(st.body)
      elseif st.t == "forin" then
        disq[st.name] = true -- a `for x in` var holds arbitrary strings, never lift it
        scan(st.body)
      elseif st.t == "if" then
        for _, cl in ipairs(st.clauses) do scan(cl.body) end
      elseif st.t == "funcdef" then
        scan(st.body)
      end
    end
  end
  scan(ast.stmts)
  local lifted = {}
  for n in pairs(assigned) do if not disq[n] and not localed[n] then lifted[n] = true end end
  return lifted
end

-- Does a function need a positional-param swap / a `local` frame? A call to a
-- function that needs neither is emitted bare (fn_x(sh)); one that needs only
-- params uses the lightweight pushParams; only `local` needs the full frame.
local function scan_arith_param(e, f)
  if type(e) ~= "table" then return end
  if e.k == "param" then f.params = true end
  scan_arith_param(e.e, f); scan_arith_param(e.l, f); scan_arith_param(e.r, f)
end
local function scan_word_param(w, f)
  for _, p in ipairs(w.parts) do
    if p.param or (p.special and p.special ~= "?") then f.params = true end -- $? is status, not $@
    if p.arith then scan_arith_param(require("parser").arith(p.arith), f) end
  end
end
local function func_flags(body)
  local f = { params = false, locals = false }
  local function scan(stmts)
    for _, st in ipairs(stmts) do
      if st.t == "simple" then
        local cmd = st.words[1] and st.words[1].parts[1] and st.words[1].parts[1].lit
        if cmd == "local" then f.locals = true end
        for j = 2, #st.words do scan_word_param(st.words[j], f) end
      elseif st.t == "assign" then
        if st.arith then scan_arith_param(st.arith, f) elseif st.rhs then scan_word_param(st.rhs, f) end
      elseif st.t == "forc" or st.t == "whilec" then
        scan_arith_param(st.init, f); scan_arith_param(cond_arith(st.cond), f); scan_arith_param(st.step, f); scan(st.body)
      elseif st.t == "forin" then
        for _, w in ipairs(st.words) do scan_word_param(w, f) end; scan(st.body)
      elseif st.t == "if" then
        for _, cl in ipairs(st.clauses) do scan_arith_param(cond_arith(cl.cond), f); scan(cl.body) end
      end
    end
  end
  scan(body)
  return f
end

-- A function is INLINABLE if its body is flat (only assignments and
-- echo/:/true/false) — no control flow, calls, `return`, or `local`. Such a
-- function is spliced into its direct call sites (params bound directly, no call,
-- no string round-trip), which also lets its shared vars collapse to run-locals.
local function word_varargs(w) -- word that blocks inlining
  for _, p in ipairs(w.parts) do
    -- $@ / $* / $# need a real param array (inlining has no call frame)…
    if p.special and (p.special == "@" or p.special == "*" or p.special == "#") then return true end
    -- …and $( … ) is opaque source re-run against the live frame, so its inner
    -- $n would see the caller's params, not the inlined ones — don't inline it.
    if p.cmdsub then return true end
  end
  return false
end
local function inlinable_body(body)
  for _, st in ipairs(body) do
    if st.t == "assign" then
      if st.rhs and word_varargs(st.rhs) then return false end
    elseif st.t == "simple" then
      local cmd = st.words[1] and st.words[1].parts[1] and st.words[1].parts[1].lit
      if not (cmd == "echo" or cmd == ":" or cmd == "true" or cmd == "false") then return false end
      for j = 2, #st.words do if word_varargs(st.words[j]) then return false end end
    else
      return false
    end
  end
  return true
end

-- Substitute positional params ($n) with the caller's already-computed Lua exprs.
-- pb[n] = { int = <arith Lua expr>, str = <string Lua expr> }.
local function subst_arith(e, pb)
  if type(e) ~= "table" then return e end
  local k = e.k
  if k == "param" then -- unset positional inside the callee is 0 in arith
    return pb[e.n] and { k = "raw", code = pb[e.n].int } or { k = "num", v = "0" }
  end
  if k == "bin" then return { k = "bin", op = e.op, l = subst_arith(e.l, pb), r = subst_arith(e.r, pb) } end
  if k == "un" then return { k = "un", op = e.op, e = subst_arith(e.e, pb) } end
  if k == "asgn" then return { k = "asgn", name = e.name, op = e.op, e = subst_arith(e.e, pb) } end
  return e -- num, var, post, pre, raw
end
local function subst_word(w, pb)
  local parts = {}
  for _, p in ipairs(w.parts) do
    if p.param then parts[#parts + 1] = pb[p.param] and { raw = pb[p.param].str } or { lit = "" } -- unset positional = ""
    elseif p.arith then parts[#parts + 1] = { arithast = subst_arith(require("parser").arith(p.arith), pb) }
    else parts[#parts + 1] = p end
  end
  return { k = "word", parts = parts }
end
local function subst_list(body, pb)
  local out = {}
  for _, st in ipairs(body) do
    if st.t == "assign" then
      out[#out + 1] = st.arith and { t = "assign", name = st.name, arith = subst_arith(st.arith, pb) }
        or { t = "assign", name = st.name, rhs = subst_word(st.rhs, pb) }
    elseif st.t == "simple" then
      local words = {}
      for _, w in ipairs(st.words) do words[#words + 1] = subst_word(w, pb) end
      out[#out + 1] = { t = "simple", words = words }
    end
  end
  return out
end

-- Build a pc-dispatch CFG for a statement list. Shared by the top-level `run`
-- and every function body. `funcflags[name]` marks user functions (out-of-line
-- call), `inlinefns[name]` gives the body of an inlinable one (spliced in place).
-- Returns { blocks, npc, entry, loopPc, stmtPc, DONE }.
local function build_cfg(stmts, lifted, funcflags, inlinefns, toplevel)
  emit_toplevel = toplevel and true or false -- gates top-level-only ERR firing (see errchk)
  local blocks = {}
  local loopPc, stmtPc = {}, {}
  local npc = 0
  local function newpc() local p = npc; npc = npc + 1; return p end

  local DONE = newpc()
  blocks[DONE] = "break"

  -- Compile-time loop stack for break/continue: each entry is { brk = pc to exit
  -- the loop, cont = pc to re-test/advance }. `break N` / `continue N` jump to the
  -- Nth-innermost enclosing loop — a compile-time decision, so they become native
  -- jumps (no runtime unwind). loopvars are run()-level status holders (one per
  -- command-condition while), declared 0 and used to give the loop bash's exit
  -- status (last body command, or 0). Both are returned for assemble to declare.
  local loopstack, loopvars = {}, {}
  local function newloopvar() local v = "__lw" .. #loopvars; loopvars[#loopvars + 1] = v; return v end

  local flatten_list

  -- Delegate a cold statement to the shared interpreter on a baked AST node. Lifted
  -- locals are synced to `sh` before and reloaded after, so the interpreter sees
  -- current values and picks up any it changed (delegated statements are cold, so
  -- this sync costs nothing). This is how the compiled tier reaches feature parity
  -- without re-implementing the word engine in generated code.
  local function delegate(st, after)
    local p = newpc()
    local out = {}
    for n in pairs(lifted) do out[#out + 1] = ("sh:aset(%q, %s)"):format(n, lname(n)) end
    out[#out + 1] = ("I.exec_stmt(sh, %s, __noop)"):format(ser(st))
    for n in pairs(lifted) do out[#out + 1] = ("%s = sh:aget(%q)"):format(lname(n), n) end
    -- errexit: a delegated errexit-relevant statement (interp's exec_stmt doesn't
    -- fire it — exec_list does) gets the guard here. Compounds (if/for/case) fire
    -- errexit for their inner commands inside exec_stmt already, so they're excluded.
    local ec = errchk(st); if ec ~= "" then out[#out + 1] = ec end
    out[#out + 1] = ("pc = %d"):format(after)
    blocks[p] = table.concat(out, "; ")
    return p
  end

  -- Statement types with no native compiled form yet -> always delegate.
  local DELEGATE = {
    pipeline = 1, case = 1, group = 1,
    dbracket = 1, arrayassign = 1, parse_error = 1, assignlist = 1, background = 1,
  }

  -- Compile one redirect's target to a native Lua expr (op + fd are already
  -- compile-time constants). Returns the expr, or nil when this redirect isn't
  -- monomorphic enough to compile — a `{var}>` named fd, a fd MOVE (`>&N-`), an
  -- expanding heredoc, a dup target that isn't a plain fd, or a FILE target that
  -- needs the field engine ($/glob/brace/tilde/split/ambiguity). The caller then
  -- delegates the whole command (honest transition; those are the defect to grind).
  local P = require("parser")
  local REDIR_FILE = { out = 1, app = 1, ["in"] = 1, clobber = 1, rw = 1, appboth = 1, outboth = 1 }
  local function redir_target_expr(r)
    if r.fdvar then return nil end
    if REDIR_FILE[r.op] then
      local t = r.target or ""
      -- needs the field engine or a subshell/procsub (`> >(cmd)`, `< <(cmd)`): delegate.
      if t == "" or t:find("[%$`%*%?%[~{()]") then return nil end
      return ("%q"):format(t) -- a static literal path
    elseif r.op == "dup" or r.op == "dupin" then
      local t = r.target or ""
      if t == "-" or t:match("^%d+$") then return ("%q"):format(t) end
      return nil -- a dynamic fd, or a MOVE (`>&5-`): delegate
    elseif r.op == "herestring" then
      local w = P.parse_word(r.word or ""); if not emitable_word(w) then return nil end
      return "(" .. emit_word(w, lifted) .. ' .. "\\n")' -- one blob (no split), + a trailing newline
    elseif r.op == "heredoc" then
      if r.expand then return nil end -- an expanding body needs the word engine — later
      return ("%q"):format(r.body or "")
    end
    return nil
  end
  -- Build the "install all redirs, run, restore" conditions for `st.redirs`, or nil
  -- if any redir can't be compiled (caller delegates) or the command is `exec`
  -- (whose redirs must PERSIST — never restored). Returns the `and`-chained apply
  -- expression; the caller wraps the command body with it.
  local function redir_conds(st, cmd)
    if cmd == "exec" then return nil end
    local conds = {}
    for _, r in ipairs(st.redirs) do
      local texpr = redir_target_expr(r)
      if not texpr then return nil end
      conds[#conds + 1] = ("rt.redir_apply(sh, %q, %d, %s, __rs)"):format(r.op, r.fd or 0, texpr)
    end
    return table.concat(conds, " and ")
  end

  -- Build blocks for `st`; its exit flows to pc `after`. Returns st's entry pc.
  local function flatten_stmt(st, after)
    local t = st.t
    -- break / continue [N]: a compile-time jump to the Nth enclosing loop's exit or
    -- re-test point. Both set $?=0 (bash). Outside any loop it's a no-op. A
    -- non-literal level (`break $n`) is rare — delegate it.
    local cf_op, cf_arg = resolve_cf(st)
    if cf_op == "break" or cf_op == "continue" then
      local lvl, ok = 1, true
      if st.words[cf_arg] then
        local wl = full_lit(st.words[cf_arg])
        if wl and wl:match("^%d+$") and not st.words[cf_arg + 1] then lvl = tonumber(wl)
        else ok = false end
      end
      if ok then
        local p = newpc()
        if #loopstack == 0 then blocks[p] = ("sh.status = 0; pc = %d"):format(after) -- no-op outside a loop
        else
          local idx = #loopstack - (lvl - 1); if idx < 1 then idx = 1 end
          local tgt = (cf_op == "break") and loopstack[idx].brk or loopstack[idx].cont
          blocks[p] = ("sh.status = 0; pc = %d"):format(tgt)
        end
        return p
      end
    elseif cf_op == "return" then
      -- return [N] (incl. \return / builtin return / command return): set $? and exit
      -- the CFG. A non-literal/expression status word is fine (emit_word handles it).
      if not st.words[cf_arg + 1] then -- at most one status arg
        local p = newpc()
        local n = st.words[cf_arg] and ("tonumber(%s)"):format(emit_word(st.words[cf_arg], lifted)) or "sh.status"
        blocks[p] = ("sh.status = (%s) or 0; pc = %d"):format(n, DONE)
        return p
      end
    end
    if DELEGATE[t] then return delegate(st, after) end
    if t == "assign" then
      if st.index or st.append or (st.rhs and not emitable_word(st.rhs))
        or (st.arith and arith_side_effect(st.arith)) then return delegate(st, after) end
      local p = newpc()
      local d = dbg(st) -- DEBUG trap fires before the assignment (bash: DEBUG_FIRE.assign)
      if st.arith then
        blocks[p] = d .. emit_set(st.name, emit_value(st.arith, lifted), lifted) .. ("; pc = %d"):format(after)
      elseif lifted[st.name] then
        blocks[p] = d .. emit_set(st.name, numeric_word(st.rhs) .. "LL", lifted) .. ("; pc = %d"):format(after)
      elseif emit_has_attr then -- readonly reject / array [0] / declare -i,-l,-u — via interp's logic
        -- status 0 first so a plain RHS yields 0 (a cmdsub RHS overwrites it), then
        -- assign_scalar (which sets 1 on a readonly reject); errchk applies errexit/ERR.
        local ec = errchk(st); local ecs = ec ~= "" and ("; " .. ec) or ""
        blocks[p] = d .. ("sh.status = 0; I.assign_scalar(sh, %q, %s)%s; pc = %d")
          :format(st.name, emit_word(st.rhs, lifted), ecs, after)
      else
        blocks[p] = d .. ("sh:set_str(%q, %s); pc = %d"):format(st.name, emit_word(st.rhs, lifted), after)
      end
      return p
    elseif t == "funcdef" then
      local p = newpc(); blocks[p] = ("pc = %d"):format(after); return p -- closures are hoisted
    elseif t == "simple" then
      local cmd = st.words[1] and st.words[1].parts[1] and st.words[1].parts[1].lit
      -- redirects compile (targets computed natively, syscalls via rt.redir_apply)
      -- when every one is compilable AND this isn't `exec` (its redirs persist);
      -- otherwise the whole command delegates.
      local redir_apply = nil
      if st.redirs then
        redir_apply = redir_conds(st, cmd)
        if not redir_apply then return delegate(st, after) end
      end
      -- a redirect-ONLY command (`> file`, `< f`): no command runs; apply the redirs
      -- (their open/truncate is the effect), status 0 (or 1 on failure), then restore.
      if not st.words[1] then
        local p = newpc()
        blocks[p] = dbg(st) .. ("do local __rs = {}; sh.status = %s and 0 or 1; rt.redir_restore(__rs) end; pc = %d")
          :format(redir_apply, after)
        return p
      end
      -- delegate if it needs the field engine (splitting/glob/pexp), or a builtin
      -- without a native compiled form.
      local NATIVE_BUILTIN = { echo = 1, [":"] = 1, ["true"] = 1, ["false"] = 1, ["local"] = 1,
        ["return"] = 1, test = 1, ["["] = 1 }
      local isfunc = (inlinefns and inlinefns[cmd]) or funcflags[cmd]
      if cmd == "return" and redir_apply then return delegate(st, after) end -- rare; wrapper assumes a run body
      -- FIELD-ENGINE path: an argument word-splits or globs, so argv is variable
      -- length. Commands with a STATIC dispatch (echo, test/[, a named external, a
      -- non-inline function) consume it via rt.field_split on natively-computed
      -- operands; everything else (inline fn, interp-only builtin, prefix env,
      -- dynamic command word) delegates.
      if st.assigns == nil then
        local anyfield = false
        for j = 1, #st.words do if not word_safe(st.words[j]) then anyfield = true; break end end
        if anyfield then
          local from, wrap, call, prefix
          if cmd == "echo" then from = 2; call = "sh:echo(unpack(__a))"
          elseif cmd == "test" or cmd == "[" then -- the [ / test command word is a literal (dispatched by
            from = 2; wrap = "rt.cstr(%s)"; call = "I.do_test(sh, __a)" -- name, never glob-expanded)
            prefix = ("rt.cstr(%q)"):format(cmd)
          elseif funcflags[cmd] and (funcflags[cmd].locals or funcflags[cmd].params) then
            from = 2
            local ff = funcflags[cmd]
            call = ff.locals and ("sh:pushCall(unpack(__a)); %s(sh); sh:popCall()"):format(fnlname(cmd))
              or ("sh:pushParams(unpack(__a)); %s(sh); sh:popParams()"):format(fnlname(cmd))
          elseif cmd ~= nil and not NATIVE_BUILTIN[cmd] and not (inlinefns and inlinefns[cmd])
              and not funcflags[cmd] and not require("interp").BUILTINS[cmd] then
            from = 1; call = "sh:exec(unpack(__a))" -- external, static command name
          else
            return delegate(st, after)
          end
          local builder = field_argv(st.words, from, lifted, wrap, prefix)
          if not builder then return delegate(st, after) end
          local p = newpc()
          local ec = errchk(st); local ecs = ec ~= "" and ("; " .. ec) or ""
          local d = dbg(st) -- DEBUG fires before the command (and its expansions)
          if redir_apply then
            -- bash order: expand the words (side-effecting cmdsubs run) BEFORE the
            -- redirects are applied, so `cmd $(read f) > f` reads f before it's
            -- truncated. Build argv first, then install redirs around the dispatch.
            blocks[p] = d .. builder ..
              ("; do local __rs = {}; if %s then %s else sh.status = 1 end; rt.redir_restore(__rs) end%s; pc = %d")
              :format(redir_apply, call, ecs, after)
          else
            blocks[p] = d .. builder .. "; " .. call .. ecs .. ("; pc = %d"):format(after)
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
          elseif isfunc then if not emitable_word(w) then mustdeleg = true; break end
          elseif not word_safe(w) then mustdeleg = true; break end
        end
      end
      -- interp-only builtins (no native compiled form) delegate. Use interp's own
      -- builtin set so the two backends stay in lockstep as builtins are added.
      if not mustdeleg and cmd and not NATIVE_BUILTIN[cmd] and not isfunc then
        if require("interp").BUILTINS[cmd] then mustdeleg = true end
      end
      if mustdeleg then return delegate(st, after) end
      if cmd == "return" then -- exit the current CFG (function or top level)
        local p = newpc()
        local n = st.words[2] and ("tonumber(%s)"):format(emit_word(st.words[2], lifted)) or "sh.status"
        blocks[p] = ("sh.status = (%s) or 0; pc = %d"):format(n, DONE)
        return p
      end
      if inlinefns and inlinefns[cmd] and not redir_apply then
        -- INLINE: bind $n to the caller's exprs and splice the body flowing to `after`.
        local pb = {}
        for j = 2, #st.words do
          local w = st.words[j]
          local strExpr = emit_word(w, lifted)
          local intExpr
          if #w.parts == 1 then
            local pp = w.parts[1]
            if pp.var then intExpr = lifted[pp.var] and lname(pp.var) or ("sh:aget(%q)"):format(pp.var)
            elseif pp.lit and pp.lit:match("^[+-]?%d+$") then intExpr = pp.lit .. "LL"
            elseif pp.arith then intExpr = emit_value(require("parser").arith(pp.arith), lifted)
            else intExpr = ("rt.str_to_i64(%s)"):format(strExpr) end
          else intExpr = ("rt.str_to_i64(%s)"):format(strExpr) end
          pb[j - 1] = { int = intExpr, str = strExpr }
        end
        return flatten_list(subst_list(inlinefns[cmd], pb), after)
      end
      local p = newpc()
      local args = {}
      for j = 2, #st.words do args[#args + 1] = emit_word(st.words[j], lifted) end
      local body
      if cmd == "echo" then body = "sh:echo(" .. table.concat(args, ", ") .. ")"
      elseif cmd == ":" or cmd == "true" then body = "sh.status = 0"
      elseif cmd == "false" then body = "sh.status = 1"
      elseif cmd == "local" then
        local ls = {}
        for _, a in ipairs(args) do ls[#ls + 1] = ("sh:localAssign(%s)"):format(a) end
        body = table.concat(ls, "; ") .. (#ls > 0 and "; " or "") .. "sh.status = 0"
      elseif cmd == "test" or cmd == "[" then
        -- [ EXPR ] / test EXPR: the operator/arity are compile-time known; compute the
        -- args natively (word_safe, so no field engine) and run the POSIX test logic
        -- via the do_test PRIMITIVE (access/stat/string/arith on the VALUES — not an
        -- AST re-walk). do_test sets $? (0/1, or 2 on a malformed expression). Each arg
        -- is rt.cstr'd: an argv entry is a C string, so a NUL truncates it (`$'\0'`);
        -- interp truncates in expand_args, external exec via C — do_test is Lua-side.
        local allargs = {}
        for j = 1, #st.words do allargs[#allargs + 1] = ("rt.cstr(%s)"):format(emit_word(st.words[j], lifted)) end
        body = "I.do_test(sh, {" .. table.concat(allargs, ", ") .. "})"
      elseif funcflags[cmd] then
        local ff = funcflags[cmd]
        if ff.locals then -- full frame (save/restore shadowed vars + params)
          body = ("sh:pushCall(%s); %s(sh); sh:popCall()"):format(table.concat(args, ", "), fnlname(cmd))
        elseif ff.params then -- positional swap only (no per-call frame table)
          body = ("sh:pushParams(%s); %s(sh); sh:popParams()"):format(table.concat(args, ", "), fnlname(cmd))
        else -- neither: bare call, no allocation
          body = ("%s(sh)"):format(fnlname(cmd))
        end
      else -- external command: sh:exec(all words including the command name)
        local allargs = {}
        for j = 1, #st.words do allargs[#allargs + 1] = emit_word(st.words[j], lifted) end
        body = "sh:exec(" .. table.concat(allargs, ", ") .. ")"
      end
      local ec = errchk(st) -- errexit after a failing native simple command
      local ecs = ec ~= "" and ("; " .. ec) or ""
      local d = dbg(st) -- DEBUG fires before the command
      if redir_apply then
        -- install the redirs (backing up fds), run the command only if they all
        -- succeeded (else $?=1, bash), then restore the fds — real syscalls, no AST.
        blocks[p] = d .. ("do local __rs = {}; if %s then %s else sh.status = 1 end; rt.redir_restore(__rs) end%s; pc = %d")
          :format(redir_apply, body, ecs, after)
      else
        blocks[p] = d .. body .. ecs .. ("; pc = %d"):format(after)
      end
      return p
    elseif t == "arithcmd" then
      -- (( expr )): evaluate expr WITH side effects natively (assignments, ++/--,
      -- comma), then $? = (result != 0) ? 0 : 1 — bash's arith-command status. No
      -- delegation; the interpreter is only used for the parts the emitter can't
      -- render (array subscripts, embedded $-expansion, $LINENO/$_, redirects).
      if st.redirs then return delegate(st, after) end
      if not arith_stmt_ok(st.expr) then return delegate(st, after) end
      local p = newpc()
      local ec = errchk(st); local ecs = ec ~= "" and ("; " .. ec) or ""
      local d = dbg(st) -- DEBUG fires before the (( )) command (bash: DEBUG_FIRE.arithcmd)
      local saved = arith_varread; arith_varread = "I.arith_read(sh, %q)" -- nounset+recursive-eval reads
      local code = emit_arith_into("__ar", st.expr, lifted)
      arith_varread = saved
      if arith_can_div_fault(st.expr) then
        -- ÷0 / mod-0 / negative ** THROW a non-fatal matherr — catch it (and any
        -- flagged read fault) as $?=1 and continue, like interp; re-raise anything else.
        blocks[p] = d .. ("do sh.arithfault = false; local __ok, __v = pcall(function() local __ar = 0LL; %s; return (__ar ~= 0LL) and 0 or 1 end); "
          .. "if not __ok then if type(__v) == 'table' and __v.__curse_matherr then sh.status = 1 else error(__v) end "
          .. "elseif sh.arithfault then sh.status = 1 else sh.status = __v end end%s; pc = %d")
          :format(code, ecs, after)
      elseif arith_can_error(st.expr, lifted) then
        -- a non-lifted read may fault; arith_read records it in sh.arithfault WITHOUT
        -- throwing, so no per-iteration pcall/closure — the accumulator stays JIT-native.
        blocks[p] = d .. ("do sh.arithfault = false; local __ar = 0LL; %s; sh.status = sh.arithfault and 1 or ((__ar ~= 0LL) and 0 or 1) end%s; pc = %d")
          :format(code, ecs, after)
      else -- provably error-free (lifted ints, +-*/comparisons): inline, JIT-native
        blocks[p] = d .. ("do local __ar = 0LL; %s; sh.status = (__ar ~= 0LL) and 0 or 1 end%s; pc = %d")
          :format(code, ecs, after)
      end
      return p
    elseif t == "forc" then
      if st.redirs then return delegate(st, after) end -- redirs on the loop: interp applies them
      if hard_cf(st.body) then return delegate(st, after) end -- un-static break/continue
      if not_compilable(st.init) or not_compilable(st.cond) or not_compilable(st.step)
          or arith_side_effect(st.cond) then -- a side-effecting cond can't be an emit_bool expr
        return delegate(st, after)
      end
      local condp = newpc(); loopPc[st.id] = condp
      local stepp = newpc()
      loopstack[#loopstack + 1] = { brk = after, cont = stepp } -- break exits, continue steps
      local bodyentry = flatten_list(st.body, stepp)
      loopstack[#loopstack] = nil
      blocks[stepp] = (st.step and emit_arith_stmt(st.step, lifted) .. "; " or "") .. ("pc = %d"):format(condp)
      blocks[condp] = ("if %s then pc = %d else pc = %d end"):format(
        st.cond and emit_bool(st.cond, lifted) or "true", bodyentry, after)
      if st.init then
        local ip = newpc()
        blocks[ip] = emit_arith_stmt(st.init, lifted) .. ("; pc = %d"):format(condp)
        return ip
      end
      return condp
    elseif t == "whilec" then
      if st.redirs then return delegate(st, after) end -- redirs on the loop (heredoc/file): interp applies them
      -- un-static break/continue in the body, or ANY in the command condition (loopstack
      -- isn't active there) → delegate the whole loop (else the signal is lost → spin).
      if hard_cf(st.body) or (type(st.cond) == "table" and not st.cond.k and hard_cf(st.cond, true)) then
        return delegate(st, after)
      end
      local arith = cond_arith(st.cond)
      if arith and not st.negate and not not_compilable(arith) and not arith_side_effect(arith) then
        -- fast path: a native arith condition `while (( expr ))` — no command run.
        local condp = newpc(); loopPc[st.id] = condp
        loopstack[#loopstack + 1] = { brk = after, cont = condp }
        local bodyentry = flatten_list(st.body, condp)
        loopstack[#loopstack] = nil
        blocks[condp] = ("if %s then pc = %d else pc = %d end"):format(emit_bool(arith, lifted), bodyentry, after)
        return condp
      end
      -- fast path: `while/until [ A -op B ]` with integer operands — a native int64
      -- compare instead of building an argv table and running do_test each iteration.
      -- Keeps [ ]'s own $? (0/1) for the body's first command AND the loop's
      -- last-body exit status (lv), exactly like the command-condition path below.
      local tarith = test_as_arith(st.cond, lifted)
      if tarith then
        local lv = newloopvar()
        local condp = newpc(); loopPc[st.id] = condp
        local exitp = newpc(); blocks[exitp] = ("sh.status = %s; pc = %d"):format(lv, after)
        loopstack[#loopstack + 1] = { brk = after, cont = condp }
        local bodysave = newpc()
        local bodyentry = flatten_list(st.body, bodysave)
        loopstack[#loopstack] = nil
        blocks[bodysave] = ("%s = sh.status; pc = %d"):format(lv, condp)
        blocks[condp] = ("sh.status = (%s) and 0 or 1; if sh.status %s 0 then pc = %d else pc = %d end")
          :format(emit_bool(tarith, lifted), st.negate and "~=" or "==", bodyentry, exitp)
        local entry = newpc(); blocks[entry] = ("%s = 0; pc = %d"):format(lv, condp)
        return entry
      end
      -- COMMAND condition (or `until`): run the condition list as a sub-CFG with
      -- sh.noerr raised (errexit-exempt, like the interpreter), then branch on its
      -- exit status — `while` enters the body on 0, `until` on non-zero. The loop's
      -- exit status is the LAST body command's status (bash), which the condition
      -- clobbers — so one native register (lv) remembers it across the re-test.
      -- loopPc = the condition entry (an OSR resumes at the re-test point). Genuine
      -- control flow, no delegation.
      local lv = newloopvar()
      local prep = newpc(); loopPc[st.id] = prep
      local donep = newpc()
      local exitp = newpc(); blocks[exitp] = ("sh.status = %s; pc = %d"):format(lv, after)
      loopstack[#loopstack + 1] = { brk = after, cont = prep } -- break exits (status 0), continue re-tests
      local bodysave = newpc()
      local bodyentry = flatten_list(st.body, bodysave)
      loopstack[#loopstack] = nil
      blocks[bodysave] = ("%s = sh.status; pc = %d"):format(lv, prep)
      blocks[donep] = ("sh.noerr = sh.noerr - 1; if sh.status %s 0 then pc = %d else pc = %d end")
        :format(st.negate and "~=" or "==", bodyentry, exitp)
      local listentry = flatten_list(st.cond, donep)
      blocks[prep] = ("sh.noerr = sh.noerr + 1; pc = %d"):format(listentry)
      local entry = newpc(); blocks[entry] = ("%s = 0; pc = %d"):format(lv, prep) -- status 0 if body never runs
      return entry
    elseif t == "forin" then
      if st.redirs then return delegate(st, after) end -- redirs on the loop: interp applies them
      if hard_cf(st.body) then return delegate(st, after) end -- un-static break/continue
      if not st.name:match("^[%a_][%w_]*$") then return delegate(st, after) end -- invalid loop var → interp errors
      -- Each word must be word_safe (one field) or a field_word (an unquoted
      -- expansion/glob the field engine splits+globs at runtime). Array/@/* and
      -- mixed literal+expansion words still delegate the whole loop (cold path).
      for _, w in ipairs(st.words) do
        if not word_safe(w) and not field_word(w, lifted) then return delegate(st, after) end
      end
      local initp = newpc()
      local advp = newpc(); loopPc[st.id] = advp -- back-edge = resume point
      loopstack[#loopstack + 1] = { brk = after, cont = advp } -- break exits, continue advances
      local bodyentry = flatten_list(st.body, advp)
      loopstack[#loopstack] = nil
      -- init: expand the word list ONCE into sh.forstate[id] (so OSR resumes it)
      local parts = { "local __l = {}" }
      for _, w in ipairs(st.words) do
        parts[#parts + 1] = emit_fields_into("__l", w, lifted)
      end
      parts[#parts + 1] = ("sh.forstate[%d] = {list=__l, idx=0}"):format(st.id)
      blocks[initp] = table.concat(parts, "; ") .. ("; pc = %d"):format(advp)
      -- DEBUG fires at the `for` header before each iteration (bash), with an element present.
      blocks[advp] = ("local fs = sh.forstate[%d]; fs.idx = fs.idx + 1; if fs.idx > #fs.list then pc = %d else sh:set_str(%q, fs.list[fs.idx]); %spc = %d end"):format(
        st.id, after, st.name, dbg(st), bodyentry)
      return initp
    elseif t == "if" then
      -- Each clause's condition is either a native arith `(( ))` (emit_bool) or a
      -- COMMAND LIST run for its status. Both compile — the command condition is a
      -- sub-CFG run with sh.noerr raised (errexit-exempt, like the interpreter),
      -- then we branch on sh.status. No delegation. Flatten bodies once, then build
      -- clauses back-to-front so each false-branch target (the next condition, the
      -- else body, or `after`) already exists.
      if st.redirs then return delegate(st, after) end -- redirs on the whole `if`: interp applies them
      local bentry = {}
      local has_else = false
      for i, cl in ipairs(st.clauses) do bentry[i] = flatten_list(cl.body, after); if not cl.cond then has_else = true end end
      -- With no else clause, falling past every (false) condition runs no body, so
      -- the `if` yields status 0 (bash) — route that fall-through through a reset.
      local fallthrough = after
      if not has_else then local s0 = newpc(); blocks[s0] = ("sh.status = 0; pc = %d"):format(after); fallthrough = s0 end
      local condentry = {}
      for i = #st.clauses, 1, -1 do
        local cl = st.clauses[i]
        local nxt = st.clauses[i + 1] and (condentry[i + 1] or bentry[i + 1]) or fallthrough
        if not cl.cond then
          condentry[i] = bentry[i] -- an `else` clause: its body runs unconditionally
        else
          local arith = cond_arith(cl.cond)
          local tarith = not arith and test_as_arith(cl.cond, lifted) -- `[ A -op B ]`, integer operands
          if arith and not not_compilable(arith) and not arith_side_effect(arith) then
            local cp = newpc()
            blocks[cp] = ("if %s then pc = %d else pc = %d end"):format(emit_bool(arith, lifted), bentry[i], nxt)
            condentry[i] = cp
          elseif tarith then -- native int64 compare, and set [ ]'s own $? (0/1)
            local cp = newpc()
            blocks[cp] = ("sh.status = (%s) and 0 or 1; if sh.status == 0 then pc = %d else pc = %d end")
              :format(emit_bool(tarith, lifted), bentry[i], nxt)
            condentry[i] = cp
          else -- command condition: noerr++ ; run list ; noerr-- ; branch on status
            local donep = newpc()
            blocks[donep] = ("sh.noerr = sh.noerr - 1; if sh.status == 0 then pc = %d else pc = %d end")
              :format(bentry[i], nxt)
            local listentry = flatten_list(cl.cond, donep)
            local prep = newpc()
            blocks[prep] = ("sh.noerr = sh.noerr + 1; pc = %d"):format(listentry)
            condentry[i] = prep
          end
        end
      end
      return condentry[1] or after
    elseif t == "andor" then
      -- `a && b || c`: run item 1, then each item iff the previous status matches
      -- its operator (&& on 0, || on non-zero) — pure control flow. Errexit exempts
      -- every operand EXCEPT the final one that runs (bash), so raise sh.noerr across
      -- the non-final operands and restore it right before the last, letting only its
      -- own errchk fire. Status is the last item that ran (natural). break/continue
      -- inside an operand compile to native jumps via flatten_stmt (that's why this
      -- must be real codegen, not delegation). `!`-negation lives on each pipeline.
      if st.redirs then return delegate(st, after) end
      local items = st.items
      local nI = #items
      local runafter = {} -- where item i flows after running
      for i = 1, nI - 1 do runafter[i] = 0 end -- filled with checkp[i+1] below
      runafter[nI] = after
      local checkp = {}
      for i = 2, nI do checkp[i] = newpc() end
      for i = 1, nI - 1 do runafter[i] = checkp[i + 1] end
      local runentry = {}
      for i = 1, nI do runentry[i] = flatten_stmt(items[i].cmd, runafter[i]) end
      for i = 2, nI do
        local cmp = (items[i].op == "&&") and "==" or "~=" -- && runs on success, || on failure
        if i == nI then -- last operand: restore noerr so its OWN errchk applies
          blocks[checkp[i]] = ("sh.noerr = sh.noerr - 1; if sh.status %s 0 then pc = %d else pc = %d end")
            :format(cmp, runentry[i], after)
        else
          blocks[checkp[i]] = ("if sh.status %s 0 then pc = %d else pc = %d end")
            :format(cmp, runentry[i], checkp[i + 1])
        end
      end
      local entry = newpc()
      -- raise noerr for the non-final operands; a lone-item andor never occurs (>=2).
      blocks[entry] = ("sh.noerr = sh.noerr + 1; pc = %d"):format(runentry[1])
      return entry
    elseif t == "subshell" then
      -- ( body ): a subshell is not special, just SEPARATED — fork, and the child
      -- runs the body as a BOUNDED sub-CFG that _exits at its end (so it never runs
      -- the top-level continuation); the parent waits. The body's loops get their
      -- own loopPc entries, so a forked child that started in interp can OSR into
      -- the RIGHT place (its own fragment), honoring interp/bg-compile/OSR. Redirs
      -- on the subshell delegate for now.
      if st.redirs then return delegate(st, after) end
      -- A body that toggles options with `set` (e.g. `set -e` mid-body) needs the
      -- interpreter's per-command semantics, which the straight-line sub-CFG can't
      -- reproduce — delegate the whole subshell (interp forks + enforces it).
      if body_runs_set(st.body) then return delegate(st, after) end
      -- Under errexit INHERITED at entry, likewise delegate at runtime (the fork +
      -- errexit enforcement happen in the interpreter). errexit is off in the
      -- hot-loop case, so the compiled fork+body path still applies for speed.
      local delpc = delegate(st, after)
      local exitpc = newpc(); blocks[exitpc] = "rt.subshell_exit(sh.status or 0)"
      -- A subshell is a fork: break/continue inside it target only loops WITHIN the
      -- subshell, never the parent's. Hide the enclosing loopstack while flattening
      -- the body (a break/continue with no in-subshell loop becomes a no-op, like
      -- bash), then restore it for the parent's control flow.
      local saved_loops = loopstack; loopstack = {}
      local bodyentry = flatten_list(st.body, exitpc)
      loopstack = saved_loops
      local p = newpc()
      blocks[p] = ("if sh.opt_e then pc = %d else local __pid = rt.subshell_fork(sh); if __pid == 0 then pc = %d else sh.status = rt.subshell_wait(__pid); pc = %d end end")
        :format(delpc, bodyentry, after)
      return p
    else
      return delegate(st, after) -- unknown/cold statement: run it via the interpreter
    end
  end

  flatten_list = function(list, after)
    local nextpc = after
    for k = #list, 1, -1 do nextpc = flatten_stmt(list[k], nextpc) end
    return nextpc
  end

  local nextpc = DONE
  for k = #stmts, 1, -1 do
    nextpc = flatten_stmt(stmts[k], nextpc)
    stmtPc[k] = nextpc
  end
  -- Top-level line-abort markers (parity with the interp's line model): each
  -- top-level statement is entered through a tiny marker that records `_ff`, the
  -- pc to fast-forward to if a div0/failglob lineabort fires — the marker of the
  -- first LATER statement on a NEW line (or DONE). run's retry loop jumps there
  -- and sets $?=1 (a "fancy goto"), so `;` is not a newline and a fatal expansion
  -- aborts only the rest of the current line, matching the interpreter.
  if toplevel then
    -- Sync lifted vars to sh at each marker so, on a lineabort, the tier's retry
    -- wrapper can re-enter run at sh._ff with the pre-statement state intact (run
    -- re-seeds lifted from sh). This is once per TOP-LEVEL statement, never inside a
    -- hot loop body, so it costs nothing on the fast path.
    local wb = {}
    for n in pairs(lifted) do wb[#wb + 1] = ("sh:aset(%q, %s)"):format(n, lname(n)) end
    local wbs = #wb > 0 and (table.concat(wb, "; ") .. "; ") or ""
    local real, mark = {}, {}
    for k = 1, #stmts do real[k] = stmtPc[k]; mark[k] = newpc() end
    for k = 1, #stmts do
      local ff = DONE
      for j = k + 1, #stmts do if (stmts[j].line or 0) > (stmts[k].line or 0) then ff = mark[j]; break end end
      blocks[mark[k]] = ("sh._ff = %d; %spc = %d"):format(ff, wbs, real[k])
      stmtPc[k] = mark[k] -- OSR resume enters at the marker so sh._ff + state are set
    end
    return { blocks = blocks, npc = npc, entry = mark[1] or DONE, loopPc = loopPc, stmtPc = stmtPc, loopvars = loopvars }
  end
  return { blocks = blocks, npc = npc, entry = stmtPc[1] or DONE, loopPc = loopPc, stmtPc = stmtPc, loopvars = loopvars }
end

-- Assemble a CFG into a Lua function string. `liftvars` (top-level only) are
-- seeded from `sh` on entry and written back on exit.
-- opts.runlocals: lifted vars DECLARED as run()-locals here (register-allocated,
-- fast in hot loops). opts.upvals: lifted vars declared at module level (shared
-- as upvalues with functions) — seeded/written-back but not re-declared. Both are
-- seeded from `sh` on entry and written back on exit (run() only).
local function assemble(cfg, sig, opts)
  opts = opts or {}
  local o = { sig }
  -- register compiled function closures into sh.functions so the interpreter
  -- (reached via delegation) can call them too — full interp/compiled interop.
  for _, n in ipairs(opts.register or {}) do o[#o + 1] = ("  sh.functions[%q] = %s"):format(n, fnlname(n)) end
  -- verbatim definition source for `declare -f`/`type` (parity with the interpreter)
  if opts.funcsrc and next(opts.funcsrc) then
    o[#o + 1] = "  sh.func_src = sh.func_src or {}"
    for n, txt in pairs(opts.funcsrc) do o[#o + 1] = ("  sh.func_src[%q] = %q"):format(n, txt) end
  end
  for _, n in ipairs(opts.runlocals or {}) do o[#o + 1] = ("  local %s = sh:aget(%q)"):format(lname(n), n) end
  for _, n in ipairs(opts.upvals or {}) do o[#o + 1] = ("  %s = sh:aget(%q)"):format(lname(n), n) end
  -- per-loop status holders (while-command loops): plain native locals, init 0.
  for _, v in ipairs(cfg.loopvars or {}) do o[#o + 1] = ("  local %s = 0"):format(v) end
  -- pc stays a plain LOCAL (register-allocated, fast in hot loops). A div0/failglob
  -- lineabort thrown from compiled code is caught by the tier's retry wrapper, which
  -- re-enters run at sh._ff — the markers wrote lifted state + sh._ff back per
  -- top-level statement, so no closure/upvalue boxing (which would slow hot loops).
  o[#o + 1] = opts.toplevel and ("  pc = pc or %d"):format(cfg.entry) or ("  local pc = %d"):format(cfg.entry)
  o[#o + 1] = "  while true do"
  for p = 0, cfg.npc - 1 do
    o[#o + 1] = ("    %s pc == %d then %s"):format(p == 0 and "if" or "elseif", p, cfg.blocks[p])
  end
  o[#o + 1] = "    end"
  o[#o + 1] = "  end"
  for _, n in ipairs(opts.runlocals or {}) do o[#o + 1] = ("  sh:aset(%q, %s)"):format(n, lname(n)) end
  for _, n in ipairs(opts.upvals or {}) do o[#o + 1] = ("  sh:aset(%q, %s)"):format(n, lname(n)) end
  o[#o + 1] = "end"
  return table.concat(o, "\n")
end

-- The CFG compiler is a subset. Throw for anything it can't faithfully compile,
-- so cache.lua/tier fall back to the interpreter (the semantic oracle) rather
-- than miscompiling. As coverage grows these gates are removed one by one.
local function assert_compilable(stmts)
  for _, st in ipairs(stmts) do
    local t = st.t
    if t == "parse_error" then error("curse-nocompile: parse_error (deferred)")
    elseif t == "arithcmd" then error("curse-nocompile: (( )) command")
    elseif t == "andor" then error("curse-nocompile: && / || list")
    elseif t == "pipeline" then error("curse-nocompile: pipeline")
    elseif t == "case" then error("curse-nocompile: case")
    elseif t == "group" then error("curse-nocompile: group")
    elseif t == "subshell" then
      if st.redirs then error("curse-nocompile: subshell with redirs") end
      assert_compilable(st.body) -- bare ( body ) compiles: fork + bounded sub-CFG
    elseif t == "dbracket" then error("curse-nocompile: [[ ]]")
    elseif t == "arrayassign" then error("curse-nocompile: array assign")
    elseif t == "assign" and (st.index or st.append) then error("curse-nocompile: array/append assign")
    elseif t == "whilec" then
      if st.negate or cond_arith(st.cond) == nil then error("curse-nocompile: while/until cond") end
      assert_compilable(st.body)
    elseif t == "if" then
      for _, cl in ipairs(st.clauses) do
        if cl.cond ~= nil and cond_arith(cl.cond) == nil then error("curse-nocompile: if cond") end
        assert_compilable(cl.body)
      end
    elseif t == "forc" or t == "forin" or t == "funcdef" then
      assert_compilable(st.body)
    elseif t == "simple" then
      if st.redirs then error("curse-nocompile: redirection") end
      local w1 = st.words[1]
      local cmd = w1 and w1.parts[1] and w1.parts[1].lit
      local BUILTIN = { test = 1, ["["] = 1, exit = 1, cd = 1, unset = 1,
        set = 1, shift = 1, read = 1, export = 1, declare = 1, typeset = 1 }
      if BUILTIN[cmd] then error("curse-nocompile: builtin " .. cmd) end
    end
  end
end

function M.emit(ast)
  emit_has_attr = scan_attr(ast.stmts) -- gate compiled attribute-aware scalar assign
  emit_has_err = scan_trap(ast.stmts, { ERR = 1 }) -- gate compiled ERR-trap firing
  emit_has_debug = scan_trap(ast.stmts, { DEBUG = 1 }) -- gate compiled DEBUG-trap firing
  local funcflags, inlinable, inlinefns = {}, {}, {}
  -- With a DEBUG/ERR trap, DON'T inline: an inlined body runs at the caller's level,
  -- where its commands would fire DEBUG/ERR that bash scopes to the (un-entered)
  -- function. A normal call fires the trap once at the call site and keeps the body
  -- silent (its build_cfg is non-toplevel).
  local no_inline = emit_has_err or emit_has_debug
  for _, st in ipairs(ast.stmts) do
    if st.t == "funcdef" then
      funcflags[st.name] = func_flags(st.body)
      if not no_inline and inlinable_body(st.body) then inlinable[st.name] = true; inlinefns[st.name] = st.body end
    end
  end
  -- Lift purely-arith vars to native int64. A var touched by no OUT-OF-LINE
  -- function becomes a run()-LOCAL (register-allocated — fast in hot loops); a
  -- direct call to an inlinable function is spliced in, so its var access counts
  -- as run() access. A var reached through a non-inlined function becomes a
  -- module-level UPVALUE both run() and that function's closure see (no hash
  -- lookup, no desync) — it can't be register-held across a loop, but such vars
  -- are updated per-call, not per-hot-iteration. Every fn_x is still emitted (for
  -- indirect/dynamic dispatch).
  local lifted = analyze_lift(ast)
  local funcTouched = {}
  collect_funcvars(ast.stmts, funcTouched, inlinable)
  local upvals, runlocals = {}, {}
  for n in pairs(lifted) do
    if funcTouched[n] then upvals[#upvals + 1] = n else runlocals[#runlocals + 1] = n end
  end
  table.sort(upvals); table.sort(runlocals)
  local upset = {}; for _, n in ipairs(upvals) do upset[n] = true end

  local o = { 'local rt = require("runtime")', 'local I = require("interp")',
    'local bit = require("bit")', 'local __noop = function() end' }
  if #upvals > 0 then
    local vs = {}
    for _, n in ipairs(upvals) do vs[#vs + 1] = lname(n) end
    o[#o + 1] = "local " .. table.concat(vs, ", ") -- module-level upvalues (shared with non-inlined functions)
  end
  local decls = {}
  for name in pairs(funcflags) do decls[#decls + 1] = fnlname(name) end
  if #decls > 0 then o[#o + 1] = "local " .. table.concat(decls, ", ") end
  for _, st in ipairs(ast.stmts) do
    if st.t == "funcdef" then
      -- keep every fn_x (indirect/dynamic dispatch); it can't see run-locals, so
      -- it lifts only the shared upvalues and is sh-direct for the rest.
      local cfg = build_cfg(st.body, upset, funcflags, inlinefns)
      o[#o + 1] = assemble(cfg, fnlname(st.name) .. " = function(sh)", {})
    end
  end
  local funcnames = {}
  for name in pairs(funcflags) do funcnames[#funcnames + 1] = name end
  table.sort(funcnames)
  local funcsrc = {} -- name -> verbatim definition text (top-level funcdefs)
  for _, st in ipairs(ast.stmts) do if st.t == "funcdef" and st.deftext then funcsrc[st.name] = st.deftext end end
  local top = build_cfg(ast.stmts, lifted, funcflags, inlinefns, true)
  o[#o + 1] = "local loopPc = " .. serialize(top.loopPc)
  o[#o + 1] = "local stmtPc = " .. serialize(top.stmtPc)
  o[#o + 1] = assemble(top, "local function run(sh, pc)",
    { runlocals = runlocals, upvals = upvals, toplevel = true, register = funcnames, funcsrc = funcsrc })
  o[#o + 1] = "return { run = run, loopPc = loopPc, stmtPc = stmtPc }"
  return table.concat(o, "\n") .. "\n"
end

return M
