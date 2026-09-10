-- Tree-walking interpreter over the AST, mutating the shared `sh`. It starts
-- instantly (no compile) and runs statement-by-statement like bash. At each
-- safepoint — a top-level statement boundary and every loop back-edge — it
-- calls `hook(kind, id)`; the tier driver's hook throws {switch=true, resume=…}
-- when the compiled Lua is ready, unwinding here so execution can jump into the
-- compiled code from exactly this point (state is already in `sh`).
local rt = require("runtime")
local i64 = rt.i64
local ffi = require("ffi")
local bit = require("bit")

local M = {}

local function truth(n) return n ~= i64(0) end
local function b2i(b) return b and 1LL or 0LL end

-- ---- `test` / `[` builtin ----
ffi.cdef [[
  int access(const char *path, int mode);
  int chdir(const char *path);
  int curse_stat(const char *path, void *buf) asm("stat");
  int fork(void);
  int dup2(int oldfd, int newfd);
  int dup(int oldfd);
  int open(const char *path, int flags, unsigned int mode);
  int setenv(const char *name, const char *value, int overwrite);
  void _exit(int status);
]]
local C = ffi.C
local statbuf = ffi.new("uint8_t[144]") -- glibc x86-64 struct stat is 144 bytes
local function file_test(op, path)
  if op == "-e" or op == "-a" then return C.access(path, 0) == 0 end
  if op == "-r" then return C.access(path, 4) == 0 end
  if op == "-w" then return C.access(path, 2) == 0 end
  if op == "-x" then return C.access(path, 1) == 0 end
  local ok, rc = pcall(C.curse_stat, path, statbuf)
  if not ok or rc ~= 0 then return false end
  local mode = ffi.cast("uint32_t *", statbuf + 24)[0] -- st_mode @ offset 24
  local fmt = bit.band(mode, 0xF000)
  if op == "-f" then return fmt == 0x8000 end -- S_IFREG
  if op == "-d" then return fmt == 0x4000 end -- S_IFDIR
  if op == "-b" then return fmt == 0x6000 end
  if op == "-c" then return fmt == 0x2000 end
  if op == "-p" then return fmt == 0x1000 end
  if op == "-S" then return fmt == 0xC000 end
  if op == "-s" then return tonumber(ffi.cast("int64_t *", statbuf + 48)[0]) > 0 end -- st_size @ 48
  return false
end
local UNARY_STR = { ["-z"] = true, ["-n"] = true }
local function unary(op, x)
  if op == "-z" then return x == "" end
  if op == "-n" then return x ~= "" end
  return file_test(op, x) -- -e/-f/-d/-r/-w/-x/-s…
end
local function binary(x, op, y)
  if op == "=" or op == "==" then return x == y end
  if op == "!=" then return x ~= y end
  if op == "<" then return x < y end -- string compare (C locale, like bash)
  if op == ">" then return x > y end
  local nx, ny = rt.str_to_i64(x), rt.str_to_i64(y)
  if op == "-eq" then return nx == ny end
  if op == "-ne" then return nx ~= ny end
  if op == "-lt" then return nx < ny end
  if op == "-le" then return nx <= ny end
  if op == "-gt" then return nx > ny end
  if op == "-ge" then return nx >= ny end
  return false
end
-- Evaluate a `test`/`[` argument list (already expanded). Returns a boolean.
local function eval_test(a, lo, hi)
  local n = hi - lo + 1
  if n == 0 then return false end
  if a[lo] == "!" then return not eval_test(a, lo + 1, hi) end
  if n == 1 then return a[lo] ~= "" end
  if n == 2 then return unary(a[lo], a[lo + 1]) end
  if n == 3 then return binary(a[lo], a[lo + 1], a[lo + 2]) end
  -- n>=4: handle a single -a/-o join (deprecated but common), left-associative.
  for j = lo, hi do
    if a[j] == "-o" then return eval_test(a, lo, j - 1) or eval_test(a, j + 1, hi) end
  end
  for j = lo, hi do
    if a[j] == "-a" then return eval_test(a, lo, j - 1) and eval_test(a, j + 1, hi) end
  end
  return false
