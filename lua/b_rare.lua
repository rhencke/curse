-- Lazily-loaded feature module: rarely-used builtins pulled out of exec_simple's
-- cold path (see BUILTIN_LAZY in interp.lua). Internals aliased to interp's own
-- names so the branch bodies are verbatim copies; require caches, loaded once.
local ffi = require("ffi")
local I = require("interp")._int
local C = I.C

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
  end
end
