#@ guards: `wait PID`, `wait` and `wait -n` interrupted over and over by a trapped-signal storm from a detached sender (each interruption: status 128+sig), with subshell jobs coming and going — the trapped signal is held while an in-process subshell runs (rt.defer_signal), which is where the held-signal flush race struck even with an arithmetic-only trap: `trap: … attempt to index local 'd'` and SIGSEGV (stress-attack S1). Re-waiting must end (no hang), no Lua error may surface, no job may be left. (Which statuses `wait -n` collects under such a storm is not checked: bash 5.2.21 itself loses some, and answers 127 early.)
#@ timeout: 90
#@ iters: 3
# Properties only (the signals' timing is random): every line printed is a verdict.
H=$STH
n=0; trap 'n=$((n+1))' USR1
"$H" hammer $$ 10 3000 50 300 "$HOME/s1"
for r in 1 2 3 4 5 6; do
	sleep 0.3 & p=$!; (exit 7) & q=$!
	k=0; while wait $p; [ $? -ge 128 ] && ((k++ < 400)); do :; done
	k=0; while wait $q; [ $? -ge 128 ] && ((k++ < 400)); do :; done
	(sleep 0.2; exit 3) & (sleep 0.45; exit 4) &
	k=0; while ((k++ < 400)); do wait -n; [ $? = 127 ] && break; done
	k=0; while ((k++ < 400)); do wait; [ $? -ge 128 ] || break; done
done
until [ -e "$HOME/s1" ]; do wait; sleep 0.05; done
trap - USR1
echo "rounds done"
echo "traps ran: $([ $n -ge 1 ] && [ $n -le $(cat "$HOME/s1") ] && echo ok || echo bad)"
rm -f "$HOME/s1"
"$STH" probe
