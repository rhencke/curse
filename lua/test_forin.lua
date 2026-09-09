package.path = "lua/?.lua;" .. package.path
local T = require("tier")
local function run(src, opts)
  local sh = T.rt.Shell.new(); local buf = {}; sh.out = function(s) buf[#buf + 1] = s end
  opts = opts or {}; opts.sh = sh
  local _, how = T.run(src, opts)
  return (table.concat(buf):gsub("\n", "|"):gsub("|$", "")), how
end
local pass = true
local function check(desc, got, expect)
  local ok = got == expect; pass = pass and ok
  print(("  %-34s %-14s %s"):format(desc, got, ok and "OK" or ("*** want [" .. expect .. "]")))
end

print("=== for x in — basics ===")
check("literals",        (run("for x in a b c; do echo $x; done")),        "a|b|c")
check("arith body sum",  (run("sum=0\nfor x in 1 2 3 4 5; do sum=$((sum + x)); done\necho $sum")), "15")
check("split $var",      (run('list="10 20 30"\nsum=0\nfor x in $list; do sum=$((sum+x)); done\necho $sum')), "60")

print("=== for x in — OSR mid-loop (must resume same list+index) ===")
local src = "sum=0\nfor x in 2 4 6 8 10 12 14 16 18 20; do sum=$((sum + x)); done\necho $sum"
for _, sw in ipairs({ 0, 1, 3, 6, 9 }) do
  local o = sw == 0 and {} or { switch_after = sw }
  local got, how = run(src, o)
  check("switch_after=" .. sw .. " (" .. how .. ")", got, "110")
end

print("=== for x in outer + for(( )) inner — OSR mid-inner ===")
local src2 = "sum=0\nfor x in 2 3 5 7; do\n  for ((i=1;i<=1000;i++)); do sum=$((sum + x)); done\ndone\necho $sum"
for _, sw in ipairs({ 0, 500, 2500, 3900 }) do
  local o = sw == 0 and {} or { switch_after = sw }
  local got, how = run(src2, o)
  check("switch_after=" .. sw .. " (" .. how .. ")", got, "17000")
end

if not pass then os.exit(1) end
print("\nALL forin tests pass")
