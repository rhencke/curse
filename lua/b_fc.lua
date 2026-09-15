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
  if cmd == "fc" then
    -- fc -l [-n] [-r] [first] [last]: LIST history (edit/re-exec modes not supported).
    -- The `fc` command is itself the last history entry, so it's excluded from ranges.
    sh.history = sh.history or {}
    local lflag, nflag, rflag, nums = false, false, false, {}
    for j = 2, #args do
      local x = args[j]
      if x:sub(1, 1) == "-" and #x > 1 and x:match("^%-[lnr]+$") then
        if x:find("l") then lflag = true end
        if x:find("n") then nflag = true end
        if x:find("r") then rflag = true end
      else nums[#nums + 1] = x end
    end
    local cur = #sh.history -- index of this `fc` command; ranges cover 1..cur-1
    local function resolve(s, dflt)
      if s == nil then return dflt end
      local v = tonumber(s); if not v then return dflt end
      if v < 0 then v = cur + v end -- negative: offset back from the current command
      return v
    end
    local last_default = cur - 1
    local first = resolve(nums[1], math.max(1, last_default - 15))
    local last = resolve(nums[2], last_default)
    if lflag or true then -- only -l (list) is implemented; treat any fc as a listing
      local step
      if rflag then -- -r lists high->low, regardless of the given order (bash: a
        first, last, step = math.max(first, last), math.min(first, last), -1 -- reversed range isn't "undone"
      else step = (first <= last) and 1 or -1 end -- otherwise follow first->last
      for i = first, last, step do
        if i >= 1 and i <= cur - 1 and sh.history[i] then
          sh:echo((nflag and "" or tostring(i)) .. "\t " .. sh.history[i])
        end
      end
    end
    sh.status = 0
  end
end
