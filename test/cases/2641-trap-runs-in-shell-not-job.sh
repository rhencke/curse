# A trapped signal sent to the shell ($$) by one of its background jobs runs the SHELL's
# trap, in the shell: its exit/return/break end the shell / its function / its loop, and
# the job that sent it goes on (bash: the job is a child process; the trap is the
# parent's). curse runs jobs in-process as coroutines, so the signal's hook fired inside
# the job — the trap ran there, its `exit` ended the job, and the shell ran on.
S=${THIS_SH:-bash}
# the watchdog: an ALRM from a timer job ends a busy loop
"$S" -c 'trap "echo timed out; exit 124" ALRM; ( sleep 0.2; kill -ALRM $$ ) &
	while (( SECONDS < 5 )); do :; done; echo "finished without timeout"'
echo "watchdog: rc=$?"
# the job goes on after its kill; the shell's trap exits (order between them: sorted)
"$S" -c 'trap "echo in trap; exit 8" TERM; { kill -TERM $$; echo "bg after kill"; } &
	i=0; while (( SECONDS < 5 )); do i=$((i+1)); done; echo "main survived"; exit 3' | sort
echo "bg kill, busy: rc=${PIPESTATUS[0]}"
"$S" -c 'trap "echo in trap; exit 8" TERM; { kill $$; echo "bg after"; } & wait; echo "after wait $?"' | sort
echo "bg kill, wait: rc=${PIPESTATUS[0]}"
"$S" -c 'trap "echo got; exit 7" USR1; (sleep 0.05; kill -USR1 $$; echo sender-after) &
	while (( SECONDS < 5 )); do :; done; echo notreached' | sort
echo "subshell job: rc=${PIPESTATUS[0]}"
# return in the trap returns from the interrupted function; break ends the loop
"$S" -c 'f() { trap "echo in trap; return 7" USR1; { kill -USR1 $$; echo "bg after kill"; } &
	while (( SECONDS < 5 )); do :; done; echo "f survived"; }; f; echo "f status $?"' | sort
"$S" -c 'f() { trap "echo got; return 5" USR1; (sleep 0.1; kill -USR1 $$) & while :; do (( SECONDS < 5 )) || break; done; echo fnot; }
	f; echo "f=$?"'
"$S" -c 'trap "echo got; break" USR1; (sleep 0.1; kill -USR1 $$) &
	while :; do (( SECONDS < 5 )) || break; done; echo "after loop"'
# the trap interrupting `wait` sees (and leaves) the wait's 128+sig
trap 'echo "trap sees $?"' USR1
(sleep 0.05; kill -USR1 $$) & wait; echo "wait: $?"
# the trap runs in the shell: what it sets is the shell's (hot loop: 150 rounds)
n=0
trap 'n=$((n+1))' USR1
for ((r = 0; r < 150; r++)); do { kill -USR1 $$; } & wait; done
echo "traps run in the shell: $n"
g() { local k; for ((k = 0; k < 150; k++)); do (kill -USR1 $$) & wait; done; }
n=0; g; echo "in a function: $n"
# from eval, from a trap handler, from a sourced file
n=0; eval '{ kill -USR1 $$; } & wait'; echo "eval: $n"
trap 'n=0; { kill -USR1 $$; } & wait' USR2
trap 'n=$((n+1))' USR1
kill -USR2 $$; echo "trap: $n"
f=${TMPDIR:-/tmp}/sig2641.$$
echo 'n=0; { kill -USR1 $$; } & wait; echo "source: $n"' >"$f"
. "$f"
rm -f "$f"
trap - USR1 USR2
