# `${!$}`: `$` names no variable to indirect through — bash's bad substitution (the
# command fails; at the top level the script goes on only in eval/a function's caller).
# curse once expanded the indirection through $$ (fuzz F24; fixed with F8's `$$` scan).
f() { echo "${!$}"; echo "f $?"; }
f; echo "after f $?"
eval 'echo ${!$}'; echo "eval $?"
printf 'echo ${!$}\necho "not reached"\n' > s2720.sh; (. ./s2720.sh); echo "source $?"; rm -f s2720.sh
trap 'echo ${!$}' USR1; kill -USR1 $$; trap - USR1; echo "trap $?"
x=$(echo ${!$:-d}); echo "cmdsub $?"
(echo ${!$#x}); echo "subshell $?"
n=0; for ((i = 0; i < 150; i++)); do (echo ${!$}) 2>/dev/null || n=$((n + 1)); done; echo "hot $n"
echo ${!$}; echo "not reached $?"
