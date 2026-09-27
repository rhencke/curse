#@ guards: trap re-entrancy (a signal arriving while its own or another trap runs is run where bash runs it — bash nests: at the next command boundary INSIDE the running handler — never lost), a trap reset / ignored / replaced while its signal is pending, and trap changes made inside a handler (signal-preemption: one-shot VM hook re-armed during a trap, curse_sig_clearpending)
#@ timeout: 20
echo "-- a trap that signals itself: runs again after it returns, never nested"
depth=0 max=0 runs=0
trap 'depth=$((depth+1)); [ $depth -gt $max ] && max=$depth; runs=$((runs+1)); [ $runs -lt 5 ] && kill -USR1 $$; depth=$((depth-1))' USR1
kill -USR1 $$
echo "runs=$runs max-depth=$max"
echo "-- two traps signalling each other"
a=0 b=0
trap 'a=$((a+1)); [ $a -lt 4 ] && kill -USR2 $$' USR1
trap 'b=$((b+1)); [ $b -lt 4 ] && kill -USR1 $$' USR2
kill -USR1 $$
echo "a=$a b=$b"
echo "-- reset while pending (sent inside another trap, reset before it can run)"
got=0
trap 'got=$((got+1))' USR1
trap 'kill -USR1 $$; trap - USR1; echo "  reset in USR2 trap"' USR2
( trap '' USR1; kill -USR2 $$ ) ; echo "sub st=$? got=$got"
trap 'got=$((got+1))' USR1
trap 'kill -USR1 $$; trap "" USR1; echo "  ignored in USR2 trap"' USR2
kill -USR2 $$; echo "got=$got"
kill -USR1 $$; echo "after ignore got=$got"
echo "-- replaced while pending"
trap 'echo "  old handler"' USR1
trap 'kill -USR1 $$; trap "echo \"  new handler\"" USR1' USR2
kill -USR2 $$
echo "-- trap - inside its own handler, then the signal again (default: dies)"
( trap 'echo "  once"; trap - USR1' USR1; kill -USR1 $BASHPID; kill -USR1 $BASHPID; echo not-reached ); echo "st=$?"
echo "-- a trap running a trap-setting eval and a subshell"
trap 'eval "trap \"echo \\\"  inner TERM\\\"\" TERM"; ( kill -TERM $$ ); echo "  USR1 done"' USR1
kill -USR1 $$
trap - USR1 USR2 TERM
echo "-- many signals while a trap sleeps in an external"
c=0
trap 'c=$((c+1)); sleep 0.05' USR1
for k in 1 2 3 4 5 6; do kill -USR1 $$; done
echo "c=$c (bash: each kill runs the trap before the next command)"
trap - USR1
"$STH" probe
