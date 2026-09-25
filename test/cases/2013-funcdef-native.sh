# Function definitions compiled as closures registered when the definition runs:
# redirected, redefined, builtin-named and nested definitions, and their calls.
f() { echo "in f $1"; } >&2
f a 2>/dev/null
f b 2>&1
g() { echo g1; }
g
g() { echo g2 "$@"; return 3; }
g x; echo "st=$?"
outer() { inner() { echo "inner $1"; }; inner o; }
outer
inner again
x=0
cnt() { x=$((x+1)); }
true && h() { echo h; }
h
for i in 1 2 3; do cnt; done
echo "x=$x"
declare -f f g inner
k() { local v=$1; if [ "$v" -gt 0 ]; then k $((v-1)); fi; echo "k$v"; } 2>/dev/null
k 2
echo() { builtin echo "E: $*"; }
echo hi
unset -f echo
echo bye
tf=$(mktemp)
x=0
g() { x=$((x+1)); }
g() { x=$((x+2)); }
for ((i=0;i<5;i++)); do g; done
echo "x=$x i=$i"
r=$(f2() { echo "f2 $1"; }; f2 in-cs)
echo "$r"
f3() { echo "f3 $x"; } > "$tf"
x=7; f3; cat "$tf"
p() { for j in 1 2 3; do if [ $j = 2 ]; then return 5; fi; done; }
p; echo "p=$?"
p() { while true; do break; done; echo pb; }
p
rm -f "$tf"
q() { local -n qr=$1; qr=set-by-q; }
q() { local -n qr=$1; qr="set twice"; typeset v=3; declare -p v; }
q target; echo "$target"
