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
  if cmd == "hash" then
    -- hash [-r] [NAME…] : the command-location cache. bare = list; NAME = look up
    -- and cache; -r = forget all. (bash keeps a cached path until -r, ignoring a
    -- later PATH change — see Shell:resolve_cmd.)
    sh.hashcache = sh.hashcache or {}
    local rflag, names, j = false, {}, 2
    while args[j] and args[j]:sub(1, 1) == "-" and #args[j] > 1 do
      if args[j]:find("r") then rflag = true end
      j = j + 1
    end
    for k = j, #args do names[#names + 1] = args[k] end
    if rflag then for k in pairs(sh.hashcache) do sh.hashcache[k] = nil end end
    if #names > 0 then
      sh.status = 0
      for _, nm in ipairs(names) do
        if not nm:find("/", 1, true) and not sh:resolve_cmd(nm) then
          io.stderr:write("curse: hash: " .. nm .. ": not found\n"); sh.status = 1
        end
      end
    elseif not rflag then -- bare `hash`: print the cache (bash format)
      local ks = {}; for k in pairs(sh.hashcache) do ks[#ks + 1] = k end; table.sort(ks)
      if #ks > 0 then
        sh:echo("hits\tcommand")
        for _, k in ipairs(ks) do sh:echo(("%4d\t%s"):format(sh.hashcache[k].hits, sh.hashcache[k].path)) end
      end
      sh.status = 0
    else sh.status = 0 end
  end
end
