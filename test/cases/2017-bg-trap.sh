# Background jobs in a program with signal traps compile (the job is an in-process task
# in both tiers: bg_launch owns the trap handling).
trap 'echo parent-caught' USR1
{ trap -p USR1; echo "in bg"; } &
wait $!; echo "st=$?"
f() { echo "f in bg $1"; }
f x &
wait
( kill -USR1 $$ ) ; echo after-kill
