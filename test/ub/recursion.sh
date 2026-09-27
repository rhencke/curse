# docs/bash-ub.md: unbounded function / trap recursion. bash 5.2.21 overflows its C stack
# (SIGSEGV, status 139) or, with a subshell between the signals, nests handlers without
# end; curse's pinned choice: the shell running it stops with "stack overflow", status 1 —
# a subshell, $(…) or job alone (as a crashed child would), the script as a whole.
f() { f; }
( f ) 2>&1 | sed 's/^[^:]*: //'
echo "subshell ${PIPESTATUS[0]}"
{ x=$(f); echo "cmdsub $? [$x]"; } 2>&1 | sed 's/^[^:]*: //'
f 2>/dev/null & wait $!; echo "job $?"
( trap 'kill -USR1 $BASHPID' USR1; kill -USR1 $BASHPID; echo not reached ) 2>&1 | sed 's/^[^:]*: //'
echo "trap ${PIPESTATUS[0]}"
g() { local n=$1; if ((n > 0)); then g $((n - 1)); fi; }; g 150; echo "deep but bounded $?"
trap 'echo "exit trap, status $?"' EXIT
exec 2>/dev/null # (the message names this script's path)
f
echo not reached
