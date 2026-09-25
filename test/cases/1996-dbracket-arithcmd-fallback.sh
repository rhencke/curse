# [[ ]] with operands emit cannot render (element reads with $(…) subscripts, unquoted
# arithmetic operands taken as $((…)) text), a nested =~ leaf (BASH_REMATCH, status 2 on a
# bad regex), (( )) the arith codegen does not render (rt.arithcmd), and element
# subscripts naming a lifted loop variable (flushed to sh before the runtime reads them).
declare -A A=([Darwin]=dj [k]=v)
a=(x y z)
[[ ${A[$(echo Darwin)]} == dj ]] && echo e1
[[ ${a[$(echo 1)]} == y && -n ${A[$(echo k)]} ]] && echo e2
[[ abc == ${a[$(echo 0)]:-a}* ]] || echo e3
[[ x == ${a[$(echo 0)]} ]] && echo e4
[[ foo123 =~ ([a-z]+)([0-9]+) && ${BASH_REMATCH[2]} == 123 ]] && echo "re ${BASH_REMATCH[1]}"
[[ x == y || ab =~ ^(a)(b)$ ]] && echo "re2 ${BASH_REMATCH[*]}"
re="("; [[ x == x && a =~ $re ]]; echo "bad=$?"
[[ ! a =~ b ]] && echo neg
i=0; while [[ $i -lt 3 && ${a[$(echo $i)]} != z ]]; do echo "w$i"; i=$((i+1)); done
a=(1 2 3); declare -A m
(( a[1] += 5, m[x]++ , m[x]++ )); echo "${a[@]} ${m[x]} $?"
i=0; while (( i < 3 )); do (( a[i]++ )); (( i++ )); done; echo "${a[@]} i=$i"
(( 4 + )); echo st=$?
(( x = 1 / 0 )); echo st=$?
f() { local n=5; (( n = ${#a[@]} * n )); echo n=$n; }; f
(( b = (c=2) + (d=3) )); echo $b $c $d
(( '3' )); echo q=$?
j=0; for k in 1 2 3; do (( j += k, a[k] = j )); done; echo "j=$j ${a[*]}"
(( 0 )); echo z=$?
a=(x y z)
for ((i=0;i<3;i++)); do echo ${a[i]} $((a[i])); done
i=0; while (( i < 3 )); do echo "${a[i+0]}"; i=$((i+1)); done
key4='7<(4+2)'; declare -a index=([6]=1); declare -A assoc=([0]=5)
[[ index[7<(4+2)] -le assoc[0] ]]; echo $?
[[ index[$key4] -le assoc[0] ]]; echo $?
