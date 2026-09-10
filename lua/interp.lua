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
  int curse_lstat(const char *path, void *buf) asm("lstat");
  int isatty(int fd);
  int fork(void);
  int dup2(int oldfd, int newfd);
  int dup(int oldfd);
  int open(const char *path, int flags, unsigned int mode);
  int setenv(const char *name, const char *value, int overwrite);
  int unsetenv(const char *name);
  void _exit(int status);
  unsigned int umask(unsigned int mask);
]]
local C = ffi.C
local statbuf = ffi.new("uint8_t[144]") -- glibc x86-64 struct stat is 144 bytes
-- Signal name/number normalization for `trap`.
local SIGNUM = { HUP = 1, INT = 2, QUIT = 3, ILL = 4, TRAP = 5, ABRT = 6, BUS = 7,
  FPE = 8, KILL = 9, USR1 = 10, SEGV = 11, USR2 = 12, PIPE = 13, ALRM = 14, TERM = 15,
  CHLD = 17, CONT = 18, STOP = 19, TSTP = 20, TTIN = 21, TTOU = 22, SYS = 31 }
local NUMSIG = {}; for k, v in pairs(SIGNUM) do NUMSIG[v] = k end
local function canon_sig(s)
  s = s:upper()
  if s == "0" or s == "EXIT" then return "EXIT" end
  if s == "ERR" or s == "DEBUG" or s == "RETURN" then return s end
  s = s:gsub("^SIG", "")
  if s:match("^%d+$") then local nm = NUMSIG[tonumber(s)]; return nm and ("SIG" .. nm) or nil end
  return SIGNUM[s] and ("SIG" .. s) or nil
end
local function sig_order(canon) -- for printing: EXIT=0, then by signal number
  if canon == "EXIT" then return 0 end
  local nm = canon:gsub("^SIG", ""); return SIGNUM[nm] or 99
end

local function file_test(op, path)
  if op == "-e" or op == "-a" then return C.access(path, 0) == 0 end
  if op == "-r" then return C.access(path, 4) == 0 end
  if op == "-w" then return C.access(path, 2) == 0 end
  if op == "-x" then return C.access(path, 1) == 0 end
  if op == "-t" then return C.isatty(tonumber(path) or -1) == 1 end -- fd is a terminal
  -- -h/-L test the link itself (lstat); everything else follows symlinks (stat)
  local statfn = (op == "-h" or op == "-L") and C.curse_lstat or C.curse_stat
  local ok, rc = pcall(statfn, path, statbuf)
  if not ok or rc ~= 0 then return false end
  local mode = ffi.cast("uint32_t *", statbuf + 24)[0] -- st_mode @ offset 24
  local fmt = bit.band(mode, 0xF000)
  if op == "-f" then return fmt == 0x8000 end -- S_IFREG
  if op == "-d" then return fmt == 0x4000 end -- S_IFDIR
  if op == "-b" then return fmt == 0x6000 end
  if op == "-c" then return fmt == 0x2000 end
  if op == "-p" then return fmt == 0x1000 end
  if op == "-S" then return fmt == 0xC000 end
  if op == "-h" or op == "-L" then return fmt == 0xA000 end -- S_IFLNK
  if op == "-k" then return bit.band(mode, 0x200) ~= 0 end -- sticky
  if op == "-g" then return bit.band(mode, 0x400) ~= 0 end -- setgid
  if op == "-u" then return bit.band(mode, 0x800) ~= 0 end -- setuid
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
-- Recursive descent with `( )` grouping and `-o` (lowest) / `-a` / `!` precedence.
local function eval_test(a, lo, hi)
  local n = hi - lo + 1
  if n <= 0 then return false end
  -- ( expr ): strip only when lo's `(` matches hi's `)`
  if a[lo] == "(" then
    local depth = 0
    for j = lo, hi do
      if a[j] == "(" then depth = depth + 1
      elseif a[j] == ")" then depth = depth - 1; if depth == 0 then
        if j == hi then return eval_test(a, lo + 1, hi - 1) end; break
      end end
    end
  end
  -- -o then -a, paren-aware, only when flanked by operands
  for _, opw in ipairs({ "-o", "-a" }) do
    local depth = 0
    for j = lo, hi do
      if a[j] == "(" then depth = depth + 1
      elseif a[j] == ")" then depth = depth - 1
      elseif a[j] == opw and depth == 0 and j > lo and j < hi then
        local l, r = eval_test(a, lo, j - 1), eval_test(a, j + 1, hi)
        if opw == "-o" then return l or r else return l and r end
      end
    end
  end
  if a[lo] == "!" and n > 1 then return not eval_test(a, lo + 1, hi) end
  if n == 1 then return a[lo] ~= "" end
  if n == 2 then return unary(a[lo], a[lo + 1]) end
  if n == 3 then return binary(a[lo], a[lo + 1], a[lo + 2]) end
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

