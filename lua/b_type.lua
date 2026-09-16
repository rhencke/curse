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
local func_body_text = I.func_body_text
local C, P = I.C, I.P

return function(sh, cmd, args, hook, tcb)
  if cmd == "type" then
    -- type [-t|-p|-P] NAME…  (-t type word; -p path-if-file; -P force PATH search)
    local tflag, pflag, Pflag, fflag, aflag, j0 = false, false, false, false, false, 2
    while args[j0] and args[j0]:sub(1, 1) == "-" and #args[j0] > 1 do
      local f = args[j0]
      if f:find("t") then tflag = true end
      if f:find("p") then pflag = true end
      if f:find("P") then Pflag = true end
      if f:find("f") then fflag = true end -- -f: suppress shell-function lookup
      if f:find("a") then aflag = true end -- -a: list ALL locations (each PATH file too)
      j0 = j0 + 1
    end
    local allok = true
    for j = j0, #args do
      local nm = args[j]
      if Pflag then -- force PATH search (all files with -a, else the first)
        local ps = find_all_in_path(nm)
        if #ps == 0 then allok = false
        elseif aflag then for _, p in ipairs(ps) do sh:echo(p) end
        else sh:echo(ps[1]) end
      elseif pflag then -- print path(s); status tracks whether the name resolves at all
        if aflag then for _, p in ipairs(find_all_in_path(nm)) do sh:echo(p) end
        else local k, p = name_type(sh, nm, fflag); if k == "file" then sh:echo(p) end end
        if not name_type(sh, nm, fflag) then allok = false end
      elseif tflag then
        local k = name_type(sh, nm, fflag); if k then sh:echo(k) else allok = false end
      elseif aflag then -- every location, in resolution order
        local found = false
        if sh.aliases[nm] then sh:echo(nm .. " is aliased to `" .. sh.aliases[nm] .. "'"); found = true end
        if KEYWORDS[nm] then sh:echo(nm .. " is a shell keyword"); found = true end
        if not fflag and sh.functions[nm] then sh:echo(nm .. " is a function")
          local d = func_body_text(sh, nm); if d then sh:echo(d) end -- canonical (or verbatim) body
          found = true end
        if BUILTINS[nm] then sh:echo(nm .. " is a shell builtin"); found = true end
        for _, p in ipairs(find_all_in_path(nm)) do sh:echo(nm .. " is " .. p); found = true end
        if not found then allok = false; io.stderr:write("curse: type: " .. nm .. ": not found\n") end
      else -- sentence form
        local k, p = name_type(sh, nm, fflag)
        if not k then allok = false; io.stderr:write("curse: type: " .. nm .. ": not found\n")
        elseif k == "alias" then sh:echo(nm .. " is aliased to `" .. sh.aliases[nm] .. "'")
        elseif k == "file" then sh:echo(nm .. " is " .. p)
        elseif k == "function" then sh:echo(nm .. " is a function")
          local d = func_body_text(sh, nm); if d then sh:echo(d) end -- canonical (or verbatim) body
        elseif k == "keyword" then sh:echo(nm .. " is a shell keyword")
        else sh:echo(nm .. " is a shell builtin") end
      end
    end
    sh.status = allok and 0 or 1
  end
end
