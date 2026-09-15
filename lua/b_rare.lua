-- Lazily-loaded feature module: rarely-used builtins pulled out of exec_simple's
-- cold path (see BUILTIN_LAZY in interp.lua). Internals aliased to interp's own
-- names so the branch bodies are verbatim copies; require caches, loaded once.
local ffi = require("ffi")
local I = require("interp")._int
local C = I.C
local parse_umask, umask_symbolic = I.parse_umask, I.umask_symbolic

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
  end
end
