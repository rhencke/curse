# SIGVTALRM's default action ends the shell (bash: "Virtual timer expired", status 154).
# curse uses it as its in-process job time-slice tick, and once a background job had run
# the tick's handler swallowed the script's own VTALRM: the shell went on (stress-attack
# S3). An EXIT trap still runs first (bash catches the terminating signals then).
run() { $THIS_SH -c "$1"; echo "$2: status $?"; }
{
run '( : ) & wait; kill -VTALRM $$; echo survived' "after a finished job"
run '( for ((i = 0; i < 20000; i++)); do :; done ) & sh -c "kill -VTALRM \$PPID"; echo survived' "external, CPU-bound job alive"
run 'trap "echo trapped" VTALRM; trap - VTALRM; ( : ) & wait; kill -VTALRM $$; echo survived' "trap set and reset"
run 'kill -VTALRM $$; echo survived' "no job ever"
run 'f() { ( : ) & wait; }; f; kill -VTALRM $BASHPID; echo survived' "job in a function"
run 'trap "echo exit trap" EXIT; ( : ) & wait; kill -VTALRM $$; echo survived' "with an EXIT trap"
run 'trap "echo caught" VTALRM; ( : ) & wait; kill -VTALRM $$; echo "survived: trapped"' "trapped"
run 'eval "( : ) & wait"; eval "kill -VTALRM \$\$"; echo survived' "eval"
run 'trap "kill -VTALRM \$\$" USR1; ( : ) & wait; kill -USR1 $$; echo survived' "from a trap"
run 'for ((i = 0; i < 150; i++)); do ( : ) & wait; done; kill -VTALRM $$; echo survived' "after 150 jobs"
} 2>&1 | sed -E 's/(line [0-9]+:) +[0-9]+ /\1 PID /'
