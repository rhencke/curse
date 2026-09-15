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
  if cmd == "mapfile" or cmd == "readarray" then
    -- mapfile [-t] [-d delim] [ARRAY]: read stdin lines into ARRAY (default MAPFILE)
    local strip, arr, j, dch = false, "MAPFILE", 2, "\n"
    local nmax, origin, skip = nil, nil, 0
    while args[j] do
      local a = args[j]
      if a == "-t" then strip = true; j = j + 1
      elseif a == "-d" then dch = (args[j + 1] or "\n"):sub(1, 1); if dch == "" then dch = "\0" end; j = j + 2
      elseif a == "-n" then nmax = tonumber(args[j + 1]) or 0; j = j + 2 -- read at most N
      elseif a == "-O" then origin = tonumber(args[j + 1]) or 0; j = j + 2 -- store from index N (keep the rest)
      elseif a == "-s" then skip = tonumber(args[j + 1]) or 0; j = j + 2 -- discard the first N
      elseif a == "-u" or a == "-c" or a == "-C" then j = j + 2
      elseif a:sub(1, 1) == "-" and #a > 1 then j = j + 1
      else break end
    end
    if args[j] then arr = args[j] end
    local all, buf = {}, {}
    while true do
      local c = io.read(1)
      if c == nil then if #buf > 0 then all[#all + 1] = table.concat(buf) end break end
      buf[#buf + 1] = c
      if c == dch then all[#all + 1] = strip and table.concat(buf):sub(1, -2) or table.concat(buf); buf = {} end
    end
    -- -s skips leading items; -n caps the count taken after the skip.
    local lines = {}
    for k = skip + 1, #all do
      if nmax and nmax > 0 and #lines >= nmax then break end
      lines[#lines + 1] = all[k]
    end
    if origin then -- -O: overwrite from `origin`, leaving earlier elements intact
      for k, ln in ipairs(lines) do sh:array_set(arr, origin + k - 1, ln, false) end
    else
      sh:array_assign(arr, lines, false)
    end
    sh.status = 0
  end
end
