# Brace expansion has no size limit in bash: every word is produced, when the command
# runs (a huge one in code that never runs costs nothing). curse capped an expansion at
# 100000 words and silently dropped the rest (stress-attack S9, SILENT DATA LOSS).
echo {1..100001} | wc -w
set -- {1..150000}; echo "$# ${!#}"
a=({a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}); echo "${#a[@]} ${a[-1]}"
echo x{1..400}y{1..400} | wc -w
n=0; for w in {1..120000}; do n=$((n + 1)); done; echo "for-in $n $w"
printf '%s\n' {1..300000} | tail -n 1
x=$(echo {1..300000}); echo "${#x}"
if false; then echo {1..900000000}; fi; echo "dead code: nothing expanded"
set +B; set -- {1..150000}; echo "set +B: $# $1"; set -B
f() { set -- {0..200000}; echo "function: $# $1 ${!#}"; }; f
declare -f f | grep -F '{0..200000}'
eval 'set -- {a,b}{1..60000}; echo "eval: $# ${!#}"'
trap 'set -- {1..110000}; echo "trap: $#"' USR1
kill -USR1 $$
b=([7]=k {1..100001}); echo "array: ${#a[@]} ${b[-1]}"
t=0
for ((i = 0; i < 150; i++)); do set -- {0..100000}; t=$((t + $#)); done
echo "loop total $t last ${!#}"
if false; then c=({1..900000000}); d=([1]=x{1..900000000}); fi; echo "dead array literal: nothing expanded"
c=(p {1..100001} q); echo "array literal: ${#c[@]} ${c[100001]} ${c[-1]}"
d=([3]=k{1..100001}); echo "keyed, de-keyed: ${#d[@]} ${d[-1]}"
declare -A h=([k]=v{1..100001}); echo "assoc keeps it: ${h[k]}"
