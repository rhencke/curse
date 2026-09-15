-- Lazily-loaded builtin feature module (see BUILTIN_LAZY in interp.lua). Its own
-- module -- no grab bags -- so a script loads only the builtin it uses. Internals
-- aliased to interp's names so the branch body is a verbatim copy.
local ffi = require("ffi")
local rt = require("runtime")
local M = require("interp")
local I = M._int
local exec_simple, expand_part_str, tilde_word_initial, file_test, sq = I.exec_simple, I.expand_part_str, I.tilde_word_initial, I.file_test, I.sq
local BUILTINS, KEYWORDS, SETOPTS, SHOPT_ORDER = I.BUILTINS, I.KEYWORDS, I.SETOPTS, I.SHOPT_ORDER
local parse_umask, umask_symbolic = I.parse_umask, I.umask_symbolic
local job_reap, block_sig, canon_sig, sig_order = I.job_reap, I.block_sig, I.canon_sig, I.sig_order
local find_all_in_path, name_type, SIGNUM, NUMSIG = I.find_all_in_path, I.name_type, I.SIGNUM, I.NUMSIG
local array_key, sh_printf, fd_getc, fd_ready, read_split = I.array_key, I.sh_printf, I.fd_getc, I.fd_ready, I.read_split
local do_arrayassign, eval, fmt_decl, fmt_set_var = I.do_arrayassign, I.eval, I.fmt_decl, I.fmt_set_var
local C, P = I.C, I.P


return function(sh, cmd, args, hook, tcb)
  if cmd == "local" then
    -- local [-naA] [+n] NAME[=val]…: shadow the var in this scope, honoring
    -- nameref (-n), indexed (-a) and associative (-A) attributes.
    local nref, assoc, plusn, rest, lok = false, false, false, {}, true
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
    if #rest == 0 and not (nref or assoc or plusn) then
      -- bare `local` / `local -p`: list this frame's local variables (bash format)
      local saved, names = sh.savedstack[sh.pd], {}
      if saved then for nm in pairs(saved) do names[#names + 1] = nm end end
      table.sort(names)
      for _, nm in ipairs(names) do local d = fmt_decl(sh, nm); if d then sh:echo(d) end end
      sh.status = 0
    elseif not (nref or assoc or plusn) then
      for _, a in ipairs(rest) do
        local anm, sub, aop, aval = a:match("^([%a_][%w_]*)%[(.-)%](%+?=)(.*)$")
        if anm then -- local a[i]=v : create the element in a local array
          sh:localVar(anm); sh:array_set(anm, array_key(sh, anm, sub), aval, aop == "+=")
        elseif not (a:match("^[%a_][%w_]*$") or a:match("^[%a_][%w_]*%+?=") or a:find("[", 1, true)) then
          io.stderr:write("curse: local: `" .. a .. "': not a valid identifier\n"); lok = false
        elseif (function() local ln = a:match("^([%a_][%w_]*)"); local lb = ln and sh.vars[sh:deref(ln)]; return lb and lb.ro end)() then
          -- a readonly var can't be localized (bash errors, skips it, continues)
          io.stderr:write("curse: local: " .. a:match("^([%a_][%w_]*)") .. ": readonly variable\n"); lok = false
        else
          sh:localAssign(a)
          if sh.opt_a then local nm = a:match("^([%a_][%w_]*)"); local b = nm and sh.vars[sh:deref(nm)]
            if b and not b.arr then b.exported = true; C.setenv(nm, sh:get(nm), 1) end end
        end
      end
    else
      for _, a in ipairs(rest) do
        local nm, val = a:match("^([%a_][%w_]*)=(.*)$")
        local vname = nm or a
        sh:localVar(vname)
        if nm then
          if nref then
            if not sh:make_nameref(nm, val) then
              io.stderr:write("curse: local: `" .. (val or "") .. "': invalid variable name for name reference\n")
              lok = false
            end
          else if assoc then sh:declare_assoc(nm) end; sh:set_str(nm, val) end
        elseif plusn then sh:unref(vname)
        elseif nref then
          if not sh:make_nameref(vname) then
            io.stderr:write("curse: local: `" .. (sh.vars[vname] and sh.vars[vname].s or "") .. "': invalid variable name for name reference\n")
            lok = false
          end
        elseif assoc then sh:declare_assoc(vname) end
      end
    end
    sh.status = lok and 0 or 1
  end
end
