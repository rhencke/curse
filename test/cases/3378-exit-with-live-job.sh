# A shell that exits while a background job still runs exits AT ONCE: the job goes on by
# itself (bash: a separate process). curse's shell waited for its in-process jobs to
# finish before exiting (stress-attack S6) — here each job waits for a file the caller
# creates only after the shell has returned, so it times out instead of seeing it. Now the
# shell forks once at its exit: the parent ends with the status, the child runs the jobs.
t() { # CODE LABEL: the job must see `go`, made after the shell has returned
	rm -f go res
	$THIS_SH -c "$1"
	echo "exit $?"
	: > go
	SECONDS=0; until [ -s res ] || ((SECONDS >= 6)); do sleep 0.05; done
	echo "$2: $(cat res)"
	rm -f go res
}
job='( SECONDS=0; until [ -e go ] || ((SECONDS >= 3)); do :; done; [ -e go ] && echo saw-go > res || echo timed-out > res )'
sjob='( SECONDS=0; until [ -e go ] || ((SECONDS >= 3)); do sleep 0.01; done; [ -e go ] && echo saw-go > res || echo timed-out > res )'
t "$job & exit 7" "busy job"
t "$sjob & exit 8" "sleeping job"
t "f() { $job & }; f; exit 9" "job started in a function"
t "eval '$job &'; echo from-the-shell" "eval"
t "trap 'echo exit-trap' EXIT; $job & exit 3" "with an EXIT trap"
t "trap '$job &' USR1; kill -USR1 \$\$; exit 4" "started by a trap"
t "for ((i = 0; i < 150; i++)); do : \$i; done; $job & exit 5" "after a hot loop"
t "$job & $job & wait %1; exit 6" "two jobs, one waited for"
