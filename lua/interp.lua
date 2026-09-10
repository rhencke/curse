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

-- `set -o NAME` / short-flag maps for the `set` builtin (and shopt -o).
-- Ordered list mirrors bash's `set -o` output order.
local SETOPTS = {
  { "allexport", "opt_a" }, { "braceexpand", "opt_B" }, { "emacs", "opt_emacs" },
  { "errexit", "opt_e" }, { "errtrace", "opt_errtrace" }, { "functrace", "opt_functrace" },
  { "hashall", "opt_h" }, { "histexpand", "opt_H" }, { "history", "opt_history" },
  { "ignoreeof", "opt_ignoreeof" }, { "interactive-comments", "opt_icomments" },
  { "keyword", "opt_k" }, { "monitor", "opt_m" }, { "noclobber", "opt_C" },
  { "noexec", "opt_n" }, { "noglob", "opt_f" }, { "nolog", "opt_nolog" },
  { "notify", "opt_b" }, { "nounset", "opt_u" }, { "onecmd", "opt_t" },
  { "physical", "opt_P" }, { "pipefail", "opt_pipefail" }, { "posix", "opt_posix" },
  { "privileged", "opt_p" }, { "verbose", "opt_v" }, { "vi", "opt_vi" },
  { "xtrace", "opt_x" },
}
local SETOPT = {} -- name -> field
for _, o in ipairs(SETOPTS) do SETOPT[o[1]] = o[2] end
local SETFLAG = { a = "opt_a", B = "opt_B", e = "opt_e", h = "opt_h", H = "opt_H",
  k = "opt_k", m = "opt_m", C = "opt_C", n = "opt_n", f = "opt_f", b = "opt_b",
  u = "opt_u", t = "opt_t", P = "opt_P", v = "opt_v", x = "opt_x", p = "opt_p" }
-- options that default ON (interactive-comments and braceexpand/hashall/histexpand/
-- history are on; emacs is on for the display default). nil field state == off.
local SETDEFAULT = { opt_B = true, opt_h = true, opt_H = true, opt_history = true,
  opt_icomments = true }
local function opt_on(sh, field)
  local v = sh[field]
  if v ~= nil then return v end
  -- emacs line-editing defaults on only for interactive shells.
  if field == "opt_emacs" then return sh.opt_i and true or false end
  return SETDEFAULT[field] or false
end
local function set_opt(sh, field, on)
  sh[field] = on
  -- emacs and vi line-editing modes are mutually exclusive.
  if on and field == "opt_emacs" then sh.opt_vi = false
  elseif on and field == "opt_vi" then sh.opt_emacs = false end
end

-- bash `shopt` options in bash's own listing order, with their default state.
-- Curse doesn't implement most behaviors, but validity + default + on/off display
-- must match bash. sh.shopt[name] overrides the default once set/unset.
local SHOPT_ORDER = {
  "autocd", "assoc_expand_once", "cdable_vars", "cdspell", "checkhash", "checkjobs",
  "checkwinsize", "cmdhist", "compat31", "compat32", "compat40", "compat41",
  "compat42", "compat43", "compat44", "complete_fullquote", "direxpand", "dirspell",
  "dotglob", "execfail", "expand_aliases", "extdebug", "extglob", "extquote",
  "failglob", "force_fignore", "globasciiranges", "globskipdots", "globstar",
  "gnu_errfmt", "histappend", "histreedit", "histverify", "hostcomplete", "huponexit",
  "inherit_errexit", "interactive_comments", "lastpipe", "lithist", "localvar_inherit",
  "localvar_unset", "login_shell", "mailwarn", "no_empty_cmd_completion", "nocaseglob",
  "nocasematch", "noexpand_translation", "nullglob", "patsub_replacement", "progcomp",
  "progcomp_alias", "promptvars", "restricted_shell", "shift_verbose", "sourcepath",
  "varredir_close", "xpg_echo",
}
local SHOPT_DEFAULT = {} -- name -> true (valid); default-on ones map to "on"
for _, n in ipairs(SHOPT_ORDER) do SHOPT_DEFAULT[n] = false end
for _, n in ipairs({ "checkwinsize", "cmdhist", "complete_fullquote", "extquote",
  "force_fignore", "globasciiranges", "globskipdots", "hostcomplete",
  "interactive_comments", "patsub_replacement", "progcomp", "promptvars",
  "sourcepath" }) do SHOPT_DEFAULT[n] = true end
local function shopt_on(sh, name)
  local v = sh.shopt[name]
  if v == nil then return SHOPT_DEFAULT[name] end
  return v
end

-- Quote a value the way `set`/`declare -p` do: bare if it's all "safe" chars,
-- else single-quoted with embedded quotes escaped as '\''.
local function sq(s)
  if s == "" then return "''" end
  if s:match("^[%w_,.:/@%%+=%-]+$") then return s end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end
-- Field-split a line for `read` into exactly `nvars` values. Skips leading IFS
-- whitespace; each field but the last stops at an IFS char (a run of IFS
-- whitespace + at most one IFS non-whitespace is one delimiter); the LAST var
-- gets the verbatim remainder (keeping its interior separators — unlike a
-- re-join) with trailing IFS whitespace stripped.
local function read_split(ifs, line, nvars)
  local wsset, ifsset = {}, {}
  for c in ifs:gmatch(".") do ifsset[c] = true; if c == " " or c == "\t" or c == "\n" then wsset[c] = true end end
  local i, n = 1, #line
  local function cw(p) return wsset[line:sub(p, p)] end
  local function cifs(p) return ifsset[line:sub(p, p)] end
  while i <= n and cw(i) do i = i + 1 end -- leading IFS whitespace
  local out = {}
  for v = 1, nvars do
    if v == nvars then
      local rest = line:sub(i)
      while #rest > 0 and wsset[rest:sub(-1)] do rest = rest:sub(1, -2) end -- trailing IFS ws
      out[v] = rest
    else
      local s = i
      while i <= n and not cifs(i) do i = i + 1 end
      out[v] = line:sub(s, i - 1)
      while i <= n and cw(i) do i = i + 1 end -- delimiter: IFS whitespace
      if i <= n and cifs(i) then i = i + 1; while i <= n and cw(i) do i = i + 1 end end -- + one non-ws
    end
  end
  return out
