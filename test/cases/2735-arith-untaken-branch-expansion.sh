# bash expands every $name in an arithmetic expression before evaluating it, so one in a
# branch that isn't taken (a ternary arm, the right of && / ||), empty or not a number,
# still makes the text a syntax error — `(( 1 ? 0 : $i ))` (fuzz F36). curse evaluated the
# parsed operands lazily and never looked at it.
(( 1 ? 0 : $i )); echo "a $?"
(( 0 ? $i : 1 )); echo "b $?"
(( 1 || $i )); echo "c $?"
(( 0 && $i )); echo "d $?"
x="1+"; (( 1 || $x )); echo "e $?"
i=3; (( 1 || $i )); echo "f $?"; (( 0 && $i )); echo "g $?"; echo $(( 1 ? 2 : $i ))
x="2*3"; echo $(( 0 || $x+1 )) $(( 1 ? $i : $x ))
( echo $(( 1 ? 0 : $j )); echo "not reached" ); echo "sub $?"
f() { local k; (( 1 ? 1 : $k )); echo "function $?"; }; f
eval '(( 1 && 1 || $e ))'; echo "eval $?"
printf '(( 1 ? 1 : $s ))\necho "in $?"\n' > s2735.sh; . ./s2735.sh; echo "source $?"
trap '(( 1 || $t )); echo "trap $?"' USR1; kill -USR1 $$; trap - USR1
n=0; i=0; while [ $i -lt 150 ]; do (( i % 2 ? 1 : $u )) || n=$((n + 1)); v=$i; (( 1 || $v )) && n=$((n + 1)); i=$((i + 1)); done 2>&1 | sort | uniq -c
echo "n=$n"
rm -f s2735.sh
