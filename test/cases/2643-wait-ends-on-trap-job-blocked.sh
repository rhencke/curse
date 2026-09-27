# `wait` for a job that is blocked (reading a FIFO no one writes yet) ends with 128+sig
# when a trapped signal arrives, the trap runs, and the job's status stays collectable
# (bash). In curse the job is a coroutine the scheduler polls for: the signal came
# while the scheduler ran, was held for the shell, and the scheduler must hand back to
# the shell for it — it polled on forever, and `wait` never returned.
trap 'echo "  trap USR1 sees $?"' USR1
f=${TMPDIR:-/tmp}/w2643.$$; rm -f "$f"; mkfifo "$f"
exec 3<>"$f"
for k in 1 2 3; do
	( read -r x <&3; exit 4$k ) &
	j=$!
	/bin/sh -c "sleep 0.2; kill -USR1 $$" &
	wait $j; echo "wait interrupted: st=$?"
	echo go >&3
	wait $j; echo "wait again: st=$?"
	wait
done
exec 3>&-
rm -f "$f"
# (a hot loop of waits on already-ended jobs, around it: 150 rounds)
n=0
for ((r = 0; r < 150; r++)); do (exit 3) & wait $!; n=$((n + $?)); done
echo "n=$n"
eval '( read -r x <&4; exit 7 ) 4< <(sleep 0.4; echo hi) & j=$!; ( /bin/sh -c "sleep 0.1; kill -USR1 $$" & ); wait $j; echo "eval wait: $?"; wait $j; echo "eval again: $?"'
