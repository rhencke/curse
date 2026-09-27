# `wait %1` and `wait %2` on jobs `kill %1 %2` killed, the order they are reaped in forced:
# bash's `kill %1 %2; wait %1 %2` depends on whether job 2's SIGCHLD lands before wait %1's
# notify_of_job_status (which drops a TERM-killed job silently: "no such job", 127). A
# STOPPED job keeps the TERM pending (no job control: kill_pid sends no CONT) until it is
# continued, so it is still in the table when the other one's wait returns; one that has
# ended and been reaped before the next line is read is dropped by that line's notify.
settle() { while kill -0 "$1" 2>/dev/null; do sleep 0.01; done; /bin/true; }
# (the job's sleep is found by its unique argument: an in-process job's $! is not its pid)
stopped() { until ps -eo stat=,args= | awk -v a="$1" '$2 == "sleep" && $3 == a && $1 ~ /^T/ { f = 1 } END { exit !f }'; do sleep 0.01; done; }
up() { until ps -eo args= | awk -v a="$1" '$1 == "sleep" && $2 == a { f = 1 } END { exit !f }'; do sleep 0.01; done; }
u=$$; n=0
e() { sed 's/^.*line [0-9]*: //'; }
echo "-- job 2 stopped: wait %1 first"
n=$((n + 1)); sleep 5 & sleep 6.$u$n & up 6.$u$n; kill -STOP %2; stopped 6.$u$n
kill %1 %2; wait %1; echo "w1=$?"; jobs %2 | sed 's/  */ /g'; kill -CONT %2; wait %2; echo "w2=$?"
echo "-- job 1 stopped: wait %2 first"
n=$((n + 1)); sleep 5.$u$n & sleep 6 & up 5.$u$n; kill -STOP %1; stopped 5.$u$n
kill %1 %2; wait %2; echo "w2=$?"; kill -CONT %1; wait %1; echo "w1=$?"
echo "-- both reaped and notified first: both gone"
sleep 5 & a=$!; sleep 6 & b=$!; kill %1 %2; settle $a; settle $b
wait %1 %2 2>err; echo "w=$?"; e <err
echo "-- job 2 gone first, job 1 then waited"
sleep 5 & sleep 6 & b=$!; kill %2; settle $b
kill %1; wait %1 %2 2>err; echo "w=$?"; e <err; rm -f err
echo "-- hot"
hot() {
  local i r=
  for ((i = 0; i < 150; i++)); do
    n=$((n + 1)); sleep 5 & sleep 6.$u$n & up 6.$u$n; kill -STOP %2; stopped 6.$u$n
    kill %1 %2; wait %1; r+="$? "; kill -CONT %2; wait %2; r+="$? "
  done
  echo $r | tr ' ' '\n' | sort | uniq -c | sed 's/^ *//'
}
hot
