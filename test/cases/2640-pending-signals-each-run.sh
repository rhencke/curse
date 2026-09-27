# Signals that arrive together (before the shell's next safepoint) each run their trap,
# lowest signal number first — bash's run_pending_traps walks pending_traps[] in order.
# curse's C handler used to keep only the LAST signal: of HUP, USR1, USR2 sent back to
# back while a foreground command ran, only one trap ran.
trap 'echo got USR1' USR1
trap 'echo got USR2' USR2
trap 'echo got HUP' HUP
/bin/sh -c 'kill -USR2 $PPID; kill -USR1 $PPID; kill -HUP $PPID; sleep 0.05'
echo end
# every round, in a hot loop (compiled / JIT-traced) of 150 rounds
h=0 u1=0 u2=0 order=ok
trap '[ $u2 = $h ] || order=bad; h=$((h+1))' HUP
trap 'u1=$((u1+1)); [ $u1 = $h ] || order=bad' USR1
trap 'u2=$((u2+1)); [ $u2 = $u1 ] || order=bad' USR2
round() { /bin/sh -c 'kill -USR2 $PPID; kill -HUP $PPID; kill -USR1 $PPID'; }
for ((r = 0; r < 150; r++)); do round; done
echo "rounds: HUP=$h USR1=$u1 USR2=$u2 order=$order"
# from eval, and from a sourced file
eval 'trap "echo eval HUP" HUP; trap "echo eval USR1" USR1; /bin/sh -c "kill -USR1 \$PPID; kill -HUP \$PPID"'
f=${TMPDIR:-/tmp}/sig2640.$$
echo 'trap "echo src USR2" USR2; trap "echo src HUP" HUP; /bin/sh -c "kill -USR2 \$PPID; kill -HUP \$PPID"' >"$f"
. "$f"
rm -f "$f"
echo done
