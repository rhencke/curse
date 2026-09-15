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
  if cmd == "jobs" then
    -- jobs [-p|-l|-r]: list active background jobs (one line each). Refresh done
    -- state non-blockingly first so finished jobs drop off (bash removes them).
    local pflag, lflag = false, false
    for k = 2, #args do local a = args[k]
      if a == "-p" then pflag = true elseif a == "-l" then lflag = true
      elseif a == "-r" or a == "-s" or a == "-n" then -- filters: accept
      elseif a:sub(1, 1) == "-" and #a > 1 then io.stderr:write("curse: jobs: " .. a .. ": invalid option\n"); sh.status = 2; return end
    end
    local sb = ffi.new("int[1]")
    for _, j in ipairs(sh.jobs or {}) do job_reap(sh, j, true) end -- WNOHANG refresh
    local active = {}
    for _, j in ipairs(sh.jobs or {}) do if not j.done then active[#active + 1] = j end end
    for i, j in ipairs(active) do
      local mark = (i == #active) and "+" or (i == #active - 1 and "-" or " ")
      if pflag then sh:echo(tostring(j.pid))
      elseif lflag then sh:echo(("[%d]%s %d Running                 %s &"):format(j.id, mark, j.pid, j.cmd))
      else sh:echo(("[%d]%s  Running                 %s &"):format(j.id, mark, j.cmd)) end
    end
    sh.status = 0
  end
end
