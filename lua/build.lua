-- Amalgamate curse's runtime modules into ONE precompiled-bytecode bundle, so a
-- fresh process loads it with a single file open and zero source parsing. This is
-- the ~1ms/invocation startup win the benchmarks pointed at: LuaJIT parsing our
-- ~1600 lines of source on every start costs ~1.35ms; loading bytecode is ~0.37ms.
--
-- Bytecode is version/arch-specific, which is fine here: the bundle is REGENERATED
-- by this build for the exact LuaJIT it ships with (producer == consumer), so the
-- fragility that rules bytecode out for a portable cache doesn't apply. Run:
--   luajit lua/build.lua [dist/curse.bc]
local mods = { "runtime", "parser", "emit", "interp", "tier", "cache", "repl" }

-- Wrap each module's source in a package.preload closure. `require("x")` then
-- resolves from memory with no file I/O and no parse. Registration is lazy, so
-- inter-module requires resolve fine regardless of order.
local parts = {}
for _, m in ipairs(mods) do
  local f = assert(io.open("lua/" .. m .. ".lua", "r"))
  local s = f:read("*a"); f:close()
  parts[#parts + 1] = ("package.preload[%q] = function(...)\n%s\nend\n"):format(m, s)
end
local bundle_src = table.concat(parts)

local chunk = assert(loadstring(bundle_src, "=curse.bundle"))
local bc = string.dump(chunk) -- keep debug info: line-accurate tracebacks in our runtime

local dest = arg[1] or "dist/curse.bc"
local dir = dest:match("^(.*)/[^/]+$")
if dir then os.execute("mkdir -p " .. dir) end
local o = assert(io.open(dest, "w")); o:write(bc); o:close()
print(("wrote %s (%d modules, %d bytes bytecode)"):format(dest, #mods, #bc))
