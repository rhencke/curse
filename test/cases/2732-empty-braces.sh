# `${}` is a bad substitution wherever it is — alone, beside other text (`${}a`, `a${}b`,
# quoted or not), in an assignment or an operand: the message names the whole word
# (fuzz F33). curse expanded it to nothing.
eval 'echo "${}"'; echo "a $?"
eval 'echo ${}a'; echo "b $?"
eval 'echo "a${}b"'; echo "c $?"
eval 'x=${}'; echo "d $?"
eval 'echo ${x:-${}}'; echo "e $?"
x=; echo "[${x:+${}}]" "[${x-${}}]"
f() { eval 'echo ${}'; echo "function $?"; }; f
printf 'echo "${}" x\necho after\n' > s2732.sh; . ./s2732.sh; echo "source $?"
trap 'eval "echo \${}"; echo "trap $?"' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do (eval 'echo ${}z'); echo "st $?"; i=$((i + 1)); done 2>&1 | sort | uniq -c
rm -f s2732.sh
