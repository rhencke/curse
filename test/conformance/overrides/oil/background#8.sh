# overrides: #### wait for N parallel jobs and check failure
# oil spec/background.test.sh case 8, made deterministic. Upstream orders the jobs' output
# by `sleep 0.0$i` — 10ms margins — so the expected "1 2 3" before the statuses holds only
# while each job starts within ~10ms of the previous one. Under load it doesn't, for bash
# itself: bash 5.2 beside 8 busy loops printed `1 3 status=3 2 status=2 status=1` in 2 of
# 15 runs (curse, whose fork of a big process starts a job later, more often), and the
# harness scored whichever ordering it drew. Here the jobs hand off through FIFOs instead
# of sleeping: job 1 prints first, then 2, then 3 — the same output, in the same order, for
# the same reason (1 finishes first), but by construction rather than by timing.
# Everything upstream checks is still checked: three jobs run IN PARALLEL (job 3, started
# and waited for first, cannot finish until 1 and 2 have run — a shell that ran them one
# at a time would never finish), `wait PID` returns each job's own exit status in the
# order waited, and errexit toggled around each `wait` doesn't abort on the nonzero ones.

set -o errexit

mkfifo after1 after2

pids=''
for i in 3 2 1; do
  { case $i in 3) read x < after2 ;; 2) read x < after1 ;; esac
    echo $i
    case $i in 1) echo > after1 ;; 2) echo > after2 ;; esac
    exit $i; } &
  pids="$pids $!"
done

for pid in $pids; do
  set +o errexit
  wait $pid
  status=$?
  set -o errexit

  echo status=$status
done
