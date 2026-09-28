# A [[ ]] arithmetic operand is evaluated as already-expanded text: each NAME[…] subscript
# runs to its matching `]` (skipsubscript), not the last one — `a[1]+b[2]` is two
# elements, `A[]]` is A[] then a stray `]` (whose error comes before A[] is read) — in
# every tier (leftover L14).
a=(1 2 3); b=(4 5 6)
[[ a[1]+b[2] -eq 8 ]]; echo "st $?"
x='a[1]+b[2]'; [[ $x -eq 8 ]]; echo "st $?"; [[ 8 -eq $x ]]; echo "st $?"
x='a[b[0]-3]'; [[ $x -eq 2 ]]; echo "st $?"
declare -A A; A[']']=5; x='A[]]'; [[ $x -eq 5 ]]; echo "st $?"
A['x],b[1']=3; x='A[x],b[1]'; [[ $x -eq 3 ]]; echo "st $?"; echo $(( x ))
y='A[]+'; [[ $y -eq 0 ]]; echo "st $?"
f() { local x='a[0]*b[1]'; [[ $x == 5 && $x -eq 5 ]]; echo "f $?"; }; f
eval 'x="a[2]-b[0]"; [[ $x -eq -1 ]]; echo "eval $?"'
printf 'x="a[1]+b[2]"; [[ $x -ge 8 ]]; echo "src $?"\n' > s2913.sh; . ./s2913.sh
trap 'x="a[1]+b[2]"; [[ $x -le 8 ]]; echo "trap $?"' USR1; kill -USR1 $$; trap - USR1
n=0; for i in {1..150}; do x="a[i%3]+b[i%3]"; [[ $x -gt 6 ]] && n=$((n + 1)); done; echo "$n"
rm -f s2913.sh