end
local function do_test(sh, args)
  local lo, hi = 2, #args
  if args[1] == "[" then
    if args[hi] ~= "]" then sh.status = 2; return end
    hi = hi - 1
  end
  local ok, res = pcall(eval_test, args, lo, hi)
  sh.status = (ok and res) and 0 or 1
end

local eval  -- arithmetic evaluator (forward decl)
eval = function(sh, e)
  local k = e.k
  if k == "num" then return rt.str_to_i64(e.v) end
  if k == "var" then return sh:aget(e.name) end
  if k == "param" then return rt.str_to_i64(sh:param(e.n)) end
  if k == "un" then
    local v = eval(sh, e.e)
    if e.op == "-" then return -v end
    if e.op == "!" then return b2i(not truth(v)) end
    if e.op == "~" then return bit.bnot(v) end
  end
  if k == "tern" then
    if truth(eval(sh, e.c)) then return eval(sh, e.a) else return eval(sh, e.b) end
  end
  if k == "bin" then
    local op = e.op
    if op == "&&" then return b2i(truth(eval(sh, e.l)) and truth(eval(sh, e.r))) end
    if op == "||" then return b2i(truth(eval(sh, e.l)) or truth(eval(sh, e.r))) end
    local l, r = eval(sh, e.l), eval(sh, e.r)
    if op == "+" then return l + r end
    if op == "-" then return l - r end
    if op == "*" then return l * r end
    if op == "/" then return l / r end
    if op == "%" then return l % r end
    if op == "==" then return b2i(l == r) end
    if op == "!=" then return b2i(l ~= r) end
    if op == "<" then return b2i(l < r) end
    if op == "<=" then return b2i(l <= r) end
    if op == ">" then return b2i(l > r) end
    if op == ">=" then return b2i(l >= r) end
    if op == "&" then return bit.band(l, r) end
    if op == "|" then return bit.bor(l, r) end
    if op == "^" then return bit.bxor(l, r) end
    if op == "<<" then return bit.lshift(l, tonumber(r) % 64) end
    if op == ">>" then return bit.arshift(l, tonumber(r) % 64) end
    if op == "**" then
      local base, n, res = l, tonumber(r), i64(1)
      for _ = 1, n do res = res * base end
      return res
    end
  end
  if k == "asgn" then
    local v = eval(sh, e.e)
    if e.op ~= "=" then
      local cur = sh:aget(e.name)
      local o = e.op:sub(1, 1)
      if o == "+" then v = cur + v elseif o == "-" then v = cur - v
      elseif o == "*" then v = cur * v elseif o == "/" then v = cur / v
      elseif o == "%" then v = cur % v end
    end
    return sh:aset(e.name, v)
  end
  if k == "post" then
    local cur = sh:aget(e.name); sh:aset(e.name, cur + i64(e.d)); return cur
  end
  if k == "pre" then
    local v = sh:aget(e.name) + i64(e.d); return sh:aset(e.name, v)
  end
  error("interp: bad arith node " .. tostring(k))
end
M.eval = eval

local expand_word -- forward (expand_part_str expands pexp args via it)

-- Resolve an array subscript to a key: a string (word-expanded) for an
-- associative array, else an integer (arith-evaluated) for an indexed one.
local function array_key(sh, name, index_raw)
  local P = require("parser")
  if sh:is_assoc(name) then return expand_word(sh, P.parse_word(index_raw)) end
  return tonumber(rt.i64_to_str(eval(sh, P.arith(index_raw)))) or 0
end

