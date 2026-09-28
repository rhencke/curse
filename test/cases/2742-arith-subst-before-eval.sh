# bash substitutes every $name of an arithmetic expression before evaluating any of it:
# with $a empty, `(( (A[-1] || $a) ))` evaluates A[-1] once while parsing the substituted
# text (its "bad array subscript"), then fails on the missing operand — curse evaluated it
# natively first and then again on the textual path (the message twice, or the syntax
# error lost: fuzz F43).
(( (A[-1] || $a) )); echo "a $?"
(( 2#101 < (A[-1] != 1 || $a) )); echo "b $?"
(( A[-1] + $a )); echo "c $?"
( x=$(( A[-1] + $a )); echo "not reached" ); echo "d $?"
a=2; (( (A[-1] || $a) )); echo "e $?"; echo $(( A[-1] + $a ))
a=; f() { (( A[-2] * $a )); echo "function $?"; }; f
eval '(( A[-1] - $a ))'; echo "eval $?"
printf '(( A[-3] || $a ))\necho "in $?"\n' > s2742.sh; . ./s2742.sh; echo "source $?"
trap '(( A[-1] + $a )); echo "trap $?"' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do (( A[-1] + $a )); echo "st $?"; b=$i; (( b = $b + 1 )); i=$((i + 1)); done 2>&1 | sort | uniq -c
rm -f s2742.sh
