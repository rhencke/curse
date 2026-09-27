# An arithmetic error from a variable's value in `${v:off}` is labelled with the
# parameter: `v: x+: syntax error…`. The compiled tier read the operand natively and lost
# the label (fuzz F30).
v=x+; echo ${v:v}; echo "a $?"
v=v; echo ${v:v}; echo "b $?"
v=abc; w=1+; echo ${v:w}; echo "c $?"
v=abcdef; i=2; echo ${v:i:i}
echo ${v:1+}; echo "d $?"
echo ${v:0:w}; echo "e $?"
f() { local s=hello k=x+; echo ${s:k}; echo "function $?"; }; f
eval 'k=2*; echo ${v:k}'; echo "eval $?"
printf 'k="("; echo ${v:k:1}\n' > s2726.sh; . ./s2726.sh; echo "source $?"; rm -f s2726.sh
trap 'k=x+; echo ${v:1:k}' USR1; kill -USR1 $$; trap - USR1; echo "trap $?"
n=0; s=abcdefgh; for ((j = 0; j < 150; j++)); do t=${s:j%8:1}; n=$((n + ${#t})); done; echo "hot $n"
q=x+; for ((j = 0; j < 150; j++)); do (: ${s:q}); done 2>&1 | sort | uniq -c