-- Expand ONE part to its string value (a multi-element @/* part is joined here;
-- expand_to_fields treats those specially for word-splitting).
local function expand_part_str(sh, p)
  if p.lit ~= nil then return p.lit
  elseif p.var then return sh:get(p.var)
  elseif p.param then return sh:param(p.param)
  elseif p.special then
    if p.special == "#" then return tostring(sh.nparams)
    elseif p.special == "@" or p.special == "*" then return sh:paramsJoin(" ")
    elseif p.special == "?" then return tostring(sh.status)
    elseif p.special == "$" then return tostring(sh:pid())
    elseif p.special == "!" then return sh.last_bg_pid or "" end
    return ""
  elseif p.arith then return rt.i64_to_str(eval(sh, require("parser").arith(p.arith)))
  elseif p.cmdsub then return sh:capture_src(p.cmdsub)
  elseif p.pexp then
    local pe, P = p.pexp, require("parser")
    local subkey
    if pe.index and pe.index ~= "@" and pe.index ~= "*" then
      subkey = array_key(sh, pe.name, pe.index)
    end
    local arg = pe.arg and expand_word(sh, P.parse_word(pe.arg)) or nil
    local arg2 = pe.arg2 and expand_word(sh, P.parse_word(pe.arg2)) or nil
    return sh:expand_param(pe, arg, arg2, subkey)
  end
  return ""
end

-- Expand a word to a single string (assignment RHS, case subject, arith index —
-- contexts that do NOT word-split).
expand_word = function(sh, w)
  local buf = {}
  for _, p in ipairs(w.parts) do buf[#buf + 1] = expand_part_str(sh, p) end
  return table.concat(buf)
end

-- A part that expands to multiple elements: $@ / $* / ${a[@]} / ${a[*]} /
-- ${!a[@]} (keys). ${#a[@]} (op="len") is a single count, NOT multi.
local function is_multi(p)
  if not p.pexp then return p.special == "@" or p.special == "*" end
  if p.pexp.op == "len" then return false end
  return p.pexp.index == "@" or p.pexp.index == "*"
end
local function multi_elems(sh, p) -- returns element list, star?
  if p.pexp then
    local star = (p.pexp.index == "*")
    if p.pexp.op == "indices" then -- ${!a[@]} -> the keys/indices
      local ix = sh:array_indices(p.pexp.name); local t = {}
      for i = 1, #ix do t[i] = tostring(ix[i]) end
      return t, star
    end
    return sh:array_values(p.pexp.name), star
  end
  local els = {}; for i = 1, sh.nparams do els[i] = sh.params[i] end
  return els, (p.special == "*")
end

-- Expand a word to a LIST of fields (command args, for-in lists): unquoted
-- expansions split on default-IFS whitespace; quoted text never splits; "$@" /
-- "${a[@]}" yield one field per element.
local function expand_to_fields(sh, w)
  local fields, cur = {}, nil
  local function push() if cur ~= nil then fields[#fields + 1] = cur; cur = nil end end
  -- append v to cur, splitting on whitespace (unquoted expansion)
  local function split_into(v)
    if v == "" then return end
    local toks = {}
    for tk in v:gmatch("%S+") do toks[#toks + 1] = tk end
    if #toks == 0 then push(); return end -- all whitespace: field break
    if v:match("^%s") then push() end
    cur = (cur or "") .. toks[1]
    for k = 2, #toks do push(); cur = toks[k] end
    if v:match("%s$") then push() end
  end
  for _, p in ipairs(w.parts) do
    if is_multi(p) then
      local els, star = multi_elems(sh, p)
      if p.q then
        if star then cur = (cur or "") .. table.concat(els, " ")
        else for k = 1, #els do if k == 1 then cur = (cur or "") .. els[k] else push(); cur = els[k] end end end
      else
        split_into(table.concat(els, " "))
      end
    else
      local s = expand_part_str(sh, p)
      if p.q or p.lit ~= nil then cur = (cur or "") .. s -- quoted or literal: no split
      else split_into(s) end -- unquoted expansion: split
    end
  end
  push()
  return fields
end

local exec_list  -- forward

-- ---- redirections ----
-- Apply a command's redirs, saving fds 0/1/2 for restore. open flags: 577 =
-- O_WRONLY|O_CREAT|O_TRUNC, 1089 = |O_APPEND, 0 = O_RDONLY; mode 0644.
-- Feed a string as a command's stdin (heredoc/herestring): write to a temp file,
-- open it, dup2 onto fd 0, unlink (the open fd keeps the inode alive).
local function feed_stdin(fd, body)
  local tmp = os.tmpname()
  local w = io.open(tmp, "w"); if w then w:write(body); w:close() end
  local f = C.open(tmp, 0, 0)
  if f >= 0 then C.dup2(f, fd); C.close(f) end
  os.remove(tmp)
end
local function apply_redirs(sh, redirs)
  local save = { C.dup(0), C.dup(1), C.dup(2) }
  for _, r in ipairs(redirs) do
    if r.op == "out" then local f = C.open(r.target, 577, 420); if f >= 0 then C.dup2(f, r.fd); C.close(f) end
    elseif r.op == "app" then local f = C.open(r.target, 1089, 420); if f >= 0 then C.dup2(f, r.fd); C.close(f) end
    elseif r.op == "in" then local f = C.open(r.target, 0, 0); if f >= 0 then C.dup2(f, r.fd); C.close(f) end
    elseif r.op == "outboth" then local f = C.open(r.target, 577, 420); if f >= 0 then C.dup2(f, 1); C.dup2(f, 2); C.close(f) end
    elseif r.op == "heredoc" then
      local P = require("parser")
      local body = r.expand and expand_word(sh, P.parse_heredoc(r.body or "")) or (r.body or "")
      feed_stdin(r.fd or 0, body)
    elseif r.op == "herestring" then
      local P = require("parser")
      local body = expand_word(sh, P.parse_word(r.word or "")) .. "\n"
      feed_stdin(r.fd or 0, body)
    elseif r.op == "dup" or r.op == "dupin" then
      if r.target == "-" then C.close(r.fd) else local m = tonumber(r.target); if m then C.dup2(m, r.fd) end end
    end
  end
  return save
end
local function restore_redirs(save)
  for fd = 0, 2 do local s = save[fd + 1]; if s >= 0 then C.dup2(s, fd); C.close(s) end end
end

-- Dispatch one already-expanded simple command (no redirs — the caller sets those
-- up). Builtins first, then user functions, then external.
local function exec_simple(sh, args, hook)
  local cmd = args[1]
  if cmd == nil then sh.status = 0
  elseif cmd == "echo" then sh:echo(unpack(args, 2))
  elseif cmd == ":" or cmd == "true" then sh.status = 0
  elseif cmd == "false" then sh.status = 1
  elseif cmd == "[" or cmd == "test" then do_test(sh, args)
  elseif cmd == "return" then
    error({ __curse_return = args[2] and tonumber(args[2]) or sh.status })
  elseif cmd == "exit" then
    error({ __curse_exit = args[2] and tonumber(args[2]) or sh.status })
  elseif cmd == "cd" then
    local dir = args[2] or os.getenv("HOME") or ""
    sh.status = (C.chdir(dir) == 0) and 0 or 1
  elseif cmd == "unset" then
    for j = 2, #args do sh.vars[args[j]] = nil end
    sh.status = 0
  elseif cmd == "export" or cmd == "declare" or cmd == "typeset" then
    -- export/declare [-A] NAME[=val]…: set the var; export also pushes to the
    -- process env so posix_spawn children inherit it. -A marks associative.
    local doexport, assoc = (cmd == "export"), false
    for j = 2, #args do
      local a = args[j]
      if a:sub(1, 1) == "-" and #a > 1 then
        if a:find("A") then assoc = true end
      else
        local nm, val = a:match("^([%a_][%w_]*)=(.*)$")
        if nm then
          if assoc then sh:declare_assoc(nm) end
          sh:set_str(nm, val); if doexport then C.setenv(nm, val, 1) end
        elseif a:match("^[%a_][%w_]*$") then
          if assoc then sh:declare_assoc(a)
          elseif doexport then C.setenv(a, sh:get(a), 1) end
        end
      end
    end
    sh.status = 0
  elseif cmd == "set" then
    -- set -- ARGS / set ARGS: replace positional params. Options (-e/-o/…) accepted, ignored.
    if args[2] == "--" or (args[2] and args[2]:sub(1, 1) ~= "-") then
      local j = (args[2] == "--") and 3 or 2
      local np = {}; local n = 0
      for k = j, #args do n = n + 1; np[n] = args[k] end
      sh.params = np; sh.nparams = n
    end
    sh.status = 0
  elseif cmd == "read" then
    -- read [-r] [-a arr] [-p prompt] VAR...  (line from stdin, split on IFS)
    local raw, arr, j = false, nil, 2
    while j <= #args do
      local a = args[j]
      if a == "-r" then raw = true; j = j + 1
      elseif a == "-a" then arr = args[j + 1]; j = j + 2
      elseif a == "-p" then j = j + 2 -- prompt: no tty, skip
      elseif a:sub(1, 1) == "-" and #a > 1 then j = j + 1 -- ignore -n/-d/-s/…
      else break end
    end
    local vars = {}
    for k = j, #args do vars[#vars + 1] = args[k] end
    local line = io.read("*l")
    if line == nil then
      sh.status = 1 -- EOF
    else
      if not raw then line = line:gsub("\\(.)", "%1") end
      local fields = {}
      for tok in line:gmatch("%S+") do fields[#fields + 1] = tok end
      if arr then
        sh:array_assign(arr, fields, false)
      elseif #vars == 0 then
        sh:set_str("REPLY", line)
      else
        for k = 1, #vars do
          if k < #vars then
            sh:set_str(vars[k], fields[k] or "")
          else
            local rest = {}
            for m = k, #fields do rest[#rest + 1] = fields[m] end
            sh:set_str(vars[k], table.concat(rest, " "))
          end
        end
      end
      sh.status = 0
    end
  elseif cmd == "shift" then
    local nn = tonumber(args[2]) or 1
    if nn > sh.nparams then nn = sh.nparams end
    for k = 1, sh.nparams - nn do sh.params[k] = sh.params[k + nn] end
    for k = sh.nparams - nn + 1, sh.nparams do sh.params[k] = nil end
    sh.nparams = sh.nparams - nn
    sh.status = 0
  elseif cmd == "local" then
    for j = 2, #args do sh:localAssign(args[j]) end
    sh.status = 0
  elseif sh.functions[cmd] then
    sh.calldepth = sh.calldepth + 1 -- OSR gate: no handoff inside a call
    sh:pushCall(unpack(args, 2))
    local ok, err = pcall(exec_list, sh, sh.functions[cmd], hook, false)
    sh:popCall()
    sh.calldepth = sh.calldepth - 1
    if not ok then
      if type(err) == "table" and err.__curse_return then sh.status = err.__curse_return
      else error(err) end
    end
  else sh:exec(unpack(args)) end -- external command
end

-- [[ … ]] evaluation. Reuses the test builtin's unary/binary; == is a shell glob
-- (literal when the RHS was quoted), =~ a regex (Lua-pattern approximation of ERE).
local function eval_dbracket(sh, node)
  local k = node.kind
  if k == "and" then return eval_dbracket(sh, node.l) and eval_dbracket(sh, node.r) end
  if k == "or" then return eval_dbracket(sh, node.l) or eval_dbracket(sh, node.r) end
  if k == "not" then return not eval_dbracket(sh, node.e) end
  if k == "str" then return expand_word(sh, node.word) ~= "" end
  if k == "unary" then return unary(node.op, expand_word(sh, node.word)) end
  if k == "binary" then
    local l, r, op = expand_word(sh, node.l), expand_word(sh, node.r), node.op
    if op == "==" or op == "=" then
      if node.rq then return l == r else return rt.glob_match(l, r) end
    elseif op == "!=" then
      if node.rq then return l ~= r else return not rt.glob_match(l, r) end
    elseif op == "=~" then
      local ok, m = pcall(function() return l:match(r) ~= nil end); return ok and m
    else return binary(l, op, r) end -- < > -eq -ne -lt …
  end
  return false
end

local function exec_stmt(sh, st, hook)
  local t = st.t
  if t == "assign" then
    if st.index then
      sh:array_set(st.name, array_key(sh, st.name, st.index), expand_word(sh, st.rhs), st.append)
    elseif st.arith then
      sh:aset(st.name, eval(sh, st.arith))
    elseif st.append then
      sh:set_str(st.name, sh:get(st.name) .. expand_word(sh, st.rhs))
    else
      sh:set_str(st.name, expand_word(sh, st.rhs))
    end
    sh.status = 0
  elseif t == "arrayassign" then
    local vals = {}
    for _, w in ipairs(st.elems) do vals[#vals + 1] = expand_word(sh, w) end
    sh:array_assign(st.name, vals, st.append)
    sh.status = 0
  elseif t == "funcdef" then
    sh.functions[st.name] = st.body
    sh.status = 0
  elseif t == "simple" then
    local args = {}
    for _, w in ipairs(st.words) do
      local fs = expand_to_fields(sh, w)
      for k = 1, #fs do args[#args + 1] = fs[k] end
    end
    if st.redirs then
      -- reconfigure fds and route builtin output (sh.out) to fd 1 for the command
      local save, savedout = apply_redirs(sh, st.redirs), sh.out
      sh.out = io.write
      local ok, err = pcall(exec_simple, sh, args, hook)
      io.flush(); sh.out = savedout; restore_redirs(save)
      if not ok then error(err) end
    else
      exec_simple(sh, args, hook)
    end
  elseif t == "forc" then
    if st.init then eval(sh, st.init) end
    while true do
      hook("loop", st.id)
      if st.cond and not truth(eval(sh, st.cond)) then break end
      exec_list(sh, st.body, hook, false)
      if st.step then eval(sh, st.step) end
    end
  elseif t == "whilec" then
    while true do
      hook("loop", st.id)
      exec_list(sh, st.cond, hook, false)
      local go = (sh.status == 0)
      if st.negate then go = not go end -- until
      if not go then break end
      exec_list(sh, st.body, hook, false)
    end
  elseif t == "parse_error" then
    -- Reached the unparseable tail (e.g. a makeself binary payload) — bash would
    -- syntax-error here too. If an earlier exit fired, we never get here.
    io.stderr:write("curse: syntax error" .. (st.line and (": line " .. st.line) or "") .. "\n")
    error({ __curse_exit = 2 })
  elseif t == "group" then
    -- { list; } runs in the current shell; redirs apply to the whole group
    if st.redirs then
      local save, savedout = apply_redirs(sh, st.redirs), sh.out
      sh.out = io.write
      local ok, err = pcall(exec_list, sh, st.body, hook, false)
      io.flush(); sh.out = savedout; restore_redirs(save)
      if not ok then error(err) end
    else
      exec_list(sh, st.body, hook, false)
    end
  elseif t == "subshell" then
    -- ( list ) runs in a forked child: env/var changes don't escape, like bash
    local pid = C.fork()
    if pid == 0 then
      local ok, err = pcall(function()
        if st.redirs then apply_redirs(sh, st.redirs) end
        sh.out = io.write
        exec_list(sh, st.body, hook, false)
      end)
      if not ok and type(err) == "table" then sh.status = err.__curse_exit or err.__curse_return or sh.status end
      io.flush() -- flush BEFORE _exit (which doesn't); exit/error skips an inline flush
      C._exit(sh.status or 0)
    end
    local stbuf = ffi.new("int[1]"); C.waitpid(pid, stbuf, 0)
    local s = stbuf[0]; local sig = bit.band(s, 0x7f)
    sh.status = (sig ~= 0 and sig ~= 0x7f) and (128 + sig) or bit.rshift(bit.band(s, 0xff00), 8)
  elseif t == "arithcmd" then
    sh.status = truth(eval(sh, st.expr)) and 0 or 1
  elseif t == "dbracket" then
    sh.status = eval_dbracket(sh, st.expr) and 0 or 1
  elseif t == "case" then
    local subj = expand_word(sh, st.subject)
    local P = require("parser")
    for _, cl in ipairs(st.clauses) do
      local matched = false
      for _, pat in ipairs(cl.pats) do
        local g = expand_word(sh, P.parse_word(pat)) -- resolve vars in the pattern
        if rt.glob_match(subj, g) then matched = true; break end
      end
      if matched then exec_list(sh, cl.body, hook, false); break end
    end
  elseif t == "andor" then
    -- run each pipeline, short-circuiting on the running exit status
    for _, it in ipairs(st.items) do
      local go
      if it.op == nil then go = true
      elseif it.op == "&&" then go = (sh.status == 0)
      else go = (sh.status ~= 0) end -- "||"
      if go then exec_stmt(sh, it.cmd, hook) end
    end
  elseif t == "pipeline" then
    -- fork a child per stage wired by pipes; the last stage's exit status is the
    -- pipeline's. Each child is guarded so a failure can never return into the
    -- interpreter and fork-bomb. (stdout of the last stage goes to the current
    -- fd 1; capture into $() through a pipeline is a known limitation for now.)
    local cmds, nst = st.cmds, #st.cmds
    if nst == 1 then
      exec_stmt(sh, cmds[1], hook) -- just a `! cmd` negation, no real pipe
    else
      local pids, prev_read = {}, -1
      for k = 1, nst do
        local rd, wr = -1, -1
        if k < nst then local p = ffi.new("int[2]"); C.pipe(p); rd, wr = p[0], p[1] end
        local pid = C.fork()
        if pid == 0 then
          pcall(function()
            if prev_read >= 0 then C.dup2(prev_read, 0); C.close(prev_read) end
            if wr >= 0 then C.dup2(wr, 1); C.close(wr) end
            if rd >= 0 then C.close(rd) end
            sh.out = io.write -- this stage writes to its fd 1 (the pipe / terminal)
            exec_stmt(sh, cmds[k], hook)
          end)
          io.flush() -- before _exit (exit/error in the stage would skip an inline flush)
          C._exit(sh.status or 0)
        end
        pids[k] = pid
        if prev_read >= 0 then C.close(prev_read) end
        if wr >= 0 then C.close(wr) end
        prev_read = rd
      end
      if prev_read >= 0 then C.close(prev_read) end
      local stbuf = ffi.new("int[1]")
      for k = 1, nst do
        C.waitpid(pids[k], stbuf, 0)
        if k == nst then
          local s = stbuf[0]
          local sig = bit.band(s, 0x7f)
          sh.status = (sig ~= 0 and sig ~= 0x7f) and (128 + sig) or bit.rshift(bit.band(s, 0xff00), 8)
        end
      end
    end
    if st.negate then sh.status = (sh.status == 0) and 1 or 0 end
  elseif t == "forin" then
    -- expand the word list ONCE (bash semantics) and stash it in sh.forstate so
    -- a mid-loop OSR resumes the same list + index.
    local list = {}
    for _, w in ipairs(st.words) do
      local fs = expand_to_fields(sh, w)
      for k = 1, #fs do list[#list + 1] = fs[k] end
    end
    sh.forstate[st.id] = { list = list, idx = 0 }
    while true do
      hook("loop", st.id)
      local fs = sh.forstate[st.id]
      fs.idx = fs.idx + 1
      if fs.idx > #fs.list then break end
      sh:set_str(st.name, fs.list[fs.idx])
      exec_list(sh, st.body, hook, false)
    end
  elseif t == "if" then
    for _, cl in ipairs(st.clauses) do
      local take
      if cl.cond == nil then take = true
      else exec_list(sh, cl.cond, hook, false); take = (sh.status == 0) end
      if take then exec_list(sh, cl.body, hook, false); break end
    end
  else
    error("interp: bad stmt " .. tostring(t))
  end
end

exec_list = function(sh, stmts, hook, toplevel)
  for k = 1, #stmts do
    if toplevel then hook("stmt", k) end
    exec_stmt(sh, stmts[k], hook)
  end
end
M.exec_list = exec_list

local function finish(sh, ok, err)
  if not ok then
    if type(err) == "table" and err.__curse_exit then sh.status = err.__curse_exit
    elseif type(err) == "table" and err.__curse_return then sh.status = err.__curse_return
    else error(err) end
  end
end

-- Run a whole (already-parsed) program. `hook` defaults to a no-op. A top-level
-- `exit N` unwinds to here and sets $? (like bash ending the script).
function M.run(sh, ast, hook)
  hook = hook or function() end
  finish(sh, pcall(exec_list, sh, ast.stmts, hook, true))
end

-- Run LAZILY from source: parse one top-level statement, execute it, repeat.
-- Instant start on large scripts (no full parse up front), and it never
-- tokenizes past an `exit` — so a hybrid shell+binary installer just works with
-- no special-casing. `hook("stmt", k)` fires per top-level statement (same k as
-- the eager AST, so tier OSR-by-stmt still lines up).
function M.run_lazy(sh, src, hook)
  hook = hook or function() end
  local nextf = require("parser").open(src)
  finish(sh, pcall(function()
    local k = 0
    while true do
      local st = nextf()
      if st == nil then break end
      k = k + 1
      hook("stmt", k)
      exec_stmt(sh, st, hook)
    end
  end))
end

return M
