# A trapped signal interrupting a blocking system call (EINTR: the handler has no
# SA_RESTART) never breaks it: bash runs the trap and resumes — reading a $(…)'s output
# (command_substitute's zread loop), opening a FIFO for a redirection (redir.c's
# redir_open retry), `read` from a FIFO (zread), waiting for a foreground child (waitchld:
# no zombie is left). And a trap for a signal that arrives while a foreground command —
# an external, a pipeline — runs is run after it has finished (the next command boundary),
# not while it runs. Senders are externals whose parent is the shell itself.
t=${TMPDIR:-/tmp}/c2481.$$
mkfifo "$t.f" || exit 1
n=0
trap 'n=$((n+1)); echo "  trap n=$n"' USR1
y=$(/bin/sh -c 'kill -USR1 $PPID; sleep 0.05; echo out'); echo "comsub y=$y"
/bin/sh -c "sleep 0.05; kill -USR1 $$; sleep 0.05; echo go >'$t.f'" &
read x <"$t.f"; echo "fifo open: st=$? x=$x"
wait
exec 3<>"$t.f"
/bin/sh -c "sleep 0.05; kill -USR1 $$; sleep 0.05; echo go >'$t.f'" &
read x <&3; echo "fifo read: st=$? x=$x"
wait
exec 3<&-
/bin/sh -c 'kill -USR1 $PPID; sleep 0.05; echo external'
echo "after external n=$n"
/bin/sh -c 'sleep 0.05; kill -USR1 $PPID; sleep 0.05; echo stage' | cat
echo "after pipeline n=$n"
trap 'n=$((n+1))' USR1
n=0 lost=0
for ((k = 0; k < 150; k++)); do
	y=$(/bin/sh -c 'kill -USR1 $PPID; echo out')
	[ "$y" = out ] || lost=$((lost+1))
done
echo "hot comsubs: n=$n lost=$lost"
z=$(ps -o stat= --ppid $$ | grep -c '^Z'); echo "zombies: $z"
trap - USR1
rm -f "$t.f"
