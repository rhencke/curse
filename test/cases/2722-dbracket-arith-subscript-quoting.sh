# An arithmetic operand of [[ ]] expands like $((…)) under Q_ARITH: an unquoted `[` starts a
# subscript whose text (to the matching `]`) is expanded and then backslash-quoted against
# re-evaluation ([ ] $ ` ~ \ ' "), so a bracket expression reaches the evaluator — and its
# error message — as `[\[:a:\]]`. curse kept it as written (fuzz F26). A real subscript in
# such an operand is read to ITS `]` (`arr[0]+arr[1]`, compiled once read to the last one).
[[ 1 -lt [[:a:]] ]]; echo "a $?"
[[ [[:a:]] -lt 1 ]]; echo "b $?"
[[ 1 -lt x[[:a:]] ]]; echo "c $?"
[[ 1 -eq '[[:a:]]' ]]; echo "quoted $?"
a="[[:a:]]"; [[ 1 -lt $a ]]; echo "expanded $?"
[[ 1 -lt [a[:b:]c] ]]; echo "d $?"
[[ 1 -lt [![:a:]] ]]; echo "e $?"
[[ 1 -lt [\[:a:\]] ]]; echo "f $?"
[[ 1 -lt \[[:a:]] ]]; echo "g $?"
[[ 1 -lt [[:a:]]x ]]; echo "h $?"
[[ 1 -lt a[[:a:]]b[[:c:]] ]]; echo "i $?"
[[ 1 -lt [~] ]]; echo "j $?"
arr=(5 6); [[ 1 -lt arr[1] ]]; echo "k $?"
[[ 1 -lt arr[0]+arr[1] ]]; echo "l $?"
[[ arr[0]*2 -eq 10 && 1 -lt arr[1] ]]; echo "m $?"
[[ x == [[:a:]] ]]; echo "pattern $?"
f() { [[ 1 -lt [[:a:]] ]]; }; declare -f f; f; echo "function $?"
eval '[[ 1 -gt [[:x:]] ]]'; echo "eval $?"
printf '[[ 1 -ge [[.a.]] ]]\necho "source $?"\n' > s2722.sh; . ./s2722.sh; rm -f s2722.sh
trap '[[ 1 -le [[=a=]] ]]; echo "trap $?"' USR1; kill -USR1 $$; trap - USR1
n=0; for ((i = 0; i < 150; i++)); do [[ i -lt arr[0]+arr[1] ]] && n=$((n + 1)); done; echo "hot $n"
for ((i = 0; i < 150; i++)); do [[ 1 -lt [[:a:]] ]]; done 2>&1 | sort | uniq -c
