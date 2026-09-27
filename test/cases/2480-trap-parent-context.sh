# A signal the shell sends itself ($$) from an in-process subshell — `( … )`, $(…), one
# inside eval, nested — or from a pipeline stage is the PARENT's: bash (a real child sends
# it, the parent waits) runs the parent's trap once, in the parent, after the child: its
# variable changes stick. curse runs these contexts in-process, so the trap is held until
# the context has ended AND its variables are the parent's again (trap.c's pending_traps:
# several of one signal while held run the trap once). The same in a hot loop (compiled).
n=0
trap 'n=$((n+1))' USR1
( kill -USR1 $$ ); echo "subshell n=$n"
x=$(kill -USR1 $$); echo "comsub n=$n"
eval '( kill -USR1 $$ )'; echo "eval subshell n=$n"
( ( kill -USR1 $$ ) ); echo "nested n=$n"
x=$( ( kill -USR1 $$ ) ); echo "subshell in comsub n=$n"
( x=$(kill -USR1 $$) ); echo "comsub in subshell n=$n"
( kill -USR1 $$; kill -USR1 $$ ); echo "two in one subshell n=$n"
{ kill -USR1 $$; } | cat; echo "stage n=$n"
echo a | { kill -USR1 $$; cat >/dev/null; }; echo "last stage n=$n"
f() { kill -USR1 $$; }; f | cat; echo "function stage n=$n"
m=0
g() { local k; for ((k = 0; k < 200; k++)); do ( kill -USR1 $$ ); x=$(kill -USR1 $$); m=$((m + 2)); done; }
n=0; g; echo "hot: n=$n of $m"
n=0; for ((k = 0; k < 150; k++)); do { kill -USR1 $$; } | cat; done; echo "hot stages: n=$n"
trap - USR1
