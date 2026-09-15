-- Lazily-loaded feature module: rarely-used builtins pulled out of exec_simple's
-- cold path (see BUILTIN_LAZY in interp.lua). Internals aliased to interp's own
-- names so the branch bodies are verbatim copies; require caches, loaded once.
local ffi = require("ffi")
local I = require("interp")._int
local C = I.C
local parse_umask, umask_symbolic = I.parse_umask, I.umask_symbolic
local job_reap, block_sig, canon_sig, sig_order = I.job_reap, I.block_sig, I.canon_sig, I.sig_order
local find_all_in_path, name_type = I.find_all_in_path, I.name_type
local SIGNUM, NUMSIG, BUILTINS, KEYWORDS, P = I.SIGNUM, I.NUMSIG, I.BUILTINS, I.KEYWORDS, I.P

return function(sh, cmd, args, hook, tcb)
  if cmd == "ulimit" then
    -- ulimit [-HSaflags] [limit]: get/set process resource limits (getrlimit/
    -- setrlimit). Reported/accepted in each resource's block unit; `unlimited`.
    local INF = 0xFFFFFFFFFFFFFFFFULL
    local RES = { -- flag -> { resource, bytes-per-unit, label, unit-name }
      t = { 0, 1, "cpu time", "seconds" }, f = { 1, 1024, "file size", "blocks" },
      d = { 2, 1024, "data seg size", "kbytes" }, s = { 3, 1024, "stack size", "kbytes" },
      c = { 4, 512, "core file size", "blocks" }, m = { 5, 1024, "max memory size", "kbytes" },
      l = { 8, 1024, "max locked memory", "kbytes" }, u = { 6, 1, "max user processes", "" },
      n = { 7, 1, "open files", "" }, v = { 9, 1024, "virtual memory", "kbytes" },
      p = { -1, 512, "pipe size", "512 bytes" },
    }
    local AORDER = { "t", "f", "d", "s", "c", "m", "l", "u", "n", "v" }
    local rl = ffi.new("struct curse_rlimit[1]")
    local hardflag, softflag = false, false
    -- GET one resource: -H reads the hard limit (rlim_max), else the soft (rlim_cur).
    local function report(fl)
      local r = RES[fl]; if not r or r[1] < 0 then return "unlimited" end
      if C.getrlimit(r[1], rl) ~= 0 then return nil end
      local v = hardflag and rl[0].rlim_max or rl[0].rlim_cur
      if v == INF then return "unlimited" end
      return (tostring(v / r[2]):gsub("[UuLl]+$", "")) -- drop LuaJIT's cdata "ULL" suffix
    end
    local flags, value = {}, nil
    local j = 2
    while args[j] do
      local a = args[j]
      if a == "--" then j = j + 1; break
      elseif a == "-a" or a == "--all" then flags = { "t", "f", "d", "s", "c", "m", "l", "u", "n", "v", "@all" }; j = j + 1
      elseif a:sub(1, 1) == "-" and #a > 1 then
        for k = 2, #a do local f = a:sub(k, k)
          if f == "H" then hardflag = true elseif f == "S" then softflag = true
          elseif RES[f] then flags[#flags + 1] = f
          else io.stderr:write("curse: ulimit: -" .. f .. ": invalid option\n"); sh.status = 2; return end
        end
        j = j + 1
      else break end
    end
    value = args[j] -- a trailing value; any further args are ignored (bash)
    if #flags == 0 then flags = { "f" } end -- default resource is -f
    local allmode = flags[#flags] == "@all"
    if allmode then flags[#flags] = nil end
    if allmode then value = nil end -- `ulimit -a` ignores a trailing value (bash prints all, status 0)
    if value ~= nil then -- SET each named resource
      -- with neither -S nor -H, bash sets BOTH; -S sets soft, -H sets hard.
      local setsoft, sethard = softflag or not hardflag, hardflag or not softflag
      sh.status = 0
      for _, fl in ipairs(flags) do
        local r = RES[fl]
        local nv
        if value == "unlimited" then nv = INF
        elseif value:match("^%d+$") then
          local num = tonumber(value)
          if num == nil or num * r[2] > 9223372036854775807 then sh.status = 0; return end -- overflow: bash leaves it
          nv = ffi.cast("uint64_t", num) * ffi.cast("uint64_t", r[2])
        else io.stderr:write("curse: ulimit: " .. value .. ": invalid number\n"); sh.status = 1; return end
        if r[1] < 0 or C.getrlimit(r[1], rl) ~= 0 then sh.status = 1
        else
          if setsoft then rl[0].rlim_cur = nv end
          if sethard then rl[0].rlim_max = nv end
          if C.setrlimit(r[1], rl) ~= 0 then sh.status = 1; io.stderr:write("curse: ulimit: cannot modify limit\n") end
        end
      end
    elseif allmode then -- -a: list all
      for _, fl in ipairs(AORDER) do
        local r = RES[fl]; local v = report(fl) or "unlimited"
        sh:echo(("%-24s(%s, -%s) %s"):format(r[3], r[4], fl, v))
      end
      sh.status = 0
    else -- print one or more resources
      sh.status = 0
      for _, fl in ipairs(flags) do
        local v = report(fl)
        if #flags > 1 then sh:echo(("%-24s(-%s) %s"):format(RES[fl][3], fl, v or "unlimited"))
        else sh:echo(v or "unlimited") end
      end
    end
  elseif cmd == "times" then
    -- Two lines: shell user/sys, then children user/sys, each `%dm%.3fs`.
    local function ct(s) return ("%dm%.3fs"):format(math.floor(s / 60), s % 60) end
    local c = os.clock()
    sh:echo(ct(c) .. " " .. ct(0))
    sh:echo(ct(0) .. " " .. ct(0))
    sh.status = 0
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
  elseif cmd == "umask" then
    -- umask [-S] [MODE]: print (octal or -S symbolic) or set the file-creation mask.
    local sflag, pflag, badflag, pos = false, false, false, {}
    for j = 2, #args do
      local a = args[j]
      if a == "-S" then sflag = true
      elseif a == "-p" then pflag = true -- print in a form that can be eval'd
      elseif a:sub(1, 1) == "-" and #a > 1 then badflag = true
      else pos[#pos + 1] = a end
    end
    local cur = tonumber(C.umask(0)) % 512; C.umask(cur)
    if badflag then io.stderr:write("curse: umask: invalid option\n"); sh.status = 1
    elseif #pos == 0 then -- bash ignores extra args; it uses only the first MODE
      local body = sflag and umask_symbolic(cur) or string.format("%04o", cur)
      sh:echo(pflag and ("umask " .. (sflag and "-S " or "") .. body) or body); sh.status = 0
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
    -- A leftover OPTIND pointing past a now-shorter argument list (e.g. after a
    -- fresh `set --`) is exhausted: bash returns EOF and clamps OPTIND to
    -- nargs+1 (getopt.c: `sh_optind >= argc` -> `sh_optind = argc`, argc =
    -- nparams+1). It does NOT rescan from 1 — only an explicit OPTIND= does.
    if optind > src_n + 1 then optind = src_n + 1; cur = 1 end
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
            res = { opt = oc, clr = true } -- a no-arg option UNSETS OPTARG (bash)
          end
        end
      end
    end
    sh.getopts_cur = cur
    sh:set_str("OPTIND", tostring(optind))
    local valid = vname:match("^[%a_][%w_]*$") -- an invalid NAME -> status 1, var not set
    if res.done then
      if valid then sh:set_str(vname, "?") end
      sh.getopts_cur = 1; sh.vars["OPTARG"] = nil; sh.status = 1 -- end of options: OPTARG unset
    else
      if valid then sh:set_str(vname, res.opt) end
      if res.arg ~= nil then sh:set_str("OPTARG", res.arg) elseif res.err or res.clr then sh.vars["OPTARG"] = nil end
      if res.err then io.stderr:write("curse: " .. res.err .. "\n") end
      sh.status = valid and 0 or 1
    end
  elseif cmd == "hash" then
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
  elseif cmd == "history" then
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
  elseif cmd == "jobs" then
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
    elseif args[j]:sub(1, 1) == "-" and args[j] ~= "-" then -- a stray -flag (e.g. `trap -1`)
      io.stderr:write("curse: trap: " .. args[j] .. ": invalid option\n"); sh.status = 2
    else
      -- bash: reset-mode (all tokens are signals to reset) only when the first
      -- token is a NUMERIC signal (`trap 0 2`) or the sole arg and a valid signal
      -- (`trap TERM`); a NAME first token is the action, even a name that happens
      -- to be a signal (`trap INT EXIT` runs `INT` at EXIT; `trap err ERR`).
      local action, sigstart
      if canon_sig(args[j]) and (#args == j or args[j]:match("^%d+$")) then
        action, sigstart = "-", j
      else action, sigstart = args[j], j + 1 end
      if sigstart > #args then -- an action with no signal spec is a usage error
        io.stderr:write("curse: trap: usage: trap [-lp] [[arg] signal_spec ...]\n"); sh.status = 1; return
      end
      local ok = true
      for k = sigstart, #args do
        local canon = canon_sig(args[k])
        if not canon then io.stderr:write("curse: trap: " .. args[k] .. ": invalid signal specification\n"); ok = false
        elseif action == "-" then sh.traps[canon] = nil
        else sh.traps[canon] = action end
        -- a REAL signal (not EXIT/DEBUG/RETURN/ERR): block it so we can poll it at
        -- safepoints; resetting unblocks it. sh.sigtraps counts active signal traps.
        local num = canon and SIGNUM[canon:match("^SIG(.+)$") or ""]
        if num and num ~= 9 and num ~= 19 then -- KILL/STOP can't be trapped
          local had = sh.sigtraps and sh.sigtraps[canon]
          if action == "-" and had then block_sig(num, false); sh.sigtraps[canon] = nil
          elseif action ~= "-" and not had then
            sh.sigtraps = sh.sigtraps or {}; sh.sigtraps[canon] = true; block_sig(num, true)
          end
        end
      end
      sh.status = ok and 0 or 1
    end
  elseif cmd == "type" then
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
          local d = sh.func_src and sh.func_src[nm]; if d then sh:echo(d) end -- verbatim body (bash prints it)
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
          local d = sh.func_src and sh.func_src[nm]; if d then sh:echo(d) end -- verbatim body (bash prints it)
        elseif k == "keyword" then sh:echo(nm .. " is a shell keyword")
        else sh:echo(nm .. " is a shell builtin") end
      end
    end
    sh.status = allok and 0 or 1
  end
end
