# bash expands an arithmetic expression's text whole before parsing it, so a subscript
# whose expansions leave nothing reads `NAME[]`: "NAME[]: bad array subscript" (twice) on a
# read, "`NAME[]': not a valid identifier" on a write — nothing is stored (fuzz F37). curse
# evaluated the empty subscript as 0.
v=(x y); a=
(( v[$a] ? 1 : 2 )); echo "a $?"
x=$(( v[$a] ? 1 : 2 )); echo "b $? $x"
echo $(( v[$a] )) $(( v[${a}] + 1 )) $(( v[$a$a] ))
(( v[$a]=1 )); echo "c $? ${v[*]}"
(( v[$a]++ )); echo "d $? ${v[*]}"
(( v[$a] += 1 )); echo "e $? ${v[*]}"
(( ++v[$a] )); echo "f $? ${v[*]}"
let "v[$a]=3"; echo "g $? ${v[*]}"
b=" "; echo $(( v[$b] )); echo "${v[$a]}"; v[$a]=z; echo "${v[*]}"
declare -A A; (( A[$a]=1 )); echo "h ${!A[*]}"; echo $(( A[$a] ))
k=x; (( A[$k]=5 )); echo "${A[x]}" $(( A[$k] + 1 ))
f() { local e=; (( v[$e] )); echo "function $?"; }; f
eval '(( v[$a] = 2 ))'; echo "eval $? ${v[*]}"
printf '(( v[$a] ))\necho "in $?"\n' > s2736.sh; . ./s2736.sh; echo "source $?"
trap 'echo $(( v[$a] )); echo "trap $?"' USR1; kill -USR1 $$; trap - USR1
w=(3 4); n=0; i=0; while [ $i -lt 150 ]; do (( n += w[$((i % 2))] )); (( n += w[$a] )); i=$((i + 1)); done 2>&1 | sort | uniq -c
rm -f s2736.sh
