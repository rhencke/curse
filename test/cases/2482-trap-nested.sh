# A trapped signal arriving while another trap's handler runs is run INSIDE it, at the
# handler's next command — bash's run_pending_traps nests (running_trap only warns) —
# whether the handler sent it itself with `kill`, from a `( … )`, or an external sent it.
# Not after the handler returns. A trap reset or ignored while its signal is pending
# (sent inside another handler) no longer runs it. Also in a hot loop (compiled).
trap 'echo "  usr2"' USR2
trap 'echo "  start"; /bin/kill -USR2 $$; echo "  mid"' USR1
echo "-- external sender inside a handler"
kill -USR1 $$
/bin/kill -USR1 $$
echo "-- a subshell inside a handler signals the shell"
trap 'echo "  inner TERM"' TERM
trap '( kill -TERM $$ ); echo "  USR1 done"' USR1
kill -USR1 $$
trap 'x=$(kill -TERM $$); echo "  USR1 done (comsub)"' USR1
kill -USR1 $$
echo "-- a trap that signals itself"
depth=0 max=0 runs=0
trap 'depth=$((depth+1)); [ $depth -gt $max ] && max=$depth; runs=$((runs+1)); [ $runs -lt 5 ] && kill -USR1 $$; depth=$((depth-1))' USR1
kill -USR1 $$
echo "runs=$runs max-depth=$max"
echo "-- reset while pending"
got=0
trap 'got=$((got+1))' USR1
trap 'kill -USR1 $$; trap - USR1; echo "  reset in USR2 trap"' USR2
( trap '' USR1; kill -USR2 $$ ) ; echo "sub st=$? got=$got"
trap 'got=$((got+1))' USR1
trap 'kill -USR1 $$; trap "" USR1; echo "  ignored in USR2 trap"' USR2
kill -USR2 $$; echo "got=$got"
kill -USR1 $$; echo "after ignore got=$got"
echo "-- hot"
a=0 b=0 lag=0
trap 'b=$((b+1))' USR2
trap 'a=$((a+1)); ( kill -USR2 $$ ); [ $b = $a ] || lag=$((lag+1))' USR1
f() { local i; for ((i = 0; i < 200; i++)); do kill -USR1 $$; done; }
f; echo "a=$a b=$b lag=$lag"
trap - USR1 USR2 TERM
