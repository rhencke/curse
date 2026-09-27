#@ guards: a child a script leaves behind is reaped once it ends, never left a zombie on the daemon worker that ran the script (case 2526 under full-gate load). A nested shell killed by TERM while it waits for an external leaves that external running, as bash does (it then belongs to init). The worker used to keep it and reap it only at its own later reap points: never while blocked in accept() after losing a connection to another idle worker (every idle worker's poll wakes; one accept wins), nor while serving a later request (here `sleep 2`). Before the fix the external stayed a zombie in ~85% of iterations; now the worker retires and leaves it to init
#@ timeout: 150
#@ iters: 0.25
#@ concurrent: yes
S=$THIS_SH
f=${TMPDIR:-/tmp}/orphan.$$
gone() { # has process $1 ended and been reaped, within 1s?
	local k
	for ((k = 0; k < 50; k++)); do
		[ -e /proc/$1 ] || return 0
		sleep 0.02
	done
	return 1
}
n=0 N=10
for ((i = 0; i < N; i++)); do
	rm -f "$f"
	"$S" -c '/bin/sh -c "echo \$\$ >\"\$1\"; exec /bin/sleep 0.3" _ "$1"; echo after' _ "$f" </dev/null >/dev/null &
	p=$!
	sleep 0.1
	kill -TERM $p
	wait $p 2>/dev/null
	"$S" -c 'sleep 2' </dev/null & q=$! # (a later request: the old worker served it, or lost it)
	sleep 0.3 # (the external has ended by now)
	gone "$(cat "$f")" && n=$((n + 1))
	wait $q
done
echo "externals reaped once they ended: $n/$N"
rm -f "$f"