end
-- `set` (no args) one-line rendering of a variable box.
local function fmt_set_var(name, b)
  if b.assoc and b.arr then
    local keys = {}
    for k in pairs(b.arr) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
      local kq = tostring(k):match("^[%w_]+$") and tostring(k) or ('"' .. tostring(k):gsub('"', '\\"') .. '"')
      parts[#parts + 1] = ("[%s]=\"%s\""):format(kq, tostring(b.arr[k]):gsub('"', '\\"'))
    end
    return ("%s=(%s )"):format(name, table.concat(parts, " ")) -- trailing space, like bash
  elseif b.arr then
    local idx = {}
    for k in pairs(b.arr) do idx[#idx + 1] = k end
    table.sort(idx, function(x, y) return tonumber(x) < tonumber(y) end)
    local parts = {}
    for _, i in ipairs(idx) do parts[#parts + 1] = ('[%d]="%s"'):format(tonumber(i), tostring(b.arr[i]):gsub('"', '\\"')) end
    return ("%s=(%s)"):format(name, table.concat(parts, " "))
  else
    return name .. "=" .. sq(b.s ~= nil and b.s or (b.n ~= nil and rt.i64_to_str(b.n) or ""))
  end
end

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
  long read(int fd, void *buf, unsigned long count);
]]
local C = ffi.C
-- Unbuffered one-byte read from a raw fd (for `read`, which must NOT over-read
-- past its delimiter/char count — buffered io.read would swallow the rest of the
-- stream, breaking a subsequent read from the same underlying fd).
local rd1 = ffi.new("char[1]")
local function fd_getc(fd)
  local n = C.read(fd, rd1, 1)
  if n == 1 then return string.char(rd1[0] % 256) end
  return nil -- EOF or error
end
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
-- `test -v NAME` / `[[ -v NAME ]]`: is the variable (or array element) set?
local array_key -- forward (defined below)
local function var_is_set(sh, nm)
  local base, sub = nm:match("^([%a_][%w_]*)%[(.+)%]$")
  if base then return sh:is_elem_set(base, array_key(sh, base, sub)) end
  if nm:match("^%d+$") then return tonumber(nm) <= sh.nparams end -- positional param
  return sh.vars[sh:deref(nm)] ~= nil or sh:special_get(nm) ~= ""
end
local function unary(sh, op, x)
  if op == "-z" then return x == "" end
  if op == "-n" then return x ~= "" end
  if op == "-o" then return sh and SETOPT[x] and opt_on(sh, SETOPT[x]) or false end -- shell option on
  if op == "-v" then return sh and var_is_set(sh, x) or false end -- variable/element is set
  return file_test(op, x) -- -e/-f/-d/-r/-w/-x/-s…
end
local function binary(x, op, y)
  if op == "=" or op == "==" then return x == y end
  if op == "!=" then return x ~= y end
  if op == "<" then return x < y end -- string compare (C locale, like bash)
  if op == ">" then return x > y end
  local nx, ny = rt.arith_num(x), rt.arith_num(y) -- -eq etc. honor bases (017, 0xf, N#)
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
local function eval_test(sh, a, lo, hi)
  local n = hi - lo + 1
  if n <= 0 then return false end
  -- ( expr ): strip only when lo's `(` matches hi's `)`
  if a[lo] == "(" then
    local depth = 0
    for j = lo, hi do
      if a[j] == "(" then depth = depth + 1
      elseif a[j] == ")" then depth = depth - 1; if depth == 0 then
        if j == hi then return eval_test(sh, a, lo + 1, hi - 1) end; break
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
        local l, r = eval_test(sh, a, lo, j - 1), eval_test(sh, a, j + 1, hi)
        if opw == "-o" then return l or r else return l and r end
      end
    end
  end
  if a[lo] == "!" and n > 1 then return not eval_test(sh, a, lo + 1, hi) end
  if n == 1 then return a[lo] ~= "" end
  if n == 2 then return unary(sh, a[lo], a[lo + 1]) end
  if n == 3 then return binary(a[lo], a[lo + 1], a[lo + 2]) end
  return false
end
local function do_test(sh, args)
  local lo, hi = 2, #args
  if args[1] == "[" then
    if args[hi] ~= "]" then sh.status = 2; return end
    hi = hi - 1
  end
  local ok, res = pcall(eval_test, sh, args, lo, hi)
  sh.status = (ok and res) and 0 or 1
end

local expand_word -- forward (used by eval's $-deferred arith and expand_part_str)
local expand_pattern -- forward (quote-aware glob-pattern expansion for ${v/…} etc.)
local eval  -- arithmetic evaluator (forward decl)
local arith_resolve -- var-value-as-arith-expression resolver (forward decl)
local arith_key -- array subscript in arith: string key for assoc, number for indexed
local arith_int -- forward: arith-eval a slice offset/length string
local run_trap -- trap-handler runner (forward decl; defined near the bottom)
-- Resolve a variable's string value in arithmetic. bash treats it as an arith
-- EXPRESSION: a bare number is its value, but a name (or `3+4`, `bar`) is
-- recursively parsed and evaluated (so bar=foo; foo=5; $((bar)) == 5). A pure
-- integer literal short-circuits (the hot path); a recursion guard bounds cycles.
local function looks_numeric(s)
  return s:match("^%s*[+-]?%d+%s*$") or s:match("^%s*[+-]?0[xX]%x+%s*$")
    or s:match("^%s*[+-]?0[0-7]+%s*$") or s:match("^%s*%d+#[%w@_]+%s*$")
end
arith_resolve = function(sh, s)
  if s == nil or s == "" then return i64(0) end
  if looks_numeric(s) then return rt.arith_num(s) end
  sh.arith_depth = (sh.arith_depth or 0) + 1
  local r = i64(0)
  if sh.arith_depth <= 40 then
    local ok, ast = pcall(require("parser").arith, s)
    if ok then local ok2, v = pcall(eval, sh, ast); if ok2 and v ~= nil then r = v end end
  end
  sh.arith_depth = sh.arith_depth - 1
  return r
end

eval = function(sh, e)
  local k = e.k
  if k == "num" then return rt.arith_num(e.v) end
  if k == "var" then
    if e.idx then return arith_resolve(sh, sh:array_get(e.name, arith_key(sh, e.name, e.idx))) end
    if sh.opt_u and sh.vars[sh:deref(e.name)] == nil and sh:special_get(e.name) == "" then
      io.stderr:write("curse: " .. e.name .. ": unbound variable\n"); error({ __curse_exit = 1 })
    end
    return arith_resolve(sh, sh:get(e.name))
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
    local iv = e.idx and arith_key(sh, e.name, e.idx) or nil
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
      local iv = arith_key(sh, e.name, e.idx)
      local cur = rt.arith_num(sh:array_get(e.name, iv))
      sh:array_set(e.name, iv, rt.i64_to_str(cur + i64(e.d))); return cur
    end
    local cur = sh:aget(e.name); sh:aset(e.name, cur + i64(e.d)); return cur
  end
  if k == "pre" then
    if e.idx then
      local iv = arith_key(sh, e.name, e.idx)
      local v = rt.arith_num(sh:array_get(e.name, iv)) + i64(e.d)
      sh:array_set(e.name, iv, rt.i64_to_str(v)); return v
    end
    local v = sh:aget(e.name) + i64(e.d); return sh:aset(e.name, v)
  end
  error("interp: bad arith node " .. tostring(k))
end
M.eval = eval

-- An array subscript used in arithmetic: an associative array takes the
-- evaluated-then-stringified value as its key ("5"), an indexed array a number.
arith_key = function(sh, name, idxexpr)
  local v = eval(sh, idxexpr)
  if sh:is_assoc(name) then return rt.i64_to_str(v) end
  return tonumber(rt.i64_to_str(v))
end


-- Resolve an array subscript to a key: a string (word-expanded) for an
-- associative array, else an integer (arith-evaluated) for an indexed one.
array_key = function(sh, name, index_raw)
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
    elseif p.special == "!" then return sh.last_bg_pid or ""
    elseif p.special == "-" then return sh:dash_flags() end
    return ""
  elseif p.arith then return rt.i64_to_str(eval(sh, require("parser").arith(p.arith)))
  elseif p.procsub then
    -- <(cmd)/>(cmd): substitute a filename. <( ) runs the command and captures its
    -- output to a temp file whose path is the word; >( ) makes a temp file the word
    -- and feeds it to the command AFTER the outer command runs (sh.procsub_pending).
    local tmp = os.tmpname()
    if p.dir == "<" then
      local out = sh:capture_src(p.procsub)
      local f = io.open(tmp, "w"); if f then f:write(out); if out ~= "" then f:write("\n") end; f:close() end
    else
      sh.procsub_pending = sh.procsub_pending or {}
      sh.procsub_pending[#sh.procsub_pending + 1] = { file = tmp, cmd = p.procsub }
      local f = io.open(tmp, "w"); if f then f:close() end
    end
    sh.procsub_files = sh.procsub_files or {}; sh.procsub_files[#sh.procsub_files + 1] = tmp
    return tmp
  elseif p.cmdsub then return sh:capture_src(p.cmdsub)
  elseif p.pexp then
    local pe, P = p.pexp, require("parser")
    if pe.op == "@" and pe.arg == "P" then -- ${x@P}: decode prompt escapes, then expand
      return expand_word(sh, P.parse_word(sh:prompt_escapes(sh:get(pe.name))))
    end
    if pe.op == "indirect" and pe.iop then -- ${!ref OP arg}: resolve name, then apply OP
      local b = sh.vars[pe.name]
      local tname = (b and b.ref and b.s) or sh:get(pe.name) -- nameref target, else $ref
      tname = tname:gsub("%[.*$", "")
      if tname == "" then return "" end
      local part = P.parse_paramexp(tname .. pe.iop); part.q = p.q
      return expand_part_str(sh, part)
    end
    local subkey
    if pe.index and pe.index ~= "@" and pe.index ~= "*" then
      subkey = array_key(sh, pe.name, pe.index)
    end
    -- pattern-context ops (/, //) treat quoted metachars literally; everything
    -- else (defaults :-/-, etc.) expands the arg as an ordinary value.
    local patmode = pe.op == "/" or pe.op == "//"
    local arg = pe.arg and (patmode and expand_pattern or expand_word)(sh, P.parse_word(pe.arg)) or nil
    local arg2 = pe.arg2 and expand_word(sh, P.parse_word(pe.arg2)) or nil
    if pe.op == "sub" then -- ${v:off:len}: offset/length are arithmetic expressions
      arg = arg and tostring(arith_int(sh, arg) or 0) or nil
      arg2 = arg2 and tostring(arith_int(sh, arg2) or 0) or nil
    end
    return sh:expand_param(pe, arg, arg2, subkey)
  end
  return ""
end

-- Expand a word to a single string (assignment RHS, case subject, arith index —
-- contexts that do NOT word-split).
-- Tilde expansion on a word-initial unquoted literal: ~ / ~/… -> $HOME, ~+ -> PWD,
-- ~- -> OLDPWD (~user is left alone).
local function tilde_prefix(sh, s)
  if s:sub(1, 1) ~= "~" then return s end
  local r = s:sub(2)
  if r == "" or r:sub(1, 1) == "/" then local h = sh:get("HOME"); return h ~= "" and (h .. r) or s end
  if (r == "+" or r:sub(1, 2) == "+/") then return sh:special_get("PWD") .. r:sub(2) end
  if (r == "-" or r:sub(1, 2) == "-/") then local o = sh:get("OLDPWD"); return o ~= "" and (o .. r:sub(2)) or s end
  return s
end
M.tilde_prefix = tilde_prefix

expand_word = function(sh, w)
  local buf = {}
  for k, p in ipairs(w.parts) do
    local s = expand_part_str(sh, p)
    if k == 1 and p.lit ~= nil and not p.q then s = tilde_prefix(sh, s) end
    buf[#buf + 1] = s
  end
  return table.concat(buf)
end

-- Expand a word used as a glob PATTERN (${v/pat/repl}, case, [[ == ]]): a QUOTED
-- part's glob metacharacters are backslash-escaped so they match literally, while
-- an unquoted part's (including unquoted $var expansions) stay active — matching
-- bash's rule that quoting, not the value, decides literalness.
expand_pattern = function(sh, w)
  local buf = {}
  for _, p in ipairs(w.parts) do
    local s = expand_part_str(sh, p)
    if p.q then s = s:gsub("[%*%?%[%]\\%(%)%|%+%@%!]", "\\%0") end
    buf[#buf + 1] = s
  end
  return table.concat(buf)
end

-- Expand a word used as a `=~` regex: a QUOTED part is matched literally (its
-- ERE metacharacters are backslash-escaped), an unquoted part is a live regex.
local function expand_regex(sh, w)
  local buf = {}
  for _, p in ipairs(w.parts) do
    local s = expand_part_str(sh, p)
    if p.q then s = s:gsub("[%.%^%$%*%+%?%(%)%[%]%{%}%|\\]", "\\%0") end
    buf[#buf + 1] = s
  end
  return table.concat(buf)
end

-- A part that expands to multiple elements: $@ / $* / ${a[@]} / ${a[*]} /
-- ${!a[@]} (keys). ${#a[@]} (op="len") is a single count, NOT multi.
local function is_multi(p)
  if not p.pexp then return p.special == "@" or p.special == "*" end
  if p.pexp.op == "len" then return false end
  if p.pexp.op == "prefix" then return true end -- ${!pfx@} / ${!pfx*}
  return p.pexp.index == "@" or p.pexp.index == "*"
end
-- arith-evaluate a slice offset/length expression (e.g. "i-4", "(-4)", "2").
arith_int = function(sh, s)
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
    if pe.op == "prefix" then return sh:var_prefix_names(pe.name), pe.star end
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
  for pi, p in ipairs(w.parts) do
    if is_multi(p) then
      local els, star = multi_elems(sh, p)
      if p.q then
        if star then -- "$*" / "${a[*]}" join with the first char of IFS
          local sep = sh.vars["IFS"] and sh:get("IFS"):sub(1, 1) or " "
          add(table.concat(els, sep), false)
        else for k = 1, #els do if k > 1 then brk() end; add(els[k], false) end end -- one field per element
      else
        for k = 1, #els do if k > 1 then brk() end; feed_split(els[k]) end
      end
    else
      local s = expand_part_str(sh, p)
      if pi == 1 and p.lit ~= nil and not p.q then s = tilde_prefix(sh, s) end -- word-initial ~
      if p.q or p.lit ~= nil then add(s, not p.q) else feed_split(s) end
    end
  end
  brk()
  -- pathname expansion on fields with unquoted glob metacharacters
  local out = {}
  -- GLOBIGNORE (set & non-null): filter matches by its `:`-separated patterns and
  -- enable dotglob (leading-dot names then match); `.`/`..` are always excluded.
  local gi = sh:get("GLOBIGNORE")
  local giset = sh.vars[sh:deref("GLOBIGNORE")] ~= nil and gi ~= ""
  local dotglob = giset or (sh.shopt.dotglob and true)
  local nullglob = sh.shopt.nullglob and true
  local gipats
  if giset then gipats = {}; for p in (gi .. ":"):gmatch("([^:]*):") do if p ~= "" then gipats[#gipats + 1] = p end end end
  for _, f in ipairs(fields) do
    if f.unq and (f.s:find("[*?%[]") or f.s:find("[?*+@!]%(")) then
      local m = rt.glob_expand(f.s, { dotglob = dotglob })
      if m and gipats then
        local filt = {}
        for _, x in ipairs(m) do
          local ig = false
          for _, p in ipairs(gipats) do if rt.glob_ignore_match(x, p) then ig = true; break end end
          if not ig then filt[#filt + 1] = x end
        end
        m = (#filt > 0) and filt or nil
      end
      if m then for _, x in ipairs(m) do out[#out + 1] = x end
      elseif nullglob then -- no matches: nullglob drops the field entirely
      else out[#out + 1] = f.s end
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
      -- noclobber (set -C): O_EXCL so `>` fails on an existing file (705 adds O_EXCL)
      backup(r.fd); local f = C.open(tgt(r), sh.opt_C and 705 or 577, 420)
      if f >= 0 then C.dup2(f, r.fd); C.close(f) else ok = false end
    elseif r.op == "clobber" then -- `>|` truncates regardless of noclobber
      backup(r.fd); local f = C.open(tgt(r), 577, 420)
      if f >= 0 then C.dup2(f, r.fd); C.close(f) else ok = false end
    elseif r.op == "app" then
      backup(r.fd); local f = C.open(tgt(r), 1089, 420)
      if f >= 0 then C.dup2(f, r.fd); C.close(f) else ok = false end
    elseif r.op == "in" then
      backup(r.fd); local f = C.open(tgt(r), 0, 0)
      if f >= 0 then C.dup2(f, r.fd); C.close(f) else ok = false end
    elseif r.op == "outboth" then -- `&>` truncation honors noclobber (O_EXCL) too
      backup(1); backup(2); local f = C.open(tgt(r), sh.opt_C and 705 or 577, 420)
      if f >= 0 then C.dup2(f, 1); C.dup2(f, 2); C.close(f) else ok = false end
    elseif r.op == "appboth" then -- `&>>`: append stdout+stderr (append ignores noclobber)
      backup(1); backup(2); local f = C.open(tgt(r), 1089, 420)
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
  mapfile = 1, readarray = 1, compgen = 1, complete = 1, compopt = 1,
  pushd = 1, popd = 1, dirs = 1, builtin = 1,
}
M.BUILTINS = BUILTINS -- exposed so the compiled backend delegates the same set
local KEYWORDS = {
  ["if"] = 1, ["then"] = 1, ["else"] = 1, ["elif"] = 1, ["fi"] = 1, ["for"] = 1,
  ["while"] = 1, ["until"] = 1, ["do"] = 1, ["done"] = 1, ["case"] = 1, ["esac"] = 1,
  ["function"] = 1, ["in"] = 1, ["select"] = 1, ["{"] = 1, ["}"] = 1, ["!"] = 1,
  ["time"] = 1, ["[["] = 1, ["]]"] = 1, ["coproc"] = 1,
}
-- Find `name` in PATH (existence, F_OK — bash's type/command-v report a
-- non-executable file too; execution then fails 126 via posix_spawn).
local function find_in_path(name)
  if name:find("/", 1, true) then return C.access(name, 0) == 0 and name or nil end
  local path = os.getenv("PATH") or "/usr/bin:/bin"
  for dir in path:gmatch("[^:]+") do
    local p = dir .. "/" .. name
    if C.access(p, 0) == 0 then return p end
  end
  return nil
end
local function name_type(sh, name)
  if sh.aliases[name] then return "alias" end
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
    -- attribute letters in bash's order: -rxilu (readonly/export/integer/lower/upper)
    local a = (b.ro and "r" or "") .. (os.getenv(name) ~= nil and "x" or "")
      .. (b.int and "i" or "") .. (b.lower and "l" or "") .. (b.upper and "u" or "")
    return "declare " .. (a == "" and "--" or "-" .. a) .. " " .. name .. "=" .. decl_quote(sh:get(name))
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

-- ---- printf (native, bash-compatible) ----
-- An integer printf argument: `'x`/`"x` is the code of the first byte; "" is 0;
-- otherwise arithmetic (bases honored). Returns (int64, ok) — ok=false marks an
-- invalid number (bash prints 0 and sets status 1). int64 keeps full 64-bit
-- precision for %d/%u/%o/%x (LuaJIT's string.format formats cdata directly).
local function printf_int(s)
  if s == nil or s == "" then return 0LL, true end
  local c = s:sub(1, 1)
  if c == "'" or c == '"' then return (#s >= 2 and i64(s:byte(2)) or 0LL), true end
  local ok, v = pcall(rt.arith_num, s)
  if ok then return v, true end
  return 0LL, false
end
-- A floating printf argument (for %f/%e/%g): C strtod semantics via tonumber.
local function printf_float(s)
  if s == nil or s == "" then return 0, true end
  local c = s:sub(1, 1)
  if c == "'" or c == '"' then return (#s >= 2 and s:byte(2) or 0), true end
  local v = tonumber(s)
  if v then return v, true end
  return 0, false
end
-- width/precision for %s or a %(…)T result via string.format on a plain string.
-- printf %q: quote so the result re-reads as the same word (bash style: backslash-
-- escape metacharacters/whitespace; $'…' when control chars are present).
local function printf_q(s)
  if s == "" then return "''" end
  if s:match("^[%w_@%%%+%-%./,:=^]+$") then return s end
  if s:find("[%z\1-\31\127]") then
    local out = { "$'" }
    for k = 1, #s do
      local ch, b = s:sub(k, k), s:byte(k)
      if ch == "\n" then out[#out + 1] = "\\n"
      elseif ch == "\t" then out[#out + 1] = "\\t"
      elseif ch == "\r" then out[#out + 1] = "\\r"
      elseif b < 32 or b == 127 then out[#out + 1] = string.format("\\%03o", b)
      elseif ch == "'" then out[#out + 1] = "\\'"
      elseif ch == "\\" then out[#out + 1] = "\\\\"
      else out[#out + 1] = ch end
    end
    out[#out + 1] = "'"; return table.concat(out)
  end
  return (s:gsub("[%s\"'\\|&;<>()$`?*%[%]#~=!{}^]", "\\%0"))
end
local uint64_t = ffi.typeof("uint64_t")
-- Format one numeric %-conversion from a raw arg string. Returns (string, ok).
local function printf_conv(full, conv, arg)
  if conv == "d" or conv == "i" then
    local v, ok = printf_int(arg); return string.format(full .. "d", v), ok
  elseif conv == "u" then
    local v, ok = printf_int(arg); return string.format(full .. "u", uint64_t(v)), ok
  elseif conv == "o" or conv == "x" or conv == "X" then
    local v, ok = printf_int(arg); return string.format(full .. conv, uint64_t(v)), ok
  elseif conv == "f" or conv == "F" or conv == "e" or conv == "E" or conv == "g"
      or conv == "G" or conv == "a" or conv == "A" then
    local v, ok = printf_float(arg); return string.format(full .. (conv == "F" and "f" or conv), v), ok
  end
  return nil, true -- unknown conversion
end
-- The full printf engine. `argv[start..]` are the data args; the format is reused
-- until they're exhausted. Returns (output, status).
local function sh_printf(fmt, argv, start)
  local out, status, ai = {}, 0, start
  local nargs = #argv
  local function nextarg() local v = argv[ai]; if v ~= nil then ai = ai + 1 end; return v or "" end
  repeat
    local pass_start = ai
    local i, n = 1, #fmt
    while i <= n do
      local c = fmt:sub(i, i)
      if c == "\\" then -- format-level backslash escapes (\n \t \\ \ooo \xHH …)
        local d = fmt:sub(i + 1, i + 1)
        if d == "n" then out[#out + 1] = "\n"; i = i + 2
        elseif d == "t" then out[#out + 1] = "\t"; i = i + 2
        elseif d == "r" then out[#out + 1] = "\r"; i = i + 2
        elseif d == "\\" then out[#out + 1] = "\\"; i = i + 2
        elseif d == "a" then out[#out + 1] = "\7"; i = i + 2
        elseif d == "b" then out[#out + 1] = "\8"; i = i + 2
        elseif d == "f" then out[#out + 1] = "\12"; i = i + 2
        elseif d == "v" then out[#out + 1] = "\11"; i = i + 2
        elseif d == "x" then local h = fmt:match("^%x%x?", i + 2)
          if h then out[#out + 1] = string.char(tonumber(h, 16)); i = i + 2 + #h else out[#out + 1] = "\\"; i = i + 1 end
        elseif d:match("[0-7]") then local o = fmt:match("^[0-7][0-7]?[0-7]?", i + 1)
          out[#out + 1] = string.char(tonumber(o, 8) % 256); i = i + 1 + #o
        else out[#out + 1] = "\\"; i = i + 1 end
      elseif c == "%" then
        local j = i + 1
        if fmt:sub(j, j) == "%" then out[#out + 1] = "%"; i = j + 1
        else
          local spec = "%"
          while fmt:sub(j, j):match("[-+ #0]") do spec = spec .. fmt:sub(j, j); j = j + 1 end
          local width = ""
          if fmt:sub(j, j) == "*" then local w = printf_num(nextarg()); width = tostring(math.floor(w)); j = j + 1
          else while fmt:sub(j, j):match("%d") do width = width .. fmt:sub(j, j); j = j + 1 end end
          local prec = nil
          if fmt:sub(j, j) == "." then
            j = j + 1; prec = ""
            if fmt:sub(j, j) == "*" then local p = printf_num(nextarg()); prec = tostring(math.floor(p)); j = j + 1
            else while fmt:sub(j, j):match("%d") do prec = prec .. fmt:sub(j, j); j = j + 1 end end
          end
          while fmt:sub(j, j):match("[lhLjzt]") do j = j + 1 end -- length mods (ignored)
          if fmt:sub(j, j) == "(" then -- %(FORMAT)T strftime
            local close = fmt:find(")", j + 1, true)
            local tfmt = fmt:sub(j + 1, (close or j + 1) - 1)
            j = (close or j) + 1 -- now at 'T'
            local arg = nextarg()
            local epoch = (arg == "" or arg == "-1") and os.time() or (tonumber(arg) or os.time())
            local sres = os.date(tfmt, epoch) or ""
            if prec then sres = sres:sub(1, tonumber(prec)) end
            out[#out + 1] = string.format("%" .. (spec:sub(2)) .. width .. "s", sres)
            i = j + 1
          else
            local conv = fmt:sub(j, j)
            local full = spec .. width .. (prec and ("." .. prec) or "")
            if conv == "s" then
              out[#out + 1] = string.format((spec:gsub("0", "", 1)) .. width .. (prec and ("." .. prec) or "") .. "s", nextarg())
            elseif conv == "c" then -- first char of the (string) argument
              out[#out + 1] = string.format("%" .. spec:sub(2) .. width .. "s", nextarg():sub(1, 1))
            elseif conv == "b" then
              out[#out + 1] = string.format("%" .. spec:sub(2) .. width .. "s", rt.ansi_unescape(nextarg()))
            elseif conv == "q" then
              local s = printf_q(nextarg())
              out[#out + 1] = width ~= "" and string.format("%" .. spec:sub(2) .. width .. "s", s) or s
            else
              local r, ok = printf_conv(full, conv, nextarg())
              if not ok then status = 1 end
              if r == nil then io.stderr:write("curse: printf: `" .. conv .. "': invalid conversion specification\n"); status = 1 end
              out[#out + 1] = r or ""
            end
            i = j + 1
          end
        end
      else out[#out + 1] = c; i = i + 1 end
    end
  until ai > nargs or ai == pass_start
  return table.concat(out), status
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
    local stopped
    if esc then s, stopped = rt.ansi_unescape(s) end -- \c stops all output (incl. the newline)
    sh.out(s); if not nonl and not stopped then sh.out("\n") end
    sh.status = 0
  elseif cmd == ":" or cmd == "true" then sh.status = 0
  elseif cmd == "false" then sh.status = 1
  elseif cmd == "break" then -- outside a loop: a no-op (bash), not a fatal unwind
    sh.status = 0; if (sh.loopdepth or 0) > 0 then error({ __curse_break = tonumber(args[2]) or 1 }) end
  elseif cmd == "continue" then
    sh.status = 0; if (sh.loopdepth or 0) > 0 then error({ __curse_continue = tonumber(args[2]) or 1 }) end
  elseif cmd == "eval" then
    -- eval [--]: join args, parse, run in the CURRENT shell (return/exit propagate).
    local start = (args[2] == "--") and 3 or 2
    local code = table.concat({ unpack(args, start) }, " ")
    if code:match("%S") then
      local ok, parsed = pcall(require("parser").parse, code)
      if not ok then io.stderr:write("curse: eval: " .. tostring(parsed) .. "\n"); sh.status = 2
      else exec_list(sh, parsed.stmts, hook, false) end
    else sh.status = 0 end
  elseif cmd == "source" or cmd == "." then
    -- source FILE [args]: run FILE in the current shell; a `return` ends the file.
    local file = args[2]
    local f = file and io.open(file, "r")
    if not f then io.stderr:write("curse: " .. cmd .. ": " .. tostring(file) .. ": No such file or directory\n"); sh.status = 1
    else
      local src = f:read("*a"); f:close()
      local ok, parsed = pcall(require("parser").parse, src)
      if not ok then sh.status = 2
      else
        local savep, savenp = sh.params, sh.nparams
        if #args > 2 then
          sh.params, sh.nparams = {}, 0
          for k = 3, #args do sh.nparams = sh.nparams + 1; sh.params[sh.nparams] = args[k] end
        end
        local rok, err = pcall(exec_list, sh, parsed.stmts, hook, false)
        if #args > 2 then sh.params, sh.nparams = savep, savenp end
        if not rok then
          if type(err) == "table" and err.__curse_return then sh.status = err.__curse_return
          else error(err) end -- exit propagates
        end
      end
    end
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
    local j, pflag = 2, false
    if args[j] == "-l" then -- list signal names (NN) SIGNAME)
      local nums = {}; for n in pairs(NUMSIG) do nums[#nums + 1] = n end; table.sort(nums)
      for _, n in ipairs(nums) do sh:echo(("%2d) SIG%s"):format(n, NUMSIG[n])) end
      sh.status = 0; return
    end
    if args[j] == "-p" then pflag = true; j = j + 1 end
    if args[j] == "--" then j = j + 1 end
    if pflag or j > #args then -- print traps (all, or the named signals) in signal order
      local list = {}
      if j <= #args then -- print only the named signals
        for k = j, #args do local c = canon_sig(args[k]); if c and sh.traps[c] then list[#list + 1] = c end end
      else for canon in pairs(sh.traps) do list[#list + 1] = canon end end
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
    if #args < 2 then io.stderr:write("curse: unalias: usage: unalias [-a] name [name ...]\n"); ok = false
    elseif args[2] == "-a" then sh.aliases = {}
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
    local set_, unset_, quiet, oflag, pflag, badopt = false, false, false, false, false, false
    local names = {}
    for k = 2, #args do
      local a = args[k]
      if a == "-s" then set_ = true elseif a == "-u" then unset_ = true
      elseif a == "-q" then quiet = true elseif a == "-p" then pflag = true
      elseif a == "-o" then oflag = true
      elseif a:match("^-[suqpo]+$") then
        if a:find("s") then set_ = true end; if a:find("u") then unset_ = true end
        if a:find("q") then quiet = true end; if a:find("o") then oflag = true end
        if a:find("p") then pflag = true end
      elseif a:sub(1, 2) == "--" then badopt = true -- long opts are Oil syntax; bash errors
      else names[#names + 1] = a end
    end
    if badopt then
      io.stderr:write("curse: shopt: invalid option\n"); sh.status = 1
    elseif oflag then -- shopt -o: the `set -o` options
      if set_ or unset_ then
        local allok = true
        for _, nm in ipairs(names) do
          if SETOPT[nm] then set_opt(sh, SETOPT[nm], set_)
          else io.stderr:write("curse: shopt: " .. nm .. ": invalid option name\n"); allok = false end
        end
        sh.status = allok and 0 or 1
      elseif #names == 0 then -- list all set-o options
        for _, ent in ipairs(SETOPTS) do
          if pflag then sh.out(("set %so %s\n"):format(opt_on(sh, ent[2]) and "-" or "+", ent[1]))
          else sh.out(("%-15s\t%s\n"):format(ent[1], opt_on(sh, ent[2]) and "on" or "off")) end
        end
        sh.status = 0
      else
        local allok = true
        for _, nm in ipairs(names) do
          if not SETOPT[nm] then allok = false -- unknown: skipped, drops status
          else
          local on = opt_on(sh, SETOPT[nm])
          if not on then allok = false end
          if not quiet then
            if pflag then sh.out(("set %so %s\n"):format(on and "-" or "+", nm))
            else sh.out(("%-15s\t%s\n"):format(nm, on and "on" or "off")) end
          end
          end
        end
        sh.status = allok and 0 or 1
      end
    elseif set_ or unset_ then
      -- -s/-u NAMES: unknown names error (status 1) but valid ones still apply.
      local allok = true
      for _, nm in ipairs(names) do
        if SHOPT_DEFAULT[nm] == nil then
          io.stderr:write("curse: shopt: " .. nm .. ": invalid shell option name\n"); allok = false
        else sh.shopt[nm] = set_ end
      end
      sh.status = allok and 0 or 1
    elseif #names == 0 then -- print all options (query/-p; same 2-col/`shopt -s` form)
      for _, nm in ipairs(SHOPT_ORDER) do
        sh.out(("shopt %s%s\n"):format(shopt_on(sh, nm) and "-s " or "-u ", nm))
      end
      sh.status = 0
    else -- query / print named: invalid names skipped, drop status to 1
      local allok = true
      for _, nm in ipairs(names) do
        if SHOPT_DEFAULT[nm] == nil then allok = false -- unknown: not printed
        else
          local on = shopt_on(sh, nm)
          if not on then allok = false end
          if not quiet then
            if pflag then sh.out(("shopt %s%s\n"):format(on and "-s " or "-u ", nm))
            else sh.out(("%-15s\t%s\n"):format(nm, on and "on" or "off")) end
          end
        end
      end
      sh.status = allok and 0 or 1
    end
  elseif cmd == "[" or cmd == "test" then do_test(sh, args)
  elseif cmd == "return" then
    if args[2] and not tonumber(args[2]) then io.stderr:write("curse: return: " .. args[2] .. ": numeric argument required\n"); error({ __curse_return = 2 }) end
    error({ __curse_return = args[2] and (tonumber(args[2]) % 256) or sh.status })
  elseif cmd == "exit" then
    if args[2] and not tonumber(args[2]) then io.stderr:write("curse: exit: " .. args[2] .. ": numeric argument required\n"); error({ __curse_exit = 2 }) end
    error({ __curse_exit = args[2] and (tonumber(args[2]) % 256) or sh.status })
  elseif cmd == "cd" then
    local prev = sh:special_get("PWD")
    -- parse leading -L/-P/-e/-@ flags and a `--`, then the directory operand.
    local operands, j = {}, 2
    while args[j] do
      local a = args[j]
      if a == "--" then j = j + 1; break
      elseif a == "-" then operands[#operands + 1] = a; j = j + 1
      elseif a:match("^%-[LPe@]+$") then j = j + 1 -- flags (physical/logical: curse's PWD is physical)
      else break end
    end
    for k = j, #args do operands[#operands + 1] = args[k] end
    if #operands > 1 then io.stderr:write("curse: cd: too many arguments\n"); sh.status = 1; return end
    local dir = operands[1] or sh:get("HOME")
    if dir == "-" then dir = sh:get("OLDPWD"); if dir == "" then dir = prev end
      sh.status = (C.chdir(dir) == 0) and 0 or 1
      if sh.status == 0 then sh:echo(sh:special_get("PWD")) end -- cd - prints the new dir
    else
      sh.status = (C.chdir(dir) == 0) and 0 or 1
    end
    if sh.status == 0 then
      sh:set_str("OLDPWD", prev); C.setenv("OLDPWD", prev, 1)
      if sh.dirstack then sh.dirstack[1] = sh:special_get("PWD") end -- cd replaces the top of the stack
    end
  elseif cmd == "pushd" or cmd == "popd" or cmd == "dirs" then
    sh.dirstack = sh.dirstack or { sh:special_get("PWD") }
    local ds = sh.dirstack
    local function tilde(p) local h = sh:get("HOME"); if h ~= "" and p:sub(1, #h) == h then return "~" .. p:sub(#h + 1) end return p end
    if cmd == "dirs" then
      local vflag, pflag, lflag = false, false, false
      for j = 2, #args do
        local a = args[j]
        if a == "-c" then sh.dirstack = { sh:special_get("PWD") }; ds = sh.dirstack
        elseif a == "-v" then vflag = true elseif a == "-p" then pflag = true
        elseif a == "-l" then lflag = true end
      end
      if not args[2] or not args[2]:find("c") or vflag or pflag or lflag then
        local parts = {}
        for k = 1, #ds do parts[k] = lflag and ds[k] or tilde(ds[k]) end
        if vflag then for k = 1, #parts do sh:echo(("%2d  %s"):format(k - 1, parts[k])) end
        elseif pflag then for k = 1, #parts do sh:echo(parts[k]) end
        else sh:echo(table.concat(parts, " ")) end
      end
      sh.status = 0
    elseif cmd == "pushd" then
      local target
      for j = 2, #args do local a = args[j]
        if a == "--" then target = args[j + 1]; break
        elseif a:sub(1, 1) == "-" and a ~= "-" and not a:match("^[+-]%d+$") then
          io.stderr:write("curse: pushd: " .. a .. ": invalid option\n"); sh.status = 2; return
        elseif not target then target = a end
      end
      if not target then -- swap top two
        if #ds < 2 then io.stderr:write("curse: pushd: no other directory\n"); sh.status = 1; return end
        ds[1], ds[2] = ds[2], ds[1]; C.chdir(ds[1])
        sh:set_str("OLDPWD", sh:special_get("PWD")); ds[1] = sh:special_get("PWD")
      else
        local prev = sh:special_get("PWD")
        if C.chdir(target) ~= 0 then io.stderr:write("curse: pushd: " .. target .. ": No such file or directory\n"); sh.status = 1; return end
        sh:set_str("OLDPWD", prev); table.insert(ds, 1, sh:special_get("PWD"))
      end
      local parts = {}; for k = 1, #ds do parts[k] = tilde(ds[k]) end
      sh:echo(table.concat(parts, " ")); sh.status = 0
    else -- popd
      for j = 2, #args do local a = args[j]
        if a == "--" then -- ok
        elseif a:sub(1, 1) == "-" and a ~= "-" and not a:match("^[+-]%d+$") then
          io.stderr:write("curse: popd: " .. a .. ": invalid option\n"); sh.status = 2; return
        elseif a ~= "-" then io.stderr:write("curse: popd: " .. a .. ": invalid argument\n"); sh.status = 2; return end
      end
      if #ds < 2 then io.stderr:write("curse: popd: directory stack empty\n"); sh.status = 1; return end
      table.remove(ds, 1); C.chdir(ds[1]); ds[1] = sh:special_get("PWD")
      local parts = {}; for k = 1, #ds do parts[k] = tilde(ds[k]) end
      sh:echo(table.concat(parts, " ")); sh.status = 0
    end
  elseif cmd == "unset" then
    local fmode, vmode = false, false -- -f: functions only; -v: vars only; neither: var then function
    sh.status = 0
    for j = 2, #args do
      local a = args[j]
      if a == "-f" then fmode = true
      elseif a == "-v" then vmode = true
      elseif a:sub(1, 1) == "-" and #a > 1 then -- other flags: ignore
      elseif fmode then sh.functions[a] = nil
      else
        local nm, sub = a:match("^([%a_][%w_]*)%[(.+)%]$")
        if nm then sh:array_unset(nm, array_key(sh, nm, sub))
        else
          local b = sh.vars[sh:deref(a)]
          if b and b.ro then -- readonly: cannot unset (bash: status 1, keep it)
            io.stderr:write("curse: unset: " .. a .. ": cannot unset: readonly variable\n"); sh.status = 1
          elseif b ~= nil or vmode then
            sh.vars[sh:deref(a)] = nil; C.unsetenv(a) -- drop from the process env too
          elseif sh.functions[a] then sh.functions[a] = nil -- plain unset falls back to a function
          end
        end
      end
    end
  elseif cmd == "export" or cmd == "declare" or cmd == "typeset" or cmd == "readonly" then
    -- export/declare [-Apx] NAME[=val]…: set the var; export/-x also pushes it to
    -- the process env so posix_spawn children inherit it. -A marks associative,
    -- -p prints declarations.
    local doexport, assoc, printmode, nref, plusn = (cmd == "export"), false, false, false, false
    local funcnames, funcbody, iattr, lattr, uattr, rattr = false, false, false, false, false, false
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
        if a:find("i") then iattr = true end
        if a:find("l") then lattr = true end
        if a:find("u") then uattr = true end
        if a:find("r") then rattr = true end
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
      local roattr = (cmd == "readonly") or rattr
      for _, a in ipairs(rest) do
        local nm, op, val = a:match("^([%a_][%w_]*)(%+?=)(.*)$")
        if nm then
          local ap = (op == "+=")
          if nref then sh:make_nameref(nm, val)
          elseif iattr then -- declare -i: arith-evaluate the value, mark integer
            if ap then sh:aset(nm, sh:aget(nm) + eval(sh, require("parser").arith(val)))
            else sh:aset(nm, eval(sh, require("parser").arith(val))) end
            sh.vars[nm].int = true
          elseif lattr or uattr then -- declare -l/-u: lower/upper case attribute
            local nv = lattr and val:lower() or val:upper()
            sh:set_str(nm, ap and (sh:get(nm) .. nv) or nv)
            sh.vars[nm].lower = lattr or nil; sh.vars[nm].upper = uattr or nil
          else
            if assoc then sh:declare_assoc(nm) end
            sh:set_str(nm, ap and (sh:get(nm) .. val) or val)
            if doexport then C.setenv(nm, sh:get(nm), 1) end
          end
          if roattr and sh.vars[sh:deref(nm)] then sh.vars[sh:deref(nm)].ro = true end
        elseif a:match("^[%a_][%w_]*$") then
          if plusn then sh:unref(a)
          elseif nref then sh:make_nameref(a)
          elseif iattr then sh.vars[a] = sh.vars[a] or {}; sh.vars[a].int = true
          elseif lattr or uattr then
            sh.vars[a] = sh.vars[a] or {}; sh.vars[a].lower = lattr or nil; sh.vars[a].upper = uattr or nil
          elseif assoc then sh:declare_assoc(a)
          elseif doexport then C.setenv(a, sh:get(a), 1) end
          if roattr then sh.vars[a] = sh.vars[a] or {}; sh.vars[a].ro = true end
        end
      end
      sh.status = 0
    end
  elseif cmd == "set" then
    -- set [-e|+e|-o NAME|+o NAME|…] [--] [ARGS…]: options then positional params
    if #args == 1 then -- bare `set`: list all shell variables, sorted by name
      local names = {}
      for nm in pairs(sh.vars) do names[#names + 1] = nm end
      table.sort(names)
      for _, nm in ipairs(names) do
        local b = sh.vars[nm]
        if b and not (b.s == nil and b.n == nil and b.arr == nil) then
          sh.out(fmt_set_var(nm, b) .. "\n")
        end
      end
      sh.status = 0
      return
    end
    local j, dd = 2, false
    while j <= #args do
      local a = args[j]
      if a == "--" then dd = true; j = j + 1; break
      elseif a == "-o" or a == "+o" then
        local o, on = args[j + 1], (a == "-o")
        if o == nil then
          -- `set -o`: list options aligned; `set +o`: reproducible `set ±o NAME`.
          for _, ent in ipairs(SETOPTS) do
            if on then sh.out(("%-15s\t%s\n"):format(ent[1], opt_on(sh, ent[2]) and "on" or "off"))
            else sh.out(("set %so %s\n"):format(opt_on(sh, ent[2]) and "-" or "+", ent[1])) end
          end
          j = j + 1
        else
          if SETOPT[o] then set_opt(sh, SETOPT[o], on) end
          j = j + 2
        end
      elseif a:match("^[-+][a-zA-Z]+$") then -- short flag bundle: -eu, +u, …
        local on = a:sub(1, 1) == "-"
        for f in a:sub(2):gmatch(".") do
          if SETFLAG[f] then set_opt(sh, SETFLAG[f], on) end
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
    -- type [-t|-p|-P] NAME…  (-t type word; -p path-if-file; -P force PATH search)
    local tflag, pflag, Pflag, j0 = false, false, false, 2
    while args[j0] and args[j0]:sub(1, 1) == "-" and #args[j0] > 1 do
      local f = args[j0]
      if f:find("t") then tflag = true end
      if f:find("p") then pflag = true end
      if f:find("P") then Pflag = true end
      j0 = j0 + 1
    end
    local allok = true
    for j = j0, #args do
      local nm = args[j]
      if Pflag then
        local p = find_in_path(nm); if p then sh:echo(p) else allok = false end
      elseif pflag then
        local k, p = name_type(sh, nm)
        if k == "file" then sh:echo(p) elseif not k then allok = false end -- builtins/etc: nothing
      elseif tflag then
        local k = name_type(sh, nm); if k then sh:echo(k) else allok = false end
      else -- sentence form
        local k, p = name_type(sh, nm)
        if not k then allok = false; io.stderr:write("curse: type: " .. nm .. ": not found\n")
        elseif k == "alias" then sh:echo(nm .. " is aliased to `" .. sh.aliases[nm] .. "'")
        elseif k == "file" then sh:echo(nm .. " is " .. p)
        elseif k == "function" then sh:echo(nm .. " is a function")
        elseif k == "keyword" then sh:echo(nm .. " is a shell keyword")
        else sh:echo(nm .. " is a shell builtin") end
      end
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
  elseif cmd == "builtin" then
    -- builtin CMD args: run CMD as a shell builtin (skipping functions/aliases).
    if args[2] == nil then sh.status = 0
    else exec_simple(sh, { unpack(args, 2) }, hook) end -- builtins dispatch before functions here
  elseif cmd == "command" then
    local j = 2
    while args[j] == "-p" do j = j + 1 end -- -p: use default PATH (ignored)
    if args[j] == nil then sh.status = 0
    else exec_simple(sh, { unpack(args, j) }, hook) end -- run rest, bypassing functions (approx)
  elseif cmd == "compgen" then
    -- compgen [-A action|-f|-d|-c|-a|-b|-k|-v|-e] [-W wl] [-P pre] [-S suf] [prefix]
    local actions, wordlist, prefix, bad, cpre, csuf, xfilter = {}, nil, nil, false, "", "", nil
    local VALID = { ["function"] = 1, alias = 1, builtin = 1, keyword = 1, variable = 1,
      command = 1, file = 1, directory = 1, setopt = 1, shopt = 1, arrayvar = 1,
      export = 1, helptopic = 1, user = 1, hostname = 1, group = 1, job = 1, service = 1,
      signal = 1, disabled = 1, enabled = 1, running = 1, stopped = 1 }
    local SHORT = { f = "file", d = "directory", c = "command", a = "alias", b = "builtin",
      k = "keyword", v = "variable", e = "export", g = "group", u = "user", j = "job", s = "service" }
    local j = 2
    while args[j] do
      local a = args[j]
      if a == "-A" then local act = args[j + 1]; if not VALID[act] then bad = true end; actions[#actions + 1] = act; j = j + 2
      elseif a == "-W" then wordlist = args[j + 1]; j = j + 2
      elseif a == "-P" then cpre = args[j + 1] or ""; j = j + 2
      elseif a == "-S" then csuf = args[j + 1] or ""; j = j + 2
      elseif a == "-X" then xfilter = args[j + 1]; j = j + 2
      elseif a == "-F" or a == "-G" or a == "-C" or a == "-o" then j = j + 2 -- take+ignore
      elseif a:match("^-[fdcabkvegujs]+$") then for ch in a:sub(2):gmatch(".") do actions[#actions + 1] = SHORT[ch] end; j = j + 1
      elseif a:sub(1, 1) == "-" and #a > 1 then j = j + 1
      else prefix = a; j = j + 1 end
    end
    if bad then io.stderr:write("curse: compgen: invalid action\n"); sh.status = 2
    else
      local out, seen = {}, {}
      local function emit(x) if (not prefix or x:sub(1, #prefix) == prefix) and not seen[x] then seen[x] = true; out[#out + 1] = x end end
      local function names(tbl) local t = {}; for k in pairs(tbl) do t[#t + 1] = k end; table.sort(t); return t end
      -- -W words keep their insertion order; -A action results are sorted together.
      if wordlist then
        for _, w in ipairs(rt.ifs_split(sh.vars["IFS"] and sh:get("IFS") or " \t\n", wordlist)) do emit(w) end
      end
      local acc = {}
      local function add(x) acc[#acc + 1] = x end
      for _, act in ipairs(actions) do
        if act == "function" then for n in pairs(sh.functions) do add(n) end
        elseif act == "alias" then for n in pairs(sh.aliases) do add(n) end
        elseif act == "builtin" then for n in pairs(BUILTINS) do add(n) end
        elseif act == "keyword" then for n in pairs(KEYWORDS) do add(n) end
        elseif act == "variable" or act == "arrayvar" then for n in pairs(sh.vars) do add(n) end
        elseif act == "export" then for n in pairs(sh.vars) do if os.getenv(n) ~= nil then add(n) end end
        elseif act == "setopt" then for _, e in ipairs(SETOPTS) do add(e[1]) end
        elseif act == "shopt" then for _, n in ipairs(SHOPT_ORDER) do add(n) end
        elseif act == "helptopic" then
          for n in pairs(BUILTINS) do add(n) end; for n in pairs(KEYWORDS) do add(n) end
        elseif act == "file" or act == "directory" then
          local matches = rt.glob_expand((prefix or "") .. "*", { dotglob = false }) or {}
          for _, m in ipairs(matches) do if act == "file" or file_test("-d", m) then add(m) end end
        elseif act == "command" then -- aliases, keywords, builtins, functions (+ PATH externals)
          for n in pairs(BUILTINS) do add(n) end; for n in pairs(sh.functions) do add(n) end
          for n in pairs(sh.aliases) do add(n) end; for n in pairs(KEYWORDS) do add(n) end
        end
      end
      table.sort(acc)
      for _, n in ipairs(acc) do emit(n) end
      if xfilter and xfilter ~= "" then -- -X PAT removes matches; -X !PAT keeps only matches
        local neg = xfilter:sub(1, 1) == "!"
        local pat = neg and xfilter:sub(2) or xfilter
        local kept = {}
        for _, x in ipairs(out) do
          local m = rt.glob_match(x, pat)
          if (neg and m) or (not neg and not m) then kept[#kept + 1] = x end
        end
        out = kept
      end
      for _, x in ipairs(out) do sh:echo(cpre .. x .. csuf) end
      sh.status = (#out > 0) and 0 or 1
    end
  elseif cmd == "complete" then
    -- complete [-p] [opts] [name…]: store/print completion specs (registration only)
    if args[2] == nil or args[2] == "-p" then
      local ns = {}; for n in pairs(sh.complete or {}) do ns[#ns + 1] = n end; table.sort(ns)
      for _, n in ipairs(ns) do sh:echo(sh.complete[n] .. " " .. n) end
      sh.status = 0
    else
      -- split trailing NAMEs from the option part; -F/-C etc. with no name is a
      -- usage error UNLESS -D/-E/-I (default/empty/initial-word) is given.
      local opts, cmds, catchall = { "complete" }, {}, false
      local k = 2
      while args[k] do
        local a = args[k]
        if a == "-F" or a == "-C" or a == "-W" or a == "-A" or a == "-o" or a == "-P" or a == "-S" or a == "-X" or a == "-G" then
          opts[#opts + 1] = a; opts[#opts + 1] = sq(args[k + 1] or ""); k = k + 2
        elseif a == "-D" or a == "-E" or a == "-I" then catchall = true; opts[#opts + 1] = a; k = k + 1
        elseif a:sub(1, 1) == "-" then opts[#opts + 1] = a; k = k + 1
        else cmds[#cmds + 1] = a; k = k + 1 end
      end
      if #cmds == 0 and not catchall then io.stderr:write("curse: complete: usage error\n"); sh.status = 2
      else
        sh.complete = sh.complete or {}
        for _, c in ipairs(cmds) do sh.complete[c] = table.concat(opts, " ") end
        sh.status = 0
      end
    end
  elseif cmd == "compopt" then
    -- only valid inside a completion function; we don't run those, so: usage-error
    -- on a bad -o value (2), else "not in completion function" (1).
    for k = 2, #args do
      if args[k] == "-o" or args[k] == "+o" then
        local v = args[k + 1]
        local OK = { default = 1, nospace = 1, filenames = 1, dirnames = 1, bashdefault = 1, plusdirs = 1, nosort = 1 }
        if not OK[v] then io.stderr:write("curse: compopt: invalid option name\n"); sh.status = 2; return end
      end
    end
    sh.status = 1
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
            res = { opt = oc, arg = "" } -- a no-arg option clears OPTARG
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
  elseif cmd == "printf" then
    -- printf [-v VAR] FMT [ARGS…] — native, bash-compatible.
    if args[2] == "-v" then
      local target = args[3]
      if target == nil then io.stderr:write("curse: printf: -v: option requires an argument\n"); sh.status = 2
      else
        local res, st = sh_printf(args[4] or "", args, 5)
        -- target may be NAME or NAME[SUBSCRIPT]
        local nm, sub = target:match("^([%a_][%w_]*)%[(.*)%]$")
        if nm then
          if sub == "" then io.stderr:write("curse: printf: `" .. target .. "': bad array subscript\n"); sh.status = 2
          else sh:array_set(nm, array_key(sh, nm, sub), res, false); sh.status = st end
        elseif target:find("%[") then -- malformed subscript like `a[`
          io.stderr:write("curse: printf: `" .. target .. "': bad array subscript\n"); sh.status = 2
        else sh:set_str(target, res); sh.status = st end
      end
    else
      local fi = 2
      if args[fi] == "--" then fi = fi + 1 end -- end of options
      if args[fi] == nil then
        io.stderr:write("curse: printf: usage: printf [-v var] format [arguments]\n"); sh.status = 2
      else
        local res, st = sh_printf(args[fi], args, fi + 1)
        sh.out(res); sh.status = st
      end
    end
  elseif cmd == "read" then
    -- read [-r] [-a arr] [-p prompt] VAR...  (line from stdin, split on IFS)
    local raw, arr, j, nchars, ndelim, ufd = false, nil, 2, nil, false, 0
    local delim
    while j <= #args do
      local a = args[j]
      if a == "--" then j = j + 1; break
      elseif a:sub(1, 1) == "-" and #a > 1 then
        -- parse a bundle like -rd, -rN 6; an arg-taking flag takes the attached
        -- rest of the word or the next word, and ends the bundle.
        local k, advance = 2, 1
        while k <= #a do
          local f = a:sub(k, k)
          local function takearg()
            local r = a:sub(k + 1)
            if r ~= "" then k = #a + 1; return r else advance = 2; k = #a + 1; return args[j + 1] end
          end
          if f == "r" then raw = true; k = k + 1
          elseif f == "d" then delim = takearg() or "\n"
          elseif f == "n" then nchars = tonumber(takearg())
          elseif f == "N" then nchars = tonumber(takearg()); ndelim = true
          elseif f == "a" then arr = takearg()
          elseif f == "u" then ufd = tonumber(takearg()) or 0
          elseif f == "p" or f == "t" then takearg() -- consume + ignore
          else k = k + 1 end -- -s etc.: ignore
        end
        j = j + advance
      else break end
    end
    local vars = {}
    for k = j, #args do vars[#vars + 1] = args[k] end
    local line, had_nl = nil, true
    -- Read from `ufd` one byte at a time (never over-reading past the terminator),
    -- honoring -r (backslash escaping), -d DELIM, and -n/-N char counts. `dch` is
    -- the record delimiter: the line terminator (\n) unless -d overrode it; -N
    -- ignores the delimiter entirely.
    local dch = delim == nil and "\n" or (delim == "" and "\0" or delim:sub(1, 1))
    do
      local buf, got, esc = {}, false, false
      while true do
        if nchars and #buf >= nchars then had_nl = true; break end -- -n/-N char limit reached
        local c = fd_getc(ufd)
        if c == nil then had_nl = false; break end
        got = true
        if esc then -- backslash-escaped char: keep verbatim (drop the backslash)
          buf[#buf + 1] = c; esc = false
        elseif not raw and c == "\\" then
          -- \<newline> is a line continuation (splice); other \x escapes the char.
          local d = fd_getc(ufd)
          if d == nil then buf[#buf + 1] = "\\"; had_nl = false; break end
          if d == "\n" then -- swallow both (continuation), unless -N counts raw
          else buf[#buf + 1] = d end
        elseif not ndelim and c == dch then had_nl = true; break -- -N ignores the delimiter
        else buf[#buf + 1] = c end
      end
      line = got and table.concat(buf) or nil
    end
    if line == nil then
      sh.status = 1 -- EOF: nothing read
    else
      local ifs = sh.vars["IFS"] and sh:get("IFS") or " \t\n"
      if arr then
        sh:array_assign(arr, rt.ifs_split(ifs, line), false)
      elseif ndelim then -- -N: no IFS processing; first var gets everything, rest empty
        if #vars == 0 then sh:set_str("REPLY", line)
        else sh:set_str(vars[1], line); for k = 2, #vars do sh:set_str(vars[k], "") end end
      elseif #vars == 0 then
        sh:set_str("REPLY", line) -- REPLY: the raw line, no IFS stripping
      else
        local fields = read_split(ifs, line, #vars)
        for k = 1, #vars do sh:set_str(vars[k], fields[k] or "") end
      end
      sh.status = had_nl and 0 or 1
    end
  elseif cmd == "mapfile" or cmd == "readarray" then
    -- mapfile [-t] [-d delim] [ARRAY]: read stdin lines into ARRAY (default MAPFILE)
    local strip, arr, j, dch = false, "MAPFILE", 2, "\n"
    while args[j] do
      local a = args[j]
      if a == "-t" then strip = true; j = j + 1
      elseif a == "-d" then dch = (args[j + 1] or "\n"):sub(1, 1); if dch == "" then dch = "\0" end; j = j + 2
      elseif a == "-n" or a == "-O" or a == "-s" or a == "-u" or a == "-c" or a == "-C" then j = j + 2
      elseif a:sub(1, 1) == "-" and #a > 1 then j = j + 1
      else break end
    end
    if args[j] then arr = args[j] end
    local lines, buf = {}, {}
    while true do
      local c = io.read(1)
      if c == nil then if #buf > 0 then lines[#lines + 1] = table.concat(buf) end break end
      buf[#buf + 1] = c
      if c == dch then lines[#lines + 1] = strip and table.concat(buf):sub(1, -2) or table.concat(buf); buf = {} end
    end
    sh:array_assign(arr, lines, false)
    sh.status = 0
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
    local saved_ld = sh.loopdepth; sh.loopdepth = 0 -- break/continue don't cross into a function
    local ok, err
    if type(fn) == "function" then ok, err = pcall(fn, sh) -- a COMPILED function closure
    else ok, err = pcall(exec_list, sh, fn, hook, false) end -- an interp AST body
    sh.loopdepth = saved_ld
    sh:popCall()
    sh.calldepth = sh.calldepth - 1
    if not ok then
      if type(err) == "table" and err.__curse_return then sh.status = err.__curse_return
      else error(err) end
    end
    -- RETURN trap: fires after the function body returns (in the caller's scope),
    -- preserving the function's exit status.
    local rt_h = sh.traps and sh.traps.RETURN
    if rt_h and rt_h ~= "" and not sh.in_return_trap then
      sh.in_return_trap = true; local saved = sh.status
      run_trap(sh, rt_h); sh.status = saved; sh.in_return_trap = false
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
  if k == "unary" and node.op == "-v" then return var_is_set(sh, expand_word(sh, node.word)) end
  if k == "unary" then return unary(sh, node.op, expand_word(sh, node.word)) end
  if k == "binary" then
    local l, r, op = expand_word(sh, node.l), expand_word(sh, node.r), node.op
    local ic = sh.shopt.nocasematch and true or nil -- shopt -s nocasematch: case-insensitive
    if op == "==" or op == "=" then
      if node.rq and not ic then return l == r else return rt.glob_match(l, expand_pattern(sh, node.r), ic) end
    elseif op == "!=" then
      if node.rq and not ic then return l ~= r else return not rt.glob_match(l, expand_pattern(sh, node.r), ic) end
    elseif op == "=~" then
      -- a quoted part of the regex is matched literally (bash), so re-expand with
      -- regex-escaping of quoted segments instead of using the plain rhs.
      local caps = rt.regex_captures(l, expand_regex(sh, node.r), ic) -- real POSIX ERE + BASH_REMATCH
      sh:array_assign("BASH_REMATCH", caps or {}, false)
      return caps ~= nil
    elseif op == "-eq" or op == "-ne" or op == "-lt" or op == "-le" or op == "-gt" or op == "-ge" then
      -- [[ ]] arithmetic comparisons evaluate each side as an arith EXPRESSION
      -- (bash: [[ 1+2 -eq 3 ]] is true), unlike `test` which needs integer literals.
      local P = require("parser")
      local nl = eval(sh, P.arith(l == "" and "0" or l))
      local nr = eval(sh, P.arith(r == "" and "0" or r))
      if op == "-eq" then return nl == nr elseif op == "-ne" then return nl ~= nr
      elseif op == "-lt" then return nl < nr elseif op == "-le" then return nl <= nr
      elseif op == "-gt" then return nl > nr else return nl >= nr end
    else return binary(l, op, r) end -- < > (string comparisons)
  end
  return false
end

-- Run a loop body, catching break/continue (decrementing multi-level n and
-- re-raising when it targets an outer loop). Returns "break", "continue", or nil.
local function run_loop_body(sh, body, hook)
  local ok, err = pcall(exec_list, sh, body, hook, false)
  if ok then return nil end
  if type(err) == "table" then
    if err.__curse_break then
      if err.__curse_break > 1 then error({ __curse_break = err.__curse_break - 1 }) end
      return "break"
    elseif err.__curse_continue then
      if err.__curse_continue > 1 then error({ __curse_continue = err.__curse_continue - 1 }) end
      return "continue"
    end
  end
  error(err) -- exit/return/real error propagates
end

-- compound commands whose trailing redirs (`done < f`, `fi > f`) apply to the
-- whole construct; handled generically below (simple/group/subshell do their own).
local COMPOUND_REDIR = { whilec = true, forc = true, forin = true, ["if"] = true,
  case = true, arithcmd = true, dbracket = true }
-- DEBUG trap fires just before each of these "command" nodes (bash runs it before
-- every simple/pipeline/arith/[[/assignment); it preserves $? around the handler.
local DEBUG_FIRE = { simple = true, pipeline = true, arithcmd = true, dbracket = true,
  assign = true, assignlist = true }
local function run_debug(sh, line)
  local h = sh.traps and sh.traps.DEBUG
  if not h or h == "" or sh.in_debug then return end
  sh.in_debug = true
  local saved = sh.status
  if line then sh.cur_line = line end
  run_trap(sh, h)
  sh.status = saved; sh.in_debug = false
end

local function exec_stmt(sh, st, hook)
  local t = st.t
  -- set -n (noexec): a non-interactive shell reads but does not execute. Once on,
  -- every later statement (including `set +n`) is skipped — matches bash.
  if sh.opt_n and not sh.opt_i then sh.status = 0; return end
  if DEBUG_FIRE[t] and not (sh.in_trap and sh.in_trap > 0) then run_debug(sh, st.line) end
  -- redirs trailing a compound command: apply around the whole thing, then run it
  -- with redirs temporarily detached (so this guard doesn't re-fire).
  if st.redirs and COMPOUND_REDIR[t] then
    local rd = st.redirs
    local save, ok = apply_redirs(sh, rd)
    if not ok then sh.status = 1; restore_redirs(save); return end
    local savedout = sh.out; sh.out = io.write
    st.redirs = nil
    local pok, err = pcall(exec_stmt, sh, st, hook)
    st.redirs = rd
    io.flush(); sh.out = savedout; restore_redirs(save)
    if not pok then error(err) end
    return
  end
  if st.line and not (sh.in_trap and sh.in_trap > 0) then sh.cur_line = st.line end -- $LINENO (frozen in traps)
  if t == "assign" then
    local rb = sh.vars[sh:deref(st.name)]
    if rb and rb.ro then -- readonly: reject the assignment (status 1). bash exits
      io.stderr:write("curse: " .. st.name .. ": readonly variable\n") -- only in `sh -c` mode; a script keeps going.
      sh.status = 1; if sh.opt_c then error({ __curse_exit = 1 }) end; return
    elseif st.index then
      sh:array_set(st.name, array_key(sh, st.name, st.index), expand_word(sh, st.rhs), st.append)
    elseif st.arith then
      sh:aset(st.name, eval(sh, st.arith))
    elseif st.append then
      local b = sh.vars[sh:deref(st.name)]
      if b and b.int then -- integer var: += is arithmetic addition
        sh:aset(st.name, sh:aget(st.name) + eval(sh, require("parser").arith(expand_word(sh, st.rhs))))
      else
        sh:set_str(st.name, sh:get(st.name) .. expand_word(sh, st.rhs))
      end
    else
      local b = sh.vars[sh:deref(st.name)]
      if b and b.int then -- integer var (declare -i): assign arith-evaluates
        sh:aset(st.name, eval(sh, require("parser").arith(expand_word(sh, st.rhs))))
      elseif b and (b.lower or b.upper) then -- declare -l/-u: case-fold on assign
        local v = expand_word(sh, st.rhs)
        sh:set_str(st.name, b.lower and v:lower() or v:upper())
      else
        sh:set_str(st.name, expand_word(sh, st.rhs))
      end
    end
    -- exit status of an assignment = the last command substitution's, else 0
    -- (skip when it was a rejected readonly assignment, which already set status 1)
    if not (rb and rb.ro) then
      local hascs = false
      if st.rhs then for _, p in ipairs(st.rhs.parts) do if p.cmdsub then hascs = true; break end end end
      if not hascs then sh.status = 0 end
    end
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
    -- word is a defined alias not already expanded (loop guard), splice its parsed
    -- words in and re-dispatch — recursively expanding the new first word too.
    if sh.shopt.expand_aliases and st.words[1] then
      local cw = st.words[1]
      local nm = (#cw.parts == 1 and cw.parts[1].lit ~= nil and not cw.parts[1].q) and cw.parts[1].lit or nil
      local seen = st.alias_seen
      local av = nm and not (seen and seen[nm]) and sh.aliases[nm]
      if av then
        local P = require("parser")
        local parsed = P.parse(av)
        seen = seen or {}; seen[nm] = true
        if parsed.stmts and #parsed.stmts == 1 and parsed.stmts[1].t == "simple" then
          local nw = {}
          for _, w in ipairs(parsed.stmts[1].words) do nw[#nw + 1] = w end
          -- trailing-space chaining: when an alias value ends in a blank, the next
          -- word is also alias-expanded (bash). Keep chaining while that holds.
          local rest, ends_space = 2, av:match("%s$") ~= nil
          while ends_space and st.words[rest] do
            local w2 = st.words[rest]
            local nm2 = (#w2.parts == 1 and w2.parts[1].lit ~= nil and not w2.parts[1].q) and w2.parts[1].lit or nil
            local av2 = nm2 and not seen[nm2] and sh.aliases[nm2]
            if not av2 then break end
            local p2 = P.parse(av2)
            if not (p2.stmts and #p2.stmts == 1 and p2.stmts[1].t == "simple") then break end
            seen[nm2] = true
            for _, w in ipairs(p2.stmts[1].words) do nw[#nw + 1] = w end
            ends_space = av2:match("%s$") ~= nil; rest = rest + 1
          end
          for k = rest, #st.words do nw[#nw + 1] = st.words[k] end
          return exec_stmt(sh, { t = "simple", words = nw, redirs = st.redirs, assigns = st.assigns,
            arrayargs = parsed.stmts[1].arrayargs, alias_seen = seen }, hook)
        elseif parsed.stmts then
          for _, s in ipairs(parsed.stmts) do exec_stmt(sh, s, hook) end
          return
        end
      end
    end
    -- `name=value` arguments to a declaration builtin (export/declare/readonly/
    -- local/typeset) are ASSIGNMENT words: the value isn't word-split or globbed.
    local ASSIGN_CMD = { export = 1, declare = 1, typeset = 1, readonly = 1, ["local"] = 1 }
    local args, is_assign = {}, false
    for wi, w in ipairs(st.words) do
      local p1 = w.parts[1]
      if wi > 1 and is_assign and p1 and p1.lit and p1.lit:match("^[%a_][%w_]*%+?=") then
        args[#args + 1] = expand_word(sh, w) -- assignment word: single field, no glob
      else
        local fs = expand_to_fields(sh, w)
        for k = 1, #fs do args[#args + 1] = fs[k] end
      end
      if wi == 1 then is_assign = ASSIGN_CMD[args[1]] ~= nil end
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
      -- exec [-a name] [--] [cmd…]
      local k, argv0 = 2, nil
      while args[k] == "-a" or args[k] == "--" or (args[k] and args[k]:sub(1, 2) == "-a") do
        if args[k] == "--" then k = k + 1; break
        elseif args[k] == "-a" then argv0 = args[k + 1]; k = k + 2
        else argv0 = args[k]:sub(3); k = k + 1 end
      end
      if k <= #args then
        local rest = { unpack(args, k) }
        if argv0 then rest[0] = argv0 end -- (argv[0] override best-effort)
        exec_simple(sh, rest, hook)
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
    -- $_ : the last argument (after expansion) of the command just run.
    if #args > 0 then sh:set_str("_", args[#args]) end
    -- process substitution cleanup: feed >(cmd) temp files to their commands, then
    -- remove all temp files created for this command's <()/>(). Gated to the outer
    -- level so a nested <()'s own command (run via capture) can't wipe sibling files.
    if (sh.in_subprogram or 0) == 0 and sh.procsub_pending then
      for _, ps in ipairs(sh.procsub_pending) do
        io.flush()
        local q = "'" .. ps.cmd:gsub("'", "'\\''") .. "'"
        os.execute(("sh -c %s < '%s'"):format(q, ps.file))
      end
      sh.procsub_pending = nil
    end
    if (sh.in_subprogram or 0) == 0 and sh.procsub_files then
      for _, f in ipairs(sh.procsub_files) do os.remove(f) end
      sh.procsub_files = nil
    end
  elseif t == "forc" then
    if st.init then eval(sh, st.init) end
    local bodystatus = 0 -- a loop's status is its last body command's (0 if none)
    sh.loopdepth = (sh.loopdepth or 0) + 1
    while true do
      hook("loop", st.id)
      if st.cond and not truth(eval(sh, st.cond)) then break end
      local act = run_loop_body(sh, st.body, hook); bodystatus = sh.status
      if act == "break" then break end
      if st.step then eval(sh, st.step) end -- continue still runs the step
    end
    sh.loopdepth = sh.loopdepth - 1
    sh.status = bodystatus
  elseif t == "whilec" then
    local bodystatus = 0
    sh.loopdepth = (sh.loopdepth or 0) + 1
    while true do
      hook("loop", st.id)
      -- a break/continue in the CONDITION affects this loop too (bash)
      sh.noerr = sh.noerr + 1
      local cok, cerr = pcall(exec_list, sh, st.cond, hook, false)
      sh.noerr = sh.noerr - 1
      if not cok then
        if type(cerr) == "table" and cerr.__curse_break then break
        elseif type(cerr) == "table" and cerr.__curse_continue then -- fallthrough to re-test
        else sh.loopdepth = sh.loopdepth - 1; error(cerr) end
      end
      local go = (sh.status == 0)
      if st.negate then go = not go end -- until
      if not go then break end
      local act = run_loop_body(sh, st.body, hook); bodystatus = sh.status
      if act == "break" then break end
    end
    sh.loopdepth = sh.loopdepth - 1
    sh.status = bodystatus
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
      sh.in_subprogram = (sh.in_subprogram or 0) + 1 -- ERR trap won't fire here (sans errtrace)
      sh.loopdepth = 0 -- a loop enclosing this subshell isn't ours to break/continue
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
      sh.in_subprogram = (sh.in_subprogram or 0) + 1 -- async subprogram: ERR trap won't fire (sans errtrace)
      sh.loopdepth = 0
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
    local fall = false -- carrying a `;&` fall-through into the next clause
    sh.status = 0
    for _, cl in ipairs(st.clauses) do
      local matched = fall
      if not matched then
        for _, pat in ipairs(cl.pats) do
          local g = expand_pattern(sh, P.parse_word(pat)) -- vars resolved; quoted metachars literal
          if rt.glob_match(subj, g, sh.shopt.nocasematch and true or nil) then matched = true; break end
        end
      end
      if matched then
        exec_list(sh, cl.body, hook, false)
        if cl.term == "fall" then fall = true -- ;& : run the next clause's body too
        elseif cl.term == "test" then fall = false -- ;;& : keep testing later patterns
        else break end -- ;; : done
      end
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
    local bodystatus = 0
    sh.loopdepth = (sh.loopdepth or 0) + 1
    while true do
      hook("loop", st.id)
      local fs = sh.forstate[st.id]
      fs.idx = fs.idx + 1
      if fs.idx > #fs.list then break end
      run_debug(sh, st.line) -- DEBUG fires at the `for` header before each iteration
      sh:set_str(st.name, fs.list[fs.idx])
      local act = run_loop_body(sh, st.body, hook); bodystatus = sh.status
      if act == "break" then break end
    end
    sh.loopdepth = sh.loopdepth - 1
    sh.status = bodystatus
  elseif t == "if" then
    local ran = false
    for _, cl in ipairs(st.clauses) do
      local take
      if cl.cond == nil then take = true
      else
        sh.noerr = sh.noerr + 1; exec_list(sh, cl.cond, hook, false); sh.noerr = sh.noerr - 1
        take = (sh.status == 0)
      end
      if take then exec_list(sh, cl.body, hook, false); ran = true; break end
    end
    if not ran then sh.status = 0 end -- no branch taken (no else) -> status 0, like bash
  else
    error("interp: bad stmt " .. tostring(t))
  end
end

M.exec_stmt = exec_stmt -- exposed so the compiled CFG can delegate cold statements

-- Run a trap handler string; preserves $LINENO (so an ERR/EXIT trap sees the
-- failing command's line, not the handler's). Returns true if it called exit.
run_trap = function(sh, code)
  local exited, savedline = false, sh.cur_line
  sh.in_trap = (sh.in_trap or 0) + 1
  local ok, err = pcall(function()
    for _, st in ipairs(require("parser").parse(code).stmts) do exec_stmt(sh, st, function() end) end
  end)
  sh.in_trap = sh.in_trap - 1; sh.cur_line = savedline
  if not ok and type(err) == "table" and err.__curse_exit then sh.status = err.__curse_exit; exited = true end
  return exited
end

exec_list = function(sh, stmts, hook, toplevel)
  for k = 1, #stmts do
    local st = stmts[k]
    if toplevel then hook("stmt", k) end
    exec_stmt(sh, st, hook)
    -- ERR trap + errexit: fire on a failing simple/pipeline outside a condition
    -- (restricted to those two types to avoid &&/|| short-circuit false-positives).
    if sh.noerr == 0 and sh.status ~= 0 and (st.t == "simple" or st.t == "pipeline"
        or st.t == "assign" or st.t == "assignlist") then
      local h = sh.traps and sh.traps.ERR
      -- ERR fires only in the main shell (calldepth 0, not in a subshell/cmdsub/
      -- async), unless errtrace extends it to functions and subprograms.
      local errscope = sh.opt_errtrace or ((sh.calldepth or 0) == 0 and (sh.in_subprogram or 0) == 0)
      if h and h ~= "" and not sh.in_err_trap and errscope then
        sh.in_err_trap = true; local saved = sh.status
        run_trap(sh, h); sh.status = saved; sh.in_err_trap = false
      end
      if sh.opt_e then error({ __curse_exit = sh.status }) end
    end
  end
end
M.exec_list = exec_list

-- Run a trap handler string; returns true if it called exit (which wins).
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

-- Top-level exit/return/EXIT-trap handling for a compiled run: wrap the compiled
-- module's run() so `exit`, nounset, errexit etc. thrown from compiled/delegated
-- code unwind cleanly (setting $?) instead of crashing as an uncaught table.
function M.finish_run(sh, fn) finish(sh, pcall(fn)) end

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
      if sh.noerr == 0 and sh.status ~= 0 and (st.t == "simple" or st.t == "pipeline"
        or st.t == "assign" or st.t == "assignlist") then
        local h = sh.traps and sh.traps.ERR
        if h and h ~= "" and not sh.in_err_trap and (sh.calldepth or 0) == 0 then
          sh.in_err_trap = true; local saved = sh.status
          run_trap(sh, h); sh.status = saved; sh.in_err_trap = false
        end
        if sh.opt_e then error({ __curse_exit = sh.status }) end
      end
    end
  end))
end

return M
