#@ guards: SIGCHLD storms from many background jobs with a CHLD trap; `wait`, `wait -n`, `wait %N` and `wait PID` interrupted by trapped signals (bash returns 128+sig and the job's status stays collectable); `read -t` timeouts (status > 128, partial input kept)
#@ timeout: 30
echo "-- statuses of many jobs, collected one by one"
pids=()
for k in $(seq 30); do ( exit $((k % 7)) ) & pids+=($!); done
sum=0
for p in "${pids[@]}"; do wait $p; sum=$((sum + $?)); done
echo "sum=$sum"
echo "-- wait -n: every job reported exactly once"
for k in 1 2 3 4 5; do ( sleep 0.0$k; exit $k ) & done
tot=0 cnt=0
while wait -n; st=$?; [ $st -ne 127 ]; do tot=$((tot + st)); cnt=$((cnt+1)); done
echo "wait -n: cnt=$cnt tot=$tot"
echo "-- wait interrupted by a trapped signal (128+sig), then collected"
# (the sender is not our child — ( … & ) — since waiting for a sender that raced the
# interrupted wait can hang bash 5.2.21 itself)
trap 'echo "  trap USR1"' USR1
f=${TMPDIR:-/tmp}/cw.$$; mkfifo "$f"
exec 3<>"$f"
( read -r x <&3; exit 42 ) &
j=$!
( "$STH" sendwhen $$ 10 5000 any & )
wait $j; echo "wait pid st=$?"
echo go >&3
wait $j; echo "wait pid again st=$?"
( read -r x <&3; exit 43 ) &
( "$STH" sendwhen $$ 10 5000 any & )
wait %?43; echo "wait %?43 st=$?"
echo go >&3
wait %?43; echo "wait %?43 again st=$?"
( read -r x <&3; exit 44 ) &
j=$!
( "$STH" sendwhen $$ 10 5000 any & )
wait -n $j; echo "wait -n st=$?"
echo go >&3
wait; echo "wait all st=$?"
exec 3>&-
rm -f "$f"
trap - USR1
echo "-- CHLD storm: 40 background jobs"
# (bash runs the trap about once per reaped child; the last may run a command later,
# so check bounds, and the total once everything settled)
c=0
trap 'c=$((c+1))' CHLD
for ((k = 0; k < 40; k++)); do /bin/true & done
wait
c1=$c
echo "external jobs: $([ $c1 -ge 1 ] && [ $c1 -le 40 ] && echo ok || { echo "bad $c1" >&2; echo bad; })"
for ((k = 1; k <= 20; k++)); do ( exit $k ) & done
wait
/bin/sleep 0.1
echo "subshell jobs: $([ $((c - c1)) -ge 0 ] && [ $c -le 70 ] && [ $c -ge 2 ] && echo ok || { echo "bad $c1 $c" >&2; echo bad; })"
trap - CHLD
echo "-- read -t"
read -t 0.2 x <> <(:); echo "timeout st=$? x=[$x]"
{ printf 'part'; sleep 0.5; printf 'ial\n'; } | { read -t 0.2 x; echo "partial st=$? x=[$x]"; }
read -t 0 x </dev/null; echo "t0 st=$?"
echo line | { read -t 5 x; echo "ok st=$? x=[$x]"; }
read -t 0.1 -n 3 x <> <(:); echo "n3 st=$? x=[$x]"
z=$(ps -o stat= --ppid $$ | grep -c '^Z'); echo "zombies: $([ $z = 0 ] && echo none || { echo "zombies: $z" >&2; echo SOME; })"
"$STH" probe
