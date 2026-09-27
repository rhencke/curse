#@ guards: a signal sent to a client reaches only the request it was sent for. The client forwards its signals to the worker running its script; A's USR1 sent just as A's script ends must never reach the worker's NEXT request (B's script, whose USR1 trap would run). The worker takes no next request until the client has stopped forwarding and closed the connection (protocol v2); before, B got A's signal ~1-4 times in 300
#@ timeout: 240
#@ iters: 0.25
#@ concurrent: yes
d=${TMPDIR:-/tmp}
printf ':\n' >"$d/a.sh"
printf "trap 'echo B-GOT-USR1' USR1\nsleep 0.2\n" >"$d/b.sh"
n=0
for i in $(seq 300); do
	"$THIS_SH" "$d/a.sh" </dev/null & a=$!
	"$THIS_SH" "$d/b.sh" </dev/null >"$d/out.b" & b=$!
	k=$(( (i % 15) * 20 )) # (the kill lands at every point of A's short life)
	while [ $k -gt 0 ]; do k=$((k - 1)); done
	kill -USR1 $a 2>/dev/null
	wait $a 2>/dev/null
	wait $b
	grep -q B-GOT "$d/out.b" && n=$((n + 1))
done
echo "B received A's signal: $n/300"
rm -f "$d/a.sh" "$d/b.sh" "$d/out.b"
