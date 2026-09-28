# A CPU-time limit a subshell sets counts ITS time (a forked child's clock starts at 0)
# and ends only it: past a soft limit below the hard one SIGXCPU (152, or its own trap
# runs), at the hard one SIGKILL (137) — through a function, eval, a $(…); the limits it
# shows, and the one a program it runs gets, are its own. curse ran it in-process: the
# SIGXCPU killed the whole script (stress-attack S21). Each run is under a KILL-timeout.
run() { timeout -s KILL 8 $THIS_SH -c "$1" 2>&1 | sed -E 's/^.*line [0-9]+: +[0-9]+ /E: /; s/^[^ ]*: line [0-9]+: /sh: line N: /'; echo "status ${PIPESTATUS[0]}"; }
run 'ulimit -c 0; ( ulimit -St 1; while :; do :; done ); echo "soft only: $?"'
run 'f() { ulimit -t 1; while :; do :; done; }; ( f ) 2> /dev/null; echo "function: $?"'
run 'x=$(ulimit -t 1; echo pre; eval "while :; do :; done"); echo "comsub, eval: $? [$x]"'
run '( trap "echo xcpu-trapped; exit 7" XCPU; ulimit -Ht 3; ulimit -St 1; while :; do :; done ); echo "own trap: $?"'
run '( ulimit -t 2; ulimit -t; ulimit -Ht; sh -c "ulimit -t" ); ulimit -t'
