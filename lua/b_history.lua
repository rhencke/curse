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
  if cmd == "history" then
    -- history [-c] [-r [file]] [-w [file]] | history : the shell command history.
    sh.history = sh.history or {}
    local a = args[2]
    if a == "-c" then for i = #sh.history, 1, -1 do sh.history[i] = nil end; sh.status = 0
    elseif a == "-r" or a == "-n" then -- read history from FILE (default $HISTFILE)
      -- -r reads the whole file; -n reads only the lines NOT already read (bash
      -- tracks a line offset so a later -n picks up commands appended since).
      local file = args[3] or sh:get("HISTFILE")
      if file and file ~= "" then
        local f = io.open(file, "r")
        if f then
          local lines = {}
          for line in f:lines() do lines[#lines + 1] = line end; f:close()
          local from = (a == "-n") and ((sh.hist_read_lines or 0) + 1) or 1
          for k = from, #lines do sh.history[#sh.history + 1] = lines[k] end
          sh.hist_read_lines = #lines
          sh.status = 0
        else -- a named history file that can't be read is an error (bash)
          io.stderr:write("curse: history: cannot read history file: " .. file .. "\n"); sh.status = 1
        end
      else sh.status = 0 end
    elseif a == "-d" then -- delete the history entry at OFFSET (negative counts from end)
      local off = tonumber(args[3])
      local n = #sh.history
      local idx = off and (off >= 0 and off or n + off + 1)
      if idx and idx >= 1 and idx <= n then table.remove(sh.history, idx); sh.status = 0
      else io.stderr:write("curse: history: " .. tostring(args[3]) .. ": history position out of range\n"); sh.status = 1 end
    elseif a == "-w" or a == "-a" then -- write history to FILE
      local file = args[3] or sh:get("HISTFILE")
      local f = file ~= "" and file and io.open(file, "w")
      if f then for _, h in ipairs(sh.history) do f:write(h, "\n") end; f:close() end
      sh.status = 0
    elseif a == nil then -- list the whole history
      for i = 1, #sh.history do sh:echo(("%5d  %s"):format(i, sh.history[i])) end
      sh.status = 0
    elseif a:sub(1, 1) == "-" then -- an unrecognized `-X` flag (e.g. `history -5`)
      io.stderr:write("curse: history: " .. a .. ": invalid option\n"); sh.status = 2
    elseif args[3] ~= nil then -- too many arguments
      io.stderr:write("curse: history: too many arguments\n"); sh.status = 1
    elseif not tonumber((a:gsub("^%+", ""))) then -- a non-numeric count (`history f`)
      io.stderr:write("curse: history: " .. a .. ": numeric argument required\n"); sh.status = 1
    else -- `history N` / `history +N`: list the last N entries
      local nn = math.abs(tonumber((a:gsub("^%+", ""))))
      for i = math.max(1, #sh.history - nn + 1), #sh.history do sh:echo(("%5d  %s"):format(i, sh.history[i])) end
      sh.status = 0
    end
  end
end
