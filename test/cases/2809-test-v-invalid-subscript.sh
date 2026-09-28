# `[[ -v NAME ]]` / `test -v NAME` whose `[` doesn't close at its end (skipsubscript:
# `A["]`) names no variable: false, no error (leftover L10). The [[ -v ]] word was
# expanded already: quotes in its subscript are text (`A[\"0\"]` is an arith error); test's
# subscript still expands.
[[ -v 'A["]' ]]; echo "st $?"; test -v 'A["]'; echo "st $?"; [ -v 'A["]' ]; echo "st $?"
declare -a A=(1); [[ -v 'A["]' ]]; echo "st $?"; test -v 'A["]'; echo "st $?"
declare -A B=([x]=1); [[ -v 'B["]' ]]; echo "st $?"; [[ -v 'B[x]' ]]; echo "st $?"
[[ -v 'A[0]' ]]; echo "st $?"; [[ -v 'A[0]x' ]]; echo "st $?"
a=(1 2); i=1; test -v 'a[$i]'; echo $?; [[ -v a[i] ]]; echo $?; test -v "a[i+1]"; echo $?
[[ -v a[\"1\"] ]]; echo "st $?"
echo next
f() { [[ -v 'C["]' ]]; echo "f $?"; }; f
eval '[[ -v "D[\"]" ]]; echo "eval $?"'
printf '[[ -v '"'"'E["]'"'"' ]]; echo "src $?"\n' > s2809.sh; . ./s2809.sh
trap '[[ -v "F[\"]" ]]; echo "trap $?"' USR1; kill -USR1 $$; trap - USR1
n=0; for ((i = 0; i < 150; i++)); do [[ -v 'A["]' ]] || n=$((n + 1)); test -v "a[i%2]" && n=$((n + 1)); done; echo "$n"
rm -f s2809.sh