local expand_word -- forward (used by eval's $-deferred arith and expand_part_str)
local eval  -- arithmetic evaluator (forward decl)
eval = function(sh, e)
  local k = e.k
  if k == "num" then return rt.arith_num(e.v) end
  if k == "var" then
    if e.idx then return rt.arith_num(sh:array_get(e.name, tonumber(rt.i64_to_str(eval(sh, e.idx))))) end
    return sh:aget(e.name)
  end
  if k == "param" then return rt.str_to_i64(sh:param(e.n)) end
  if k == "xpand" then -- deferred: expansions inside $(( )) resolved at runtime
    local P = require("parser")
    return eval(sh, P.arith(expand_word(sh, P.parse_word(e.raw)), true))
  end
  if k == "comma" then eval(sh, e.l); return eval(sh, e.r) end
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
    local iv = e.idx and tonumber(rt.i64_to_str(eval(sh, e.idx))) or nil
    local v = eval(sh, e.e)
    if e.op ~= "=" then
      local cur = iv and rt.arith_num(sh:array_get(e.name, iv)) or sh:aget(e.name)
      local o = e.op:sub(1, 1)
      if o == "+" then v = cur + v elseif o == "-" then v = cur - v
      elseif o == "*" then v = cur * v elseif o == "/" then v = cur / v
      elseif o == "%" then v = cur % v end
    end
    if iv then sh:array_set(e.name, iv, rt.i64_to_str(v)); return v end
    return sh:aset(e.name, v)
  end
  if k == "post" then
    if e.idx then
      local iv = tonumber(rt.i64_to_str(eval(sh, e.idx)))
      local cur = rt.arith_num(sh:array_get(e.name, iv))
      sh:array_set(e.name, iv, rt.i64_to_str(cur + i64(e.d))); return cur
    end
    local cur = sh:aget(e.name); sh:aset(e.name, cur + i64(e.d)); return cur
  end
  if k == "pre" then
    if e.idx then
      local iv = tonumber(rt.i64_to_str(eval(sh, e.idx)))
      local v = rt.arith_num(sh:array_get(e.name, iv)) + i64(e.d)
      sh:array_set(e.name, iv, rt.i64_to_str(v)); return v
    end
    local v = sh:aget(e.name) + i64(e.d); return sh:aset(e.name, v)
  end
  error("interp: bad arith node " .. tostring(k))
end
M.eval = eval


-- Resolve an array subscript to a key: a string (word-expanded) for an
-- associative array, else an integer (arith-evaluated) for an indexed one.
local function array_key(sh, name, index_raw)
  local P = require("parser")
  if sh:is_assoc(name) then return expand_word(sh, P.parse_word(index_raw)) end
  -- indexed: expand $()/$vars in the subscript, then evaluate it as arithmetic
  local ex = expand_word(sh, P.parse_word(index_raw))
  if ex == "" then return 0 end
  local ok, v = pcall(function() return tonumber(rt.i64_to_str(eval(sh, P.arith(ex)))) end)
  return (ok and v) or 0
end

-- Expand ONE part to its string value (a multi-element @/* part is joined here;
-- expand_to_fields treats those specially for word-splitting).
local function expand_part_str(sh, p)
  if p.lit ~= nil then return p.lit
  elseif p.var then
    if sh.opt_u and sh.vars[sh:deref(p.var)] == nil and sh:special_get(p.var) == "" then
      io.stderr:write("curse: " .. p.var .. ": unbound variable\n"); error({ __curse_exit = 1 })
    end
    return sh:get(p.var)
  elseif p.param then
    if sh.opt_u and p.param > sh.nparams then
      io.stderr:write("curse: " .. p.param .. ": unbound variable\n"); error({ __curse_exit = 1 })
    end
    return sh:param(p.param)
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
-- arith-evaluate a slice offset/length expression (e.g. "i-4", "(-4)", "2").
local function arith_int(sh, s)
  if s == nil or s == "" then return nil end
  local ok, v = pcall(function() return tonumber(rt.i64_to_str(eval(sh, require("parser").arith(s)))) end)
  return (ok and v) or tonumber(s) or 0
end
-- ${a[@]:off:len}: select elements by (0-based, negatives-from-end) offset/length.
local function array_slice(els, off, len)
  local n = #els
  off = off or 0
  if off < 0 then off = n + off; if off < 0 then off = 0 end end
  local last = n
  if len ~= nil then last = (len < 0) and (n + len) or (off + len) end
  local out = {}
  for i = off, last - 1 do if els[i + 1] ~= nil then out[#out + 1] = els[i + 1] end end
  return out
end
local function multi_elems(sh, p) -- returns element list, star?
  if p.pexp then
    local pe, P = p.pexp, require("parser")
    local star = (pe.index == "*")
    if pe.op == "indices" then -- ${!a[@]} -> the keys/indices
      local ix = sh:array_indices(pe.name); local t = {}
      for i = 1, #ix do t[i] = tostring(ix[i]) end
      return t, star
    end
    local els = sh:array_values(pe.name)
    if pe.op == "sub" then -- array slice
      local off = arith_int(sh, pe.arg and expand_word(sh, P.parse_word(pe.arg)) or nil)
      local len = pe.arg2 and arith_int(sh, expand_word(sh, P.parse_word(pe.arg2))) or nil
      els = array_slice(els, off or 0, len)
    elseif (pe.op == ":-" or pe.op == "-") and #els == 0 then
      return { pe.arg and expand_word(sh, P.parse_word(pe.arg)) or "" }, star
    elseif pe.op and pe.op ~= ":-" and pe.op ~= "-" and pe.op ~= ":+" and pe.op ~= "+" then
      local arg = pe.arg and expand_word(sh, P.parse_word(pe.arg)) or ""
      local arg2 = pe.arg2 and expand_word(sh, P.parse_word(pe.arg2)) or nil
      local out = {}
      for i, v in ipairs(els) do out[i] = sh:apply_str_op(pe.op, v, arg, arg2) end
      els = out
    end
    return els, star
  end
  local els = {}; for i = 1, sh.nparams do els[i] = sh.params[i] end
  return els, (p.special == "*")
end

-- Expand a word to a LIST of fields (command args, for-in lists): unquoted
-- expansions split on default-IFS whitespace; quoted text never splits; "$@" /
-- "${a[@]}" yield one field per element.
local function expand_to_fields(sh, w)
  -- Concatenate-then-split model: build the word left to right, splitting the
  -- chars that came from UNQUOTED expansions on $IFS (default: space/tab/newline),
  -- while literal/quoted chars are never delimiters. This is what bash does, and
  -- it handles concatenation ($x-, pre$x) and custom IFS correctly. Fields also
  -- track `unq` for glob eligibility (quoted glob chars stay literal).
  local ifs = sh.vars["IFS"] and sh:get("IFS") or " \t\n"
  local function isws(c) return c == " " or c == "\t" or c == "\n" end
  local function inifs(c) return c ~= "" and ifs:find(c, 1, true) ~= nil end
  local fields, cur, cur_unq = {}, nil, false
  local function brk() if cur ~= nil then fields[#fields + 1] = { s = cur, unq = cur_unq }; cur = nil; cur_unq = false end end
  local function add(s, unq) cur = (cur or "") .. s; if unq then cur_unq = true end end
  local function feed_split(v) -- unquoted expansion text: split on $IFS
    local i, n = 1, #v
    while i <= n do
      local c = v:sub(i, i)
      if inifs(c) then
        if isws(c) then
          if cur ~= nil then brk() end
          i = i + 1
          while i <= n and isws(v:sub(i, i)) do i = i + 1 end
          if i <= n and inifs(v:sub(i, i)) and not isws(v:sub(i, i)) then
            i = i + 1; while i <= n and isws(v:sub(i, i)) do i = i + 1 end
          end
        else                       -- non-whitespace IFS delimiter
          if cur == nil then cur = "" end -- a delimiter always ends a field (empty ok)
          cur_unq = true; brk()
          i = i + 1
          while i <= n and isws(v:sub(i, i)) do i = i + 1 end
        end
      else
        add(c, true); i = i + 1
      end
    end
  end
  for _, p in ipairs(w.parts) do
    if is_multi(p) then
      local els, star = multi_elems(sh, p)
      if p.q then
        if star then add(table.concat(els, " "), false)
        else for k = 1, #els do if k > 1 then brk() end; add(els[k], false) end end -- one field per element
      else
        for k = 1, #els do if k > 1 then brk() end; feed_split(els[k]) end
      end
    else
      local s = expand_part_str(sh, p)
      if p.q or p.lit ~= nil then add(s, not p.q) else feed_split(s) end
    end
  end
  brk()
  -- pathname expansion on fields with unquoted glob metacharacters
  local out = {}
  for _, f in ipairs(fields) do
    if f.unq and (f.s:find("[*?%[]") or f.s:find("[?*+@!]%(")) then
      local m = rt.glob_expand(f.s)
      if m then for _, x in ipairs(m) do out[#out + 1] = x end else out[#out + 1] = f.s end
    else
      out[#out + 1] = f.s
    end
  end
  return out
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
-- Apply redirections, backing up each touched fd (any fd, not just 0/1/2) so it
-- can be restored. Returns (save, ok); ok is false when an open() failed (bash
-- then skips the command and reports failure).
local function apply_redirs(sh, redirs)
  io.flush() -- flush pending stdout BEFORE moving fds, else buffered output from a
             -- prior command would be redirected into (and lost to) the new target
  local P = require("parser")
  local save, ok = {}, true
  local function backup(fd) save[#save + 1] = { fd = fd, saved = C.dup(fd) } end
  -- redirect targets are word-expanded at runtime (e.g. `> $TMP/f`, `>& $myfd`).
  local function tgt(r) return expand_word(sh, P.parse_word(r.target or "")) end
  for _, r in ipairs(redirs) do
    if r.op == "out" then
      backup(r.fd); local f = C.open(tgt(r), 577, 420)
      if f >= 0 then C.dup2(f, r.fd); C.close(f) else ok = false end
    elseif r.op == "app" then
      backup(r.fd); local f = C.open(tgt(r), 1089, 420)
      if f >= 0 then C.dup2(f, r.fd); C.close(f) else ok = false end
    elseif r.op == "in" then
      backup(r.fd); local f = C.open(tgt(r), 0, 0)
      if f >= 0 then C.dup2(f, r.fd); C.close(f) else ok = false end
    elseif r.op == "outboth" then
      backup(1); backup(2); local f = C.open(tgt(r), 577, 420)
      if f >= 0 then C.dup2(f, 1); C.dup2(f, 2); C.close(f) else ok = false end
    elseif r.op == "heredoc" then
      local body = r.expand and expand_word(sh, P.parse_heredoc(r.body or "")) or (r.body or "")
      backup(r.fd or 0); feed_stdin(r.fd or 0, body)
    elseif r.op == "herestring" then
      local body = expand_word(sh, P.parse_word(r.word or "")) .. "\n"
      backup(r.fd or 0); feed_stdin(r.fd or 0, body)
    elseif r.op == "dup" or r.op == "dupin" then
      backup(r.fd)
      local tv = tgt(r)
      if tv == "-" then C.close(r.fd)
      else local m = tonumber(tv); if m then C.dup2(m, r.fd) end end
    end
  end
  return save, ok
end
local function restore_redirs(save)
  for k = #save, 1, -1 do
    local s = save[k]
    if s.saved >= 0 then C.dup2(s.saved, s.fd); C.close(s.saved) else C.close(s.fd) end
  end
end

-- name classification for `type` / `command -v`
local BUILTINS = {
  echo = 1, [":"] = 1, ["true"] = 1, ["false"] = 1, ["["] = 1, test = 1, ["return"] = 1,
  exit = 1, cd = 1, unset = 1, export = 1, declare = 1, typeset = 1, set = 1, shift = 1,
  read = 1, getopts = 1, printf = 1, ["local"] = 1, command = 1, type = 1, pwd = 1,
  eval = 1, source = 1, ["."] = 1, ["break"] = 1, ["continue"] = 1, ["true"] = 1,
  exec = 1, readonly = 1, umask = 1, alias = 1, unalias = 1, shopt = 1, wait = 1, trap = 1,
}
local KEYWORDS = {
  ["if"] = 1, ["then"] = 1, ["else"] = 1, ["elif"] = 1, ["fi"] = 1, ["for"] = 1,
  ["while"] = 1, ["until"] = 1, ["do"] = 1, ["done"] = 1, ["case"] = 1, ["esac"] = 1,
  ["function"] = 1, ["in"] = 1, ["select"] = 1, ["{"] = 1, ["}"] = 1, ["!"] = 1,
}
local function find_in_path(name)
  if name:find("/", 1, true) then return C.access(name, 1) == 0 and name or nil end
  local path = os.getenv("PATH") or "/usr/bin:/bin"
  for dir in path:gmatch("[^:]+") do
    local p = dir .. "/" .. name
    if C.access(p, 1) == 0 then return p end -- X_OK
  end
  return nil
end
local function name_type(sh, name)
  if KEYWORDS[name] then return "keyword" end
  if sh.functions[name] then return "function" end
  if BUILTINS[name] then return "builtin" end
  local p = find_in_path(name)
  if p then return "file", p end
  return nil
end

-- Execute an array literal assignment `name=(...)` / `name+=(...)`. bash evaluates
-- in two phases: expand every RHS against the OLD array state first, then evaluate
-- indices left-to-right against the array as it is being built.
local function do_arrayassign(sh, st)
  local isassoc = sh:is_assoc(st.name)
  local anykeyed = false
  for _, e in ipairs(st.elems) do if e.key ~= nil then anykeyed = true; break end end
  local items = {}
  for _, e in ipairs(st.elems) do
    if e.key ~= nil then -- keyed RHS is a single value (no field splitting)
      items[#items + 1] = { key = e.key, op = e.op, val = expand_word(sh, e.word) }
    else -- bare element: unquoted expansions split into multiple elements
      for _, f in ipairs(expand_to_fields(sh, e.word)) do
        items[#items + 1] = { key = nil, op = "=", val = f }
      end
    end
  end
  if not st.append then -- plain assignment resets the array (keep assoc-ness)
    local b = sh.vars[st.name]
    if not b then sh:array_assign(st.name, {}, false); b = sh.vars[st.name] end
    b.arr = {}; b.s = nil; b.n = nil
    if isassoc then b.order = {} end
  end
  if isassoc then
    if anykeyed then -- keyed elements assigned; bare ones are an error in bash (skip)
      for _, it in ipairs(items) do
        if it.key ~= nil then
          sh:array_set(st.name, array_key(sh, st.name, it.key), it.val, it.op == "+=")
        end
      end
    else -- all-bare assoc: alternating key value pairs
      for k = 1, #items, 2 do
        sh:array_set(st.name, items[k].val, items[k + 1] and items[k + 1].val or "", false)
      end
    end
  else
    local auto = 0
    if st.append then
      local mx, b = -1, sh.vars[st.name]
      if b and b.arr then for kk in pairs(b.arr) do if kk > mx then mx = kk end end end
      auto = mx + 1
    end
    for _, it in ipairs(items) do
      if it.key ~= nil then
        local idx = array_key(sh, st.name, it.key)
        sh:array_set(st.name, idx, it.val, it.op == "+=")
        auto = idx + 1
      else
        sh:array_set(st.name, auto, it.val, false)
        auto = auto + 1
      end
    end
  end
end
M.do_arrayassign = do_arrayassign

-- Quote a value the way `declare -p` does: double-quoted with \ " $ ` escaped.
local function decl_quote(s)
  s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("%$", "\\$"):gsub("`", "\\`")
  return '"' .. s .. '"'
end
-- Format one variable as a `declare -p` line, or nil if it is unset.
local function fmt_decl(sh, name)
  local b = sh.vars[name]
  if b == nil then return nil end
  if b.ref then return "declare -n " .. name .. "=" .. decl_quote(b.s or "") end
  if b.assoc then
    local parts = {}
    for _, k in ipairs(sh:array_indices(name)) do
      parts[#parts + 1] = "[" .. tostring(k) .. "]=" .. decl_quote(sh:array_get(name, k))
    end
    if #parts == 0 then return "declare -A " .. name .. "=()" end
    return "declare -A " .. name .. "=(" .. table.concat(parts, " ") .. " )"
  elseif b.arr then
    local parts = {}
    for _, k in ipairs(sh:array_indices(name)) do
      parts[#parts + 1] = "[" .. tostring(k) .. "]=" .. decl_quote(sh:array_get(name, k))
    end
    return "declare -a " .. name .. "=(" .. table.concat(parts, " ") .. ")"
  else
    local attr = os.getenv(name) ~= nil and "-x" or "--"
    return "declare " .. attr .. " " .. name .. "=" .. decl_quote(sh:get(name))
  end
end

-- ---- umask helpers ----
local function perms_str(bits)
  return (bit.band(bits, 4) ~= 0 and "r" or "") .. (bit.band(bits, 2) ~= 0 and "w" or "")
    .. (bit.band(bits, 1) ~= 0 and "x" or "")
end
local function umask_symbolic(cur)
  local allowed = bit.band(bit.bnot(cur), 511)
  return "u=" .. perms_str(bit.band(bit.rshift(allowed, 6), 7))
    .. ",g=" .. perms_str(bit.band(bit.rshift(allowed, 3), 7))
    .. ",o=" .. perms_str(bit.band(allowed, 7))
end
-- Parse a umask MODE (octal like 0022, or symbolic like u=rwx,go=rx) against the
-- current mask; returns the new mask, or nil on a syntax error.
local function parse_umask(s, cur)
  if s == "" then return nil end
  if s:match("^[0-7]+$") then return tonumber(s, 8) % 512 end
  local allowed = bit.band(bit.bnot(cur), 511) -- symbolic works on allowed perms
  for clause in s:gmatch("[^,]+") do
    local who, op, perms = clause:match("^([ugoa]*)([=+-])([rwx]*)$")
    if not who then return nil end
    local pv = 0
    for ch in perms:gmatch(".") do
      pv = bit.bor(pv, ch == "r" and 4 or ch == "w" and 2 or 1)
    end
    if who == "" then who = "a" end
    local whos = {}
    for c in who:gmatch(".") do
      if c == "a" then whos = { "u", "g", "o" }; break else whos[#whos + 1] = c end
    end
    for _, wc in ipairs(whos) do
      local sh4 = wc == "u" and 6 or wc == "g" and 3 or 0
      local cbits = bit.band(bit.rshift(allowed, sh4), 7)
      if op == "=" then cbits = pv
      elseif op == "+" then cbits = bit.bor(cbits, pv)
      else cbits = bit.band(cbits, bit.band(bit.bnot(pv), 7)) end
      allowed = bit.bor(bit.band(allowed, bit.band(bit.bnot(bit.lshift(7, sh4)), 511)), bit.lshift(cbits, sh4))
    end
  end
  return bit.band(bit.bnot(allowed), 511)
end

-- Dispatch one already-expanded simple command (no redirs — the caller sets those
-- up). Builtins first, then user functions, then external.
local function exec_simple(sh, args, hook)
  local cmd = args[1]
  if cmd == nil then sh.status = 0
  elseif cmd == "echo" then
    -- echo [-neE] ARGS: -n suppresses the newline, -e interprets backslash escapes.
    local j, nonl, esc = 2, false, false
    while args[j] and args[j]:match("^%-[neE]+$") do
      for ch in args[j]:sub(2):gmatch(".") do
        if ch == "n" then nonl = true elseif ch == "e" then esc = true elseif ch == "E" then esc = false end
      end
      j = j + 1
    end
    local buf = {}
    for k = j, #args do buf[#buf + 1] = args[k] end
    local s = table.concat(buf, " ")
    if esc then s = rt.ansi_unescape(s) end
    sh.out(s); if not nonl then sh.out("\n") end
    sh.status = 0
  elseif cmd == ":" or cmd == "true" then sh.status = 0
  elseif cmd == "false" then sh.status = 1
  elseif cmd == "wait" then
    -- wait [-n] [pid…]: reap background jobs. With pids, return the last one's
    -- status; with none, wait for all (status 0); an invalid arg is status 1.
    local stbuf = ffi.new("int[1]")
    local function reap(pid)
      if C.waitpid(pid, stbuf, 0) < 0 then return 127 end
      local s = stbuf[0]; local sig = bit.band(s, 0x7f)
      return (sig ~= 0 and sig ~= 0x7f) and (128 + sig) or bit.rshift(bit.band(s, 0xff00), 8)
    end
    local pids, bad = {}, false
    for k = 2, #args do
      local a = args[k]
      if a == "-n" then -- wait for the next; approximate as the first tracked pid
      elseif a:match("^%d+$") then pids[#pids + 1] = tonumber(a)
      else bad = true end
    end
    if bad then sh.status = 1
    elseif #pids > 0 then
      local last = 0
      for _, p in ipairs(pids) do last = reap(p) end
      sh.status = last
    else
      if sh.bg_pids then for _, p in ipairs(sh.bg_pids) do pcall(reap, p) end; sh.bg_pids = {} end
      sh.status = 0
    end
  elseif cmd == "trap" then
    -- trap [-p] [ACTION] SIG…  (subset: registers/prints; only EXIT actually fires)
    local j = 2
    if args[j] == "-p" or args[j] == "-l" then j = j + 1 end
    if args[j] == "--" then j = j + 1 end
    if j > #args then -- print all registered traps, in signal order
      local list = {}
      for canon, h in pairs(sh.traps) do list[#list + 1] = canon end
      table.sort(list, function(a, b) return sig_order(a) < sig_order(b) end)
      for _, canon in ipairs(list) do
        sh:echo("trap -- '" .. sh.traps[canon] .. "' " .. canon)
      end
      sh.status = 0
    else
      -- first token is the action if it's not itself a signal, else action="-" (reset)
      local action, sigstart
      if canon_sig(args[j]) and #args == j then action, sigstart = "-", j -- `trap SIG` resets
      else action, sigstart = args[j], j + 1 end
      local ok = true
      for k = sigstart, #args do
        local canon = canon_sig(args[k])
        if not canon then io.stderr:write("curse: trap: " .. args[k] .. ": invalid signal specification\n"); ok = false
        elseif action == "-" then sh.traps[canon] = nil
        else sh.traps[canon] = action end
      end
      sh.status = ok and 0 or 1
    end
  elseif cmd == "alias" then
    -- alias [name[=value] …]: define or print aliases.
    local j, ok, printed = 2, true, false
    if args[j] == "--" then j = j + 1 end
    if j > #args then -- print all, sorted
      local ns = {}; for k in pairs(sh.aliases) do ns[#ns + 1] = k end; table.sort(ns)
      for _, k in ipairs(ns) do sh:echo("alias " .. k .. "='" .. sh.aliases[k] .. "'") end
      sh.status = 0
    else
      for k = j, #args do
        local nm, val = args[k]:match("^([^=]+)=(.*)$")
        if nm then sh.aliases[nm] = val
        elseif sh.aliases[args[k]] then sh:echo("alias " .. args[k] .. "='" .. sh.aliases[args[k]] .. "'")
        else io.stderr:write("curse: alias: " .. args[k] .. ": not found\n"); ok = false end
      end
      sh.status = ok and 0 or 1
    end
  elseif cmd == "unalias" then
    local ok = true
    if args[2] == "-a" then sh.aliases = {}
    else
      for k = 2, #args do
        if args[k] ~= "--" then
          if sh.aliases[args[k]] then sh.aliases[args[k]] = nil
          else io.stderr:write("curse: unalias: " .. args[k] .. ": not found\n"); ok = false end
        end
      end
    end
    sh.status = ok and 0 or 1
  elseif cmd == "shopt" then
    -- shopt [-s|-u|-q|-p|-o] [names]: set/unset/query shell options (subset).
    local set_, unset_, quiet, oflag = false, false, false, false
    local names = {}
    for k = 2, #args do
      local a = args[k]
      if a == "-s" then set_ = true elseif a == "-u" then unset_ = true
      elseif a == "-q" then quiet = true elseif a == "-p" then -- print form
      elseif a == "-o" then oflag = true
      elseif a:match("^-[suqpo]+$") then
        if a:find("s") then set_ = true end; if a:find("u") then unset_ = true end
        if a:find("q") then quiet = true end; if a:find("o") then oflag = true end
      else names[#names + 1] = a end
    end
    if oflag then -- shopt -o: the `set -o` options
      if set_ or unset_ then
        for _, nm in ipairs(names) do
          if nm == "errexit" then sh.opt_e = set_ elseif nm == "nounset" then sh.opt_u = set_
          elseif nm == "pipefail" then sh.opt_pipefail = set_ end
        end
        sh.status = 0
      else
        for _, nm in ipairs(names) do
          local on = (nm == "errexit" and sh.opt_e) or (nm == "nounset" and sh.opt_u) or (nm == "pipefail" and sh.opt_pipefail)
          if not quiet then sh:echo("set " .. (on and "-o " or "+o ") .. nm) end
        end
        sh.status = 0
      end
    elseif set_ or unset_ then
      for _, nm in ipairs(names) do sh.shopt[nm] = set_ end
      sh.status = 0
    else -- query / print
      local allok = true
      for _, nm in ipairs(names) do
        local on = sh.shopt[nm] and true or false
        if not quiet then sh:echo("shopt " .. (on and "-s " or "-u ") .. nm) end
        if not on then allok = false end
      end
      sh.status = allok and 0 or 1
    end
  elseif cmd == "[" or cmd == "test" then do_test(sh, args)
  elseif cmd == "return" then
    error({ __curse_return = args[2] and tonumber(args[2]) or sh.status })
  elseif cmd == "exit" then
    error({ __curse_exit = args[2] and tonumber(args[2]) or sh.status })
  elseif cmd == "cd" then
    local dir = args[2] or os.getenv("HOME") or ""
    sh.status = (C.chdir(dir) == 0) and 0 or 1
  elseif cmd == "unset" then
    for j = 2, #args do
      local a = args[j]
      if a:sub(1, 1) == "-" and #a > 1 then -- -v/-f flags: ignore
      else
        local nm, sub = a:match("^([%a_][%w_]*)%[(.+)%]$")
        if nm then sh:array_unset(nm, array_key(sh, nm, sub))
        else sh.vars[a] = nil end
      end
    end
    sh.status = 0
  elseif cmd == "export" or cmd == "declare" or cmd == "typeset" then
    -- export/declare [-Apx] NAME[=val]…: set the var; export/-x also pushes it to
    -- the process env so posix_spawn children inherit it. -A marks associative,
    -- -p prints declarations.
    local doexport, assoc, printmode, nref, plusn = (cmd == "export"), false, false, false, false
    local funcnames, funcbody = false, false
    local rest = {}
    for j = 2, #args do
      local a = args[j]
      if a == "--" then -- end of flags
      elseif a:sub(1, 1) == "-" and #a > 1 then
        if a:find("A") then assoc = true end
        if a:find("p") then printmode = true end
        if a:find("x") then doexport = true end
        if a:find("n") then nref = true end
        if a:find("F") then funcnames = true end
        if a:find("f") then funcbody = true end
      elseif a:sub(1, 1) == "+" and #a > 1 then
        if a:find("n") then plusn = true end
      else rest[#rest + 1] = a end
    end
    if funcnames or funcbody then
      -- declare -F [name…] lists `declare -f NAME`; -f prints bodies (not
      -- reconstructed here) — either way the exit status signals existence.
      local names, allok = rest, true
      if #names == 0 then
        names = {}; for k in pairs(sh.functions) do names[#names + 1] = k end; table.sort(names)
      end
      for _, nm in ipairs(names) do
        if sh.functions[nm] then if funcnames then sh:echo("declare -f " .. nm) end
        else allok = false end
      end
      sh.status = allok and 0 or 1
    elseif printmode then
      local allok = true
      if #rest == 0 then -- best-effort: all shell vars, sorted
        local names = {}; for nm in pairs(sh.vars) do names[#names + 1] = nm end
        table.sort(names)
        for _, nm in ipairs(names) do local d = fmt_decl(sh, nm); if d then sh:echo(d) end end
      else
        for _, nm in ipairs(rest) do
          local d = fmt_decl(sh, nm)
          if d then sh:echo(d)
          else allok = false; io.stderr:write("curse: " .. cmd .. ": " .. nm .. ": not found\n") end
        end
      end
      sh.status = allok and 0 or 1
    else
      for _, a in ipairs(rest) do
        local nm, val = a:match("^([%a_][%w_]*)=(.*)$")
        if nm then
          if nref then sh:make_nameref(nm, val)
          else
            if assoc then sh:declare_assoc(nm) end
            sh:set_str(nm, val); if doexport then C.setenv(nm, val, 1) end
          end
        elseif a:match("^[%a_][%w_]*$") then
          if plusn then sh:unref(a)
          elseif nref then sh:make_nameref(a)
          elseif assoc then sh:declare_assoc(a)
          elseif doexport then C.setenv(a, sh:get(a), 1) end
        end
      end
      sh.status = 0
    end
  elseif cmd == "set" then
    -- set [-e|+e|-o NAME|+o NAME|…] [--] [ARGS…]: options then positional params
    local j, dd = 2, false
    while j <= #args do
      local a = args[j]
      if a == "--" then dd = true; j = j + 1; break
      elseif a == "-o" or a == "+o" then
        local o, on = args[j + 1], (a == "-o")
        if o == "errexit" then sh.opt_e = on
        elseif o == "nounset" then sh.opt_u = on
        elseif o == "pipefail" then sh.opt_pipefail = on end
        j = j + 2
      elseif a:match("^[-+][a-zA-Z]+$") then -- short flag bundle: -eu, +u, …
        local on = a:sub(1, 1) == "-"
        for f in a:sub(2):gmatch(".") do
          if f == "e" then sh.opt_e = on elseif f == "u" then sh.opt_u = on end
        end
        j = j + 1
      else break end
    end
    if dd or j <= #args then
      local np, n = {}, 0
      for k = j, #args do n = n + 1; np[n] = args[k] end
      sh.params = np; sh.nparams = n
    end
    sh.status = 0
  elseif cmd == "type" then
    -- type [-t] NAME…  ( -t prints the type word; plain prints a sentence )
    local tflag = args[2] == "-t"
    local j0 = tflag and 3 or 2
    local allok = true
    for j = j0, #args do
      local k, p = name_type(sh, args[j])
      if not k then allok = false
        if not tflag then io.stderr:write("curse: type: " .. args[j] .. ": not found\n") end
      elseif tflag then sh:echo(k)
      elseif k == "file" then sh:echo(args[j] .. " is " .. p)
      elseif k == "function" then sh:echo(args[j] .. " is a function")
      elseif k == "keyword" then sh:echo(args[j] .. " is a shell keyword")
      else sh:echo(args[j] .. " is a shell builtin") end
    end
    sh.status = allok and 0 or 1
  elseif cmd == "command" and (args[2] == "-v" or args[2] == "-V") then
    local verbose = args[2] == "-V"
    local allok = true
    for j = 3, #args do
      local k, p = name_type(sh, args[j])
      if not k then allok = false
      elseif verbose then
        if k == "file" then sh:echo(args[j] .. " is " .. p)
        elseif k == "function" then sh:echo(args[j] .. " is a function")
        elseif k == "keyword" then sh:echo(args[j] .. " is a shell keyword")
        else sh:echo(args[j] .. " is a shell builtin") end
      else sh:echo(k == "file" and p or args[j]) end
    end
    sh.status = allok and 0 or 1
  elseif cmd == "command" then
    exec_simple(sh, { unpack(args, 2) }, hook) -- run rest, bypassing functions (approx)
  elseif cmd == "pwd" then
    sh:echo(sh:special_get("PWD")); sh.status = 0
  elseif cmd == "umask" then
    -- umask [-S] [MODE]: print (octal or -S symbolic) or set the file-creation mask.
    local sflag, badflag, pos = false, false, {}
    for j = 2, #args do
      local a = args[j]
      if a == "-S" then sflag = true
      elseif a == "-p" then -- print in reusable form: accept, treat like plain
      elseif a:sub(1, 1) == "-" and #a > 1 then badflag = true
      else pos[#pos + 1] = a end
    end
    local cur = tonumber(C.umask(0)) % 512; C.umask(cur)
    if badflag then io.stderr:write("curse: umask: invalid option\n"); sh.status = 1
    elseif #pos > 1 then io.stderr:write("curse: umask: too many arguments\n"); sh.status = 1
    elseif #pos == 0 then
      sh:echo(sflag and umask_symbolic(cur) or string.format("%04o", cur)); sh.status = 0
    else
      local m = parse_umask(pos[1], cur)
      if m == nil then io.stderr:write("curse: umask: `" .. pos[1] .. "': invalid symbolic mode\n"); sh.status = 1
      else C.umask(m); sh.status = 0 end
    end
  elseif cmd == "getopts" then
    -- getopts OPTSTRING NAME [args…]: parse one option per call using OPTIND (+ an
    -- internal char cursor for bundled opts); sets NAME, OPTARG; status 1 when done.
    local spec, vname = args[2] or "", args[3] or "?"
    local silent = spec:sub(1, 1) == ":"
    local src_get, src_n
    if #args >= 4 then src_n = #args - 3; src_get = function(k) return args[k + 3] end
    else src_n = sh.nparams; src_get = function(k) return sh.params[k] end end
    local optind = math.max(1, math.floor(tonumber(sh:get("OPTIND")) or 1))
    local cur = sh.getopts_cur or 1
    local res
    while not res do
      local word = optind <= src_n and src_get(optind) or nil
      if not word or word == "-" or word:sub(1, 1) ~= "-" then res = { done = true }
      elseif word == "--" then optind = optind + 1; res = { done = true }
      else
        local oc = word:sub(1 + cur, 1 + cur)
        if oc == "" then optind = optind + 1; cur = 1
        else
          local pos = spec:find(oc, 1, true)
          if not pos or oc == ":" then
            cur = cur + 1; if 1 + cur > #word then optind = optind + 1; cur = 1 end
            res = { opt = "?", arg = silent and oc or nil, err = not silent and ("illegal option -- " .. oc) }
          elseif spec:sub(pos + 1, pos + 1) == ":" then -- takes an argument
            local rest = word:sub(2 + cur)
            if rest ~= "" then sh:set_str("OPTARG", rest); optind = optind + 1; cur = 1; res = { opt = oc }
            else
              local a = (optind + 1) <= src_n and src_get(optind + 1) or nil
              if a then sh:set_str("OPTARG", a); optind = optind + 2; cur = 1; res = { opt = oc }
              else optind = optind + 1; cur = 1
                res = silent and { opt = ":", arg = oc } or { opt = "?", err = "option requires an argument -- " .. oc }
              end
            end
          else -- flag, no argument
            cur = cur + 1; if 1 + cur > #word then optind = optind + 1; cur = 1 end
            res = { opt = oc }
          end
        end
      end
    end
    sh.getopts_cur = cur
    sh:set_str("OPTIND", tostring(optind))
    if res.done then sh:set_str(vname, "?"); sh.getopts_cur = 1; sh.status = 1
    else
      sh:set_str(vname, res.opt)
      if res.arg ~= nil then sh:set_str("OPTARG", res.arg) elseif res.err then sh.vars["OPTARG"] = nil end
      if res.err then io.stderr:write("curse: " .. res.err .. "\n") end
      sh.status = 0
    end
  elseif cmd == "printf" and args[2] == "-v" then
    -- printf -v VAR FMT ARGS: format via external printf, capture, assign to VAR
    local var = args[3]
    local buf, saved = {}, sh.out
    sh.out = function(s) buf[#buf + 1] = s end
    local pa = { "printf" }; for k = 4, #args do pa[#pa + 1] = args[k] end
    sh:exec(unpack(pa))
    sh.out = saved
    sh:set_str(var, table.concat(buf))
    sh.status = 0
  elseif cmd == "read" then
    -- read [-r] [-a arr] [-p prompt] VAR...  (line from stdin, split on IFS)
    local raw, arr, j, nchars, ndelim = false, nil, 2, nil, false
    while j <= #args do
      local a = args[j]
      if a == "-r" then raw = true; j = j + 1
      elseif a == "-a" then arr = args[j + 1]; j = j + 2
      elseif a == "-n" then nchars = tonumber(args[j + 1]); j = j + 2 -- N chars or newline
      elseif a == "-N" then nchars = tonumber(args[j + 1]); ndelim = true; j = j + 2 -- exactly N
      elseif a == "-p" or a == "-d" or a == "-t" or a == "-u" then j = j + 2 -- take an arg, skip
      elseif a:sub(1, 1) == "-" and #a > 1 then j = j + 1 -- ignore -s/…
      else break end
    end
    local vars = {}
    for k = j, #args do vars[#vars + 1] = args[k] end
    local line, had_nl = nil, true
    if nchars then
      line = io.read(nchars)
      if line and not ndelim then local nl = line:find("\n", 1, true); if nl then line = line:sub(1, nl - 1) end end
    else
      line = io.read("*L") -- keep the newline so we can tell a full line from EOF
      if line then
        if line:sub(-1) == "\n" then line = line:sub(1, -2) else had_nl = false end
        -- line continuation (non -r): a trailing odd number of backslashes means
        -- the last was `\<newline>` — drop it and splice the next physical line.
        while not raw and had_nl and (#(line:match("(\\*)$") or "") % 2 == 1) do
          line = line:sub(1, -2)
          local nxt = io.read("*L"); if not nxt then break end
          if nxt:sub(-1) == "\n" then nxt = nxt:sub(1, -2) else had_nl = false end
          line = line .. nxt
        end
      end
    end
    if line == nil then
      sh.status = 1 -- EOF: nothing read
    else
      if not raw then line = line:gsub("\\(.)", "%1") end
      local ifs = sh.vars["IFS"] and sh:get("IFS") or " \t\n"
      -- IFS whitespace chars (trimmed from a single/last field, unlike other IFS chars)
      local ws = ifs:gsub("[^ \t\n]", "")
      local function trim(s)
        if ws == "" then return s end
        local pat = "[" .. ws:gsub("(%W)", "%%%1") .. "]"
        return (s:gsub("^" .. pat .. "+", ""):gsub(pat .. "+$", ""))
      end
      if arr then
        sh:array_assign(arr, rt.ifs_split(ifs, line), false)
      elseif #vars == 0 then
        sh:set_str("REPLY", ndelim and line or trim(line))
      elseif #vars == 1 then
        sh:set_str(vars[1], trim(line)) -- single var: strip only leading/trailing IFS ws
      else
        local fields = rt.ifs_split(ifs, line)
        for k = 1, #vars - 1 do sh:set_str(vars[k], fields[k] or "") end
        local rest = {}
        for m = #vars, #fields do rest[#rest + 1] = fields[m] end
        sh:set_str(vars[#vars], table.concat(rest, " "))
      end
      sh.status = had_nl and 0 or 1
    end
  elseif cmd == "shift" then
    local nn = tonumber(args[2]) or 1
    if nn > sh.nparams then nn = sh.nparams end
    for k = 1, sh.nparams - nn do sh.params[k] = sh.params[k + nn] end
    for k = sh.nparams - nn + 1, sh.nparams do sh.params[k] = nil end
    sh.nparams = sh.nparams - nn
    sh.status = 0
  elseif cmd == "local" then
    -- local [-naA] [+n] NAME[=val]…: shadow the var in this scope, honoring
    -- nameref (-n), indexed (-a) and associative (-A) attributes.
    local nref, assoc, plusn, rest = false, false, false, {}
    for j = 2, #args do
      local a = args[j]
      if a == "--" then
      elseif a:sub(1, 1) == "-" and #a > 1 then
        if a:find("n") then nref = true end
        if a:find("A") then assoc = true end
      elseif a:sub(1, 1) == "+" and #a > 1 then
        if a:find("n") then plusn = true end
      else rest[#rest + 1] = a end
    end
    if not (nref or assoc or plusn) then
      for _, a in ipairs(rest) do sh:localAssign(a) end
    else
      for _, a in ipairs(rest) do
        local nm, val = a:match("^([%a_][%w_]*)=(.*)$")
        local vname = nm or a
        sh:localVar(vname)
        if nm then
          if nref then sh:make_nameref(nm, val)
          else if assoc then sh:declare_assoc(nm) end; sh:set_str(nm, val) end
        elseif plusn then sh:unref(vname)
        elseif nref then sh:make_nameref(vname)
        elseif assoc then sh:declare_assoc(vname) end
      end
    end
    sh.status = 0
  elseif sh.functions[cmd] then
    local fn = sh.functions[cmd]
    sh.calldepth = sh.calldepth + 1 -- OSR gate: no handoff inside a call
    sh:pushCall(unpack(args, 2))
    local ok, err
    if type(fn) == "function" then ok, err = pcall(fn, sh) -- a COMPILED function closure
    else ok, err = pcall(exec_list, sh, fn, hook, false) end -- an interp AST body
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
  if k == "unary" and node.op == "-v" then -- variable/element is set
    local nm = expand_word(sh, node.word)
    local base, sub = nm:match("^([%a_][%w_]*)%[(.+)%]$")
    if base then return sh:is_elem_set(base, array_key(sh, base, sub)) end
    return sh.vars[sh:deref(nm)] ~= nil or sh:special_get(nm) ~= ""
  end
  if k == "unary" then return unary(node.op, expand_word(sh, node.word)) end
  if k == "binary" then
    local l, r, op = expand_word(sh, node.l), expand_word(sh, node.r), node.op
    if op == "==" or op == "=" then
      if node.rq then return l == r else return rt.glob_match(l, r) end
    elseif op == "!=" then
      if node.rq then return l ~= r else return not rt.glob_match(l, r) end
    elseif op == "=~" then
      return rt.regex_match(l, r) -- real POSIX ERE
    else return binary(l, op, r) end -- < > -eq -ne -lt …
  end
  return false
end

local function exec_stmt(sh, st, hook)
  local t = st.t
  if st.line then sh.cur_line = st.line end -- $LINENO
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
    do_arrayassign(sh, st)
    sh.status = 0
  elseif t == "funcdef" then
    sh.functions[st.name] = st.body
    sh.status = 0
  elseif t == "assignlist" then
    for _, a in ipairs(st.list) do exec_stmt(sh, a, hook) end
    sh.status = 0
  elseif t == "simple" then
    -- alias expansion (bash: only with `shopt -s expand_aliases`): if the command
    -- word is a defined alias, splice its parsed words in and re-dispatch.
    if not st.__aliased and sh.shopt.expand_aliases and st.words[1] then
      local cw = st.words[1]
      local nm = (#cw.parts == 1 and cw.parts[1].lit ~= nil and not cw.parts[1].q) and cw.parts[1].lit or nil
      local av = nm and sh.aliases[nm]
      if av then
        local P = require("parser")
        local parsed = P.parse(av)
        if parsed.stmts and #parsed.stmts == 1 and parsed.stmts[1].t == "simple" then
          local nw = {}
          for _, w in ipairs(parsed.stmts[1].words) do nw[#nw + 1] = w end
          for k = 2, #st.words do nw[#nw + 1] = st.words[k] end
          return exec_stmt(sh, { t = "simple", words = nw, redirs = st.redirs, assigns = st.assigns,
            arrayargs = parsed.stmts[1].arrayargs, __aliased = true }, hook)
        elseif parsed.stmts then
          for _, s in ipairs(parsed.stmts) do exec_stmt(sh, s, hook) end
          return
        end
      end
    end
    local args = {}
    for _, w in ipairs(st.words) do
      local fs = expand_to_fields(sh, w)
      for k = 1, #fs do args[#args + 1] = fs[k] end
    end
    if st.arrayargs then -- `declare -A a=(...)` / `local -a b=(...)` array literals
      local assoc = false
      for _, a in ipairs(args) do
        if a == "--" then break end
        if a:sub(1, 1) == "-" and a:find("A") then assoc = true end
      end
      for _, aa in ipairs(st.arrayargs) do
        if assoc then sh:declare_assoc(aa.name) end
        do_arrayassign(sh, aa)
      end
    end
    -- `exec [redirs] [cmd…]`: redirections are permanent (not restored). With no
    -- command it just rewires the shell's own fds (e.g. `exec 3>file`); with a
    -- command it replaces the shell process with that command.
    if args[1] == "exec" then
      io.flush()
      local ok = true
      if st.redirs then _, ok = apply_redirs(sh, st.redirs) end
      if #args > 1 then
        exec_simple(sh, { unpack(args, 2) }, hook)
        io.flush(); os.exit(sh.status or 0)
      else
        sh.status = ok and 0 or 1
      end
      return
    end
    local function run_cmd()
      if st.redirs then
        local save, ok = apply_redirs(sh, st.redirs)
        if not ok then
          sh.status = 1; restore_redirs(save) -- open failed: skip the command
        else
          local savedout = sh.out; sh.out = io.write
          local pok, err = pcall(exec_simple, sh, args, hook)
          io.flush(); sh.out = savedout; restore_redirs(save)
          if not pok then error(err) end
        end
      else
        exec_simple(sh, args, hook)
      end
    end
    if st.assigns then
      -- prefix assignments: apply as a temporary, EXPORTED env for this command
      -- only, then restore (both the shell var and the process env).
      local saved = {}
      for _, a in ipairs(st.assigns) do
        local b = sh.vars[a.name] -- COPY the box: exec_stmt mutates it in place
        saved[#saved + 1] = { name = a.name, env = os.getenv(a.name),
          box = b and { s = b.s, n = b.n, arr = b.arr, assoc = b.assoc, order = b.order } or false }
        exec_stmt(sh, a, hook); C.setenv(a.name, sh:get(a.name), 1)
      end
      local ok, err = pcall(run_cmd)
      for k = #saved, 1, -1 do
        local s = saved[k]; sh.vars[s.name] = s.box or nil
        if s.env then C.setenv(s.name, s.env, 1) else C.unsetenv(s.name) end
      end
      if not ok then error(err) end
    else
      run_cmd()
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
      sh.noerr = sh.noerr + 1; exec_list(sh, st.cond, hook, false); sh.noerr = sh.noerr - 1
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
    io.flush() -- flush parent stdio so the fork doesn't duplicate buffered output
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
  elseif t == "background" then
    -- cmd & : fork, run in the child; parent records $! and continues (status 0).
    io.flush()
    local pid = C.fork()
    if pid == 0 then
      local ok, err = pcall(function() sh.out = io.write; exec_stmt(sh, st.cmd, hook) end)
      if not ok and type(err) == "table" then sh.status = err.__curse_exit or err.__curse_return or sh.status end
      io.flush(); C._exit(sh.status or 0)
    end
    sh.last_bg_pid = tostring(pid)
    sh.bg_pids = sh.bg_pids or {}
    sh.bg_pids[#sh.bg_pids + 1] = pid
    sh.status = 0
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
      io.flush() -- flush parent stdio so forked stages don't duplicate buffered output
      local pids, prev_read = {}, -1
      for k = 1, nst do
        local rd, wr = -1, -1
        if k < nst then local p = ffi.new("int[2]"); C.pipe(p); rd, wr = p[0], p[1] end
        local pid = C.fork()
        if pid == 0 then
          local ok, err = pcall(function()
            if prev_read >= 0 then C.dup2(prev_read, 0); C.close(prev_read) end
            if wr >= 0 then C.dup2(wr, 1); C.close(wr) end
            if rd >= 0 then C.close(rd) end
            sh.out = io.write -- this stage writes to its fd 1 (the pipe / terminal)
            exec_stmt(sh, cmds[k], hook)
          end)
          if not ok and type(err) == "table" then sh.status = err.__curse_exit or err.__curse_return or sh.status end
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
      local last, pipe, pstat = 0, 0, {}
      for k = 1, nst do
        C.waitpid(pids[k], stbuf, 0)
        local s = stbuf[0]; local sig = bit.band(s, 0x7f)
        local est = (sig ~= 0 and sig ~= 0x7f) and (128 + sig) or bit.rshift(bit.band(s, 0xff00), 8)
        pstat[k] = tostring(est)
        if k == nst then last = est end
        if est ~= 0 then pipe = est end -- rightmost non-zero (for pipefail)
      end
      sh:array_assign("PIPESTATUS", pstat, false) -- ${PIPESTATUS[@]}
      sh.status = sh.opt_pipefail and pipe or last
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
      else
        sh.noerr = sh.noerr + 1; exec_list(sh, cl.cond, hook, false); sh.noerr = sh.noerr - 1
        take = (sh.status == 0)
      end
      if take then exec_list(sh, cl.body, hook, false); break end
    end
  else
    error("interp: bad stmt " .. tostring(t))
  end
end

M.exec_stmt = exec_stmt -- exposed so the compiled CFG can delegate cold statements

exec_list = function(sh, stmts, hook, toplevel)
  for k = 1, #stmts do
    local st = stmts[k]
    if toplevel then hook("stmt", k) end
    exec_stmt(sh, st, hook)
    -- errexit: a failing simple command / pipeline (not in a condition) exits. We
    -- restrict to those two types to avoid the &&/|| short-circuit false-positives.
    if sh.opt_e and sh.noerr == 0 and sh.status ~= 0 and (st.t == "simple" or st.t == "pipeline") then
      error({ __curse_exit = sh.status })
    end
  end
end
M.exec_list = exec_list

-- Run a trap handler string; returns true if it called exit (which wins).
local function run_trap(sh, code)
  local exited = false
  local ok, err = pcall(function()
    for _, st in ipairs(require("parser").parse(code).stmts) do exec_stmt(sh, st, function() end) end
  end)
  if not ok and type(err) == "table" and err.__curse_exit then sh.status = err.__curse_exit; exited = true end
  return exited
end

local function finish(sh, ok, err)
  if not ok then
    if type(err) == "table" and err.__curse_exit then sh.status = err.__curse_exit
    elseif type(err) == "table" and err.__curse_return then sh.status = err.__curse_return
    else error(err) end
  end
  -- EXIT trap: runs once with $? = the final status; its own status is ignored
  -- unless it calls exit (bash semantics).
  local h = sh.traps and sh.traps.EXIT
  if h and h ~= "" and not sh.in_exit_trap then
    sh.in_exit_trap = true
    local saved = sh.status
    if not run_trap(sh, h) then sh.status = saved end
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
      if sh.opt_e and sh.noerr == 0 and sh.status ~= 0 and (st.t == "simple" or st.t == "pipeline") then
        error({ __curse_exit = sh.status })
      end
    end
  end))
end

return M
