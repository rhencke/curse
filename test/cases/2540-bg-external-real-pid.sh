# `ext args &`: bash's child execs the external, so $! is that program's own pid — ps,
# /proc, /bin/kill, `kill -0`, a pidfile it writes all name the same process. curse spawns
# such a job directly when its words have no side effect (interp as the compiled tier).
d=${TMPDIR:-/tmp}/rp$$; mkdir -p "$d"
pm=$(cat /proc/sys/kernel/pid_max)
n=0.3
/bin/sleep $n &
ps -o comm= -p $!
wait $!; echo "st=$?"
/bin/sh -c 'echo $$ >'"$d"'/pf; exec /bin/sleep 5' &
p=$!
while [ ! -s "$d/pf" ]; do /bin/sleep 0.01; done
[ "$(cat "$d/pf")" = "$p" ] && echo "pidfile names \$!" || echo "pidfile differs"
kill -0 $p && echo "kill -0 ok"
/bin/kill -TERM $p; wait $p; echo "killed st=$?"
x=v; /bin/echo "$x" b$x $? &
wait
echo "-- hot: 150 jobs"
k=0
for ((i = 0; i < 150; i++)); do
	/bin/true & (( $! <= pm )) && k=$((k + 1))
done
wait
echo "real pids: $k"
rm -rf "$d"
