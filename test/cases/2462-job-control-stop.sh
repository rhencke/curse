# Job control (`set -m`): a job stopped by `kill -STOP %N` is Stopped (`jobs`, `jobs -s`,
# not `jobs -r`, no ` &`) and becomes the current job (%+), the one before it %-; `kill -CONT`
# runs it again at once (bash's kill_pid emulates `bg`), `bg` prints `[N]+ cmd &` and
# continues it, `fg` prints the command, continues it and waits; `%N` alone is `fg %N`.
# `wait %N` doesn't hang on a stopped job: 128+SIGSTOP; a plain `wait` skips it. fg/bg take
# no options; a job that has ended "has terminated"; the killed jobs leave the table.
# (Deterministic: each stop is waited for with `jobs -s` in a loop — bash learns of it from
# SIGCHLD — and a job to be stopped then foregrounded can't end before it's stopped: it
# reads a line the shell writes to a fifo only once it is.)
set -m
t=${TMPDIR:-/tmp}/c2462.$$
stopped() { until jobs -s >"$t"; [ -s "$t" ]; do :; done; }
err() { "$@" 2>"$t.e"; echo "$1=$? $(sed 's/^.*line [0-9]*: //' "$t.e")"; }

sleep 30 & sleep 31 & sleep 32 &
echo "-- current/previous"; jobs %+; jobs %-
kill -STOP %2; stopped
echo "-- stopped"; jobs -s
echo "-- running"; jobs -r
echo "-- all"; jobs
kill -CONT %2
echo "-- continued"; jobs
kill -STOP %3; stopped
echo "-- bg"; bg %3; echo "bg=$?"
err bg %3
jobs
kill -STOP %1; stopped
wait %1; echo "wait on a stopped job: $?"
jobs %1
exec 5>&2 2>/dev/null # (the Killed notices: by `wait`, or as the next line is read)
kill -9 %1 %2 %3
wait
:
exec 2>&5 5>&-
echo "-- after wait:"; jobs

echo "-- fg"
mkfifo "$t.f"
exec 4<>"$t.f"
{ read -r x <"$t.f"; echo "job read $x"; exit 3; } &
kill -STOP %1; stopped
echo one >&4
fg %1; echo "fg=$?"
{ read -r x <"$t.f"; echo "job read $x"; exit 4; } &
kill -STOP %1; stopped
echo two >&4
%1; echo "%1=$?"
exec 4>&-
jobs
echo "-- options, dead jobs"
sleep 30 &
err fg -s %1
err bg -x
err fg %2
true &
until ! kill -0 $! 2>/dev/null; do :; done
err fg %2
err bg %2
kill -9 %1; wait 2>/dev/null
rm -f "$t" "$t.e" "$t.f"
