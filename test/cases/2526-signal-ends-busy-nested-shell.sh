# HUP, INT and TERM end a nested shell ($THIS_SH as a job) that has no trap for them,
# whatever it is doing, with 128+sig — as bash does. The curse daemon's client forwards
# them to the worker, which runs the script in-process and so always catches them: a
# `read` spinning on endless input (a JIT-compiled loop the signal must break into), one
# with a stopped job (which gets SIGHUP+SIGCONT, as its group is orphaned), and one
# waiting for an external — which bash leaves running, and which must not be left a
# zombie once it ends (the worker, its parent, reaps it).
S=${THIS_SH:-bash}
f=${TMPDIR:-/tmp}/sig2526.$$
gone() { # has process $1 ended and been reaped, within 2s?
	local k
	for ((k = 0; k < 100; k++)); do
		[ -e /proc/$1 ] || { echo gone; return; }
		sleep 0.02
	done
	echo "still there: $(cut -d' ' -f3 /proc/$1/stat 2>/dev/null)"
}
set -m # (a job's INT is then not ignored)
for sig in HUP INT TERM; do
	"$S" -c 'read -r x; echo "read returned $?"' </dev/zero &
	p=$!; sleep 0.4; kill -$sig $p; wait $p; echo "read, $sig: st=$?"
done
for sig in HUP INT TERM; do
	rm -f "$f"
	"$S" -c 'set -m; /bin/sleep 3 & echo $! >"$1"; kill -STOP %1; read -r x; echo "read returned $?"' _ "$f" </dev/zero &
	p=$!; sleep 0.4; kill -$sig $p; wait $p; echo "read with a stopped job, $sig: st=$?"
	echo "  the stopped job: $(gone "$(cat "$f")")"
done
for sig in HUP TERM; do
	rm -f "$f"
	"$S" -c '/bin/sh -c "echo \$\$ >\"\$1\"; exec /bin/sleep 0.5" _ "$1"; echo after' _ "$f" </dev/null &
	p=$!; sleep 0.25; kill -$sig $p; wait $p; echo "external, $sig: st=$?"
	echo "  the external: $(gone "$(cat "$f")")"
done
set +m
rm -f "$f"
