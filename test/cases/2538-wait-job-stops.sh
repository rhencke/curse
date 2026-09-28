# Job control on: `wait` returns 128+SIGSTOP when the job it waits for STOPS meanwhile
# (wait_for's waitchld runs with WUNTRACED) — `wait %N` at once, a plain `wait` moves on
# and keeps the stopped job. And an async child starts without its parent's jobs
# (execute_in_subshell's without_job_control → delete_all_jobs): `jobs` lists none, %1 is
# no such job — so a job can't stop or kill its siblings through %N.
set -m
d=${TMPDIR:-/tmp}/ws$$; mkdir -p "$d"
stopper() { /bin/sh -c 'while [ ! -s '"$d/$1"' ]; do sleep 0.01; done; sleep 0.1; kill -STOP $(cat '"$d/$1"')' & }
/bin/sh -c 'echo $$ > '"$d"'/p1; exec /bin/sleep 5' &
stopper p1
wait %1; echo "wait %1: $?"
jobs -s | wc -l | tr -d ' '
kill -KILL %1; wait %1 2>/dev/null
/bin/sh -c 'echo $$ > '"$d"'/p2; exec /bin/sleep 5' &
stopper p2
wait; echo "wait: $?"
# (waited for by name: a plain `wait` skips a stopped job, and bash's report of its death then
# came with whichever command its SIGCHLD arrived at — line 22 or 23, run to run)
kill -KILL %?p2 2>/dev/null; wait %?p2 2>/dev/null; wait 2>/dev/null
echo "-- an async child has no jobs"
/bin/sleep 0.3 &
{ echo "[$(jobs)]"; kill %1 2>/dev/null; echo "kill: $?"; wait %1 2>/dev/null; echo "wait: $?"; } &
wait $!
echo "parent's job still runs: $(jobs -r | wc -l | tr -d ' ')"
wait
echo "-- hot: 150 async children"
n=0
/bin/sleep 5 &
for ((i = 0; i < 150; i++)); do
	{ jobs %1 >/dev/null 2>&1 || exit 7; } &
	wait $!; [ $? = 7 ] && n=$((n + 1))
done
echo "saw no jobs: $n"
kill %1; wait 2>/dev/null
rm -rf "$d"
