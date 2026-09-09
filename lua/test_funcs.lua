-- Functions: parity across interp / compiled / tiered, and OSR at a top-level
-- loop that CALLS a function (switch happens between calls, calldepth 0; the
-- compiled loop then calls the compiled function each iteration).
package.path = "lua/?.lua;" .. package.path
local T = require("tier")
local function run(src, opts)
  local sh = T.rt.Shell.new(); local buf = {}; sh.out = function(s) buf[#buf + 1] = s end
  opts = opts or {}; opts.sh = sh
  local _, how = T.run(src, opts)
  return (table.concat(buf):gsub("\n", "|"):gsub("|$", "")), how
end
local pass = true
local function ck(d, g, e) local ok = g == e; pass = pass and ok; print(("  %-30s %-16s %s"):format(d, g, ok and "OK" or ("*** want [" .. e .. "]"))) end

print("=== interp vs compiled parity ===")
local scripts = {
  { "positional", 'greet() { echo "hi $1 $2"; }\ngreet a b', "hi a b" },
  { "return $?", 'f() { return 7; }\nf\necho $?', "7" },
  { "local", 'x=out\nf() { local x=in; echo $x; }\nf\necho $x', "in|out" },
  { "func in for-c", 'add() { sum=$((sum+$1)); }\nsum=0\nfor ((i=1;i<=100;i++)); do add $i; done\necho $sum', "5050" },
  { "func in for-in", 'acc() { t=$((t+$1)); }\nt=0\nfor x in 10 20 30; do acc $x; done\necho $t', "60" },
  { "nested calls", 'inc() { echo $(( $1 + 1 )); }\ndbl() { echo $(( $1 * 2 )); }\ninc 4\ndbl 4', "5|8" },
}
for _, s in ipairs(scripts) do
  ck("interp: " .. s[1], (run(s[2], {})), s[3])
  ck("compiled: " .. s[1], (run(s[2], { switch_after = 1 })), s[3])
end

print("=== OSR: top-level loop calling a function ===")
local src = 'add() { sum=$((sum + $1)); }\nsum=0\nfor ((i=1; i<=1000; i++)); do add $i; done\necho $sum'
for _, sw in ipairs({ 0, 50, 500, 900 }) do
  local o = sw == 0 and {} or { switch_after = sw }
  local got, how = run(src, o)
  ck("switch_after=" .. sw .. " (" .. how .. ")", got, "500500")
end

if not pass then os.exit(1) end
print("\nALL function tests pass")
