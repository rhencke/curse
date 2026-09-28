# SIGTERM to a shell that runs a subshell or $(…) which doesn't end: bash's parent dies of
# it at once (its EXIT trap first) — the subshell or not. curse, whose subshell runs
# in-process, held the signal until the subshell ended: for good (through the daemon the
# request never ended, a hang of the conformance harness) (stress-attack S23). Each
# subshell spins until its parent is gone (bash's then ends too: no orphan); each run is
# under a KILL-timeout.
t() {
	timeout -s KILL 10 $THIS_SH -c "$1" & p=$!
	sleep 1
	kill -TERM $p
	wait $p
	echo "status $?"
}
t 'trap "echo bye" EXIT; ( while kill -0 $$; do :; done ); echo not reached'
t 'x=$(while kill -0 $$; do :; done); echo not reached'
t 'f() { ( while kill -0 $$; do :; done ); }; f; echo not reached'
t 'trap "echo bye" EXIT; eval "( while kill -0 \$\$; do :; done )"; echo not reached'
