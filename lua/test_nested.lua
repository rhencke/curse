-- Proves OSR into a NESTED (inner) loop: switch deep inside the inner loop and
-- the compiled CFG resumes at the inner cond pc, finishes the inner loop, then
-- the outer step/cond/... — the full continuation, reconstructed by pc flow.
package.path = "lua/?.lua;" .. package.path
local T = require("tier")
local NI, NJ = 200, 300
local src = ([[
sum=0
for ((i=1; i<=%d; i++)); do
  for ((j=1; j<=%d; j++)); do
    sum=$((sum + i * j))
  done
done
echo $sum
]]):format(NI, NJ)
local expect = tostring(math.floor(NI * (NI + 1) / 2) * math.floor(NJ * (NJ + 1) / 2))

local function run(opts)
  opts = opts or {}
  local sh = T.rt.Shell.new(); local buf = {}; sh.out = function(s) buf[#buf + 1] = s end
  opts.sh = sh
  local _, how = T.run(src, opts)
  return (table.concat(buf):gsub("\n", "")), how
end

print("expect " .. expect .. " (nested " .. NI .. "x" .. NJ .. " = " .. (NI * NJ) .. " inner iters)")
local cases = {
  { "pure interpreter",            {} },
  { "switch @ inner iter ~500",    { switch_after = 500 } },
  { "switch @ inner iter ~5000",   { switch_after = 5000 } },
  { "switch @ inner iter ~30000",  { switch_after = 30000 } },
  { "switch @ inner iter ~59000",  { switch_after = 59000 } },
}
local allok = true
for _, c in ipairs(cases) do
  local got, how = run(c[2])
  local ok = got == expect
  allok = allok and ok
  print(("  %-28s %-15s %-12s %s"):format(c[1], how, got, ok and "OK" or "*** MISMATCH ***"))
end
if not allok then os.exit(1) end
print("ALL MATCH — mid-inner-loop OSR works")
