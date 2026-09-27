# Inside (( )), an array element whose VALUE is not a valid expression (`a[0]` = `x+`)
# fails the command: "((: x+: syntax error…", $? 1, the script goes on, and nothing is
# stored — bash's evaluation stops at the error. The compiled tier's element reads raised
# the error past the command (no `((: `, the script ended) and a flagged read fault let
# later stores through (`(( a++ ))` left 1, `(( c = a, d = 5 ))` set d) (fuzz F14).
a=x+
(( a[0]++ ))
echo "after $? ${a[0]}"
(( a++ ))
echo "after $? $a"
b=(x+ 3)
(( b[0] += 1 ))
echo "after $? ${b[0]}"
(( b[0]-- ))
echo "after $? ${b[0]}"
(( ++b[0] ))
echo "after $? ${b[0]}"
(( c = b[0] + 1 ))
echo "after $? ${c-unset}"
(( c = a, d = 5 ))
echo "after $? ${c-unset} ${d-unset}"
(( e = b[1] * 2 ))
echo "after $? $e"
if (( b[0]++ )); then echo yes; else echo "no $? ${b[0]}"; fi
x=$(( b[1] + 1 )); echo "word $x"
f() { (( b[0] = 2, a[0]++ )); echo "fn $? ${b[0]}"; }; f
eval '(( a[0]++ ))'; echo "eval $?"
trap '(( b[0]++ )); echo "trap $?"' USR1; kill -USR1 $$
n=0; for ((i = 0; i < 150; i++)); do (( b[0]++ )) 2>/dev/null || n=$((n + 1)); (( k[i % 3] += 1 )); done
echo "loop $n ${b[0]} ${k[*]}"
declare -i di=4; (( di = a )); echo "after $? $di"
y=0; (( g = 5, h = g / y )); echo "after $? ${g-unset} ${h-unset}"
