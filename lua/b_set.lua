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
local opt_on, set_opt, SETFLAG, SETOPT = I.opt_on, I.set_opt, I.SETFLAG, I.SETOPT

return function(sh, cmd, args, hook, tcb)
  if cmd == "set" then
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
    -- `force` (only `--`) replaces the positional params even when none follow; a
    -- lone `-`/`+` merely stops option processing, so `set + -` leaves them alone.
    local j, force = 2, false
    while j <= #args do
      local a = args[j]
      if a == "--" then force = true; j = j + 1; break
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
      elseif a == "-" then -- bare `-`: turn off -v/-x and STOP option processing; any
        -- remaining args become params, but with none the params are left unchanged.
        set_opt(sh, "opt_v", false); set_opt(sh, "opt_x", false); j = j + 1; break
      elseif a == "+" then j = j + 1 -- bare `+`: an ignored no-op flag; keep scanning
      elseif a:match("^[-+][a-zA-Z]+$") then -- short flag bundle: -eu, +u, …
        local on = a:sub(1, 1) == "-"
        for f in a:sub(2):gmatch(".") do
          if SETFLAG[f] then set_opt(sh, SETFLAG[f], on) end
        end
        j = j + 1
      else break end
    end
    if force or j <= #args then
      local np, n = {}, 0
      for k = j, #args do n = n + 1; np[n] = args[k] end
      sh.params = np; sh.nparams = n
    end
    sh.status = 0
  end
end
