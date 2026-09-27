# A shell's exit and its STOPPED background jobs (bash 5.2 exit_shell -> end_job_control):
# with job control on at the exit, terminate_stopped_jobs sends each stopped job's process
# group SIGTERM then SIGCONT; without job control, a job in the shell's own process group is
# left exactly as it is — still stopped (T), no signal at all — and the exit doesn't wait
# for it (nor for a subshell or pipeline stuck behind it). Every child here writes its pid,
# logs any HUP/TERM it gets, then stops itself; the inner shell waits for the stop, runs a
# hot loop, and exits; the outer reports the child's state and log, then kills it.
t=${TMPDIR:-/tmp}/c2650.$$
mkdir -p "$t"
cat >"$t/lib" <<EOL
kid() { /bin/sh -c 'echo \$\$ > $t/p; trap "echo got-HUP >> $t/log" HUP; trap "echo got-TERM >> $t/log" TERM; kill -STOP \$\$; echo resumed >> $t/log'; }
waitstop() {
	until [ -s $t/p ]; do :; done
	p=\$(cat $t/p)
	until case \$(ps -o stat= -p \$p) in T*) true;; *) false;; esac; do :; done
}
hot() { n=0; for ((i = 0; i < 200; i++)); do n=\$((n + i)); done; echo "inner n=\$n"; }
EOL
run() { # NAME SCRIPT
	rm -f "$t/p" "$t/log"
	printf '%s\n' ". $t/lib" "$2" >"$t/s"
	"$THIS_SH" "$t/s" >"$t/out" 2>/dev/null
	echo "$1: status $?"
	cat "$t/out"
	sleep 0.2
	p=$(cat "$t/p")
	echo "  state: $(ps -o stat= -p "$p" | cut -c1 || echo gone)"
	sed 's/^/  log: /' "$t/log" 2>/dev/null
	kill -9 "$p" 2>/dev/null
	sleep 0.05
}
run simple 'kid & waitstop; hot'
run subshell '( kid ) & waitstop; hot'
run pipeline 'kid | true & waitstop; hot'
run group '{ kid; echo after; } & waitstop; hot; exit 3'
run eval 'eval "kid &"; waitstop; hot'
run trap 'trap "kid & waitstop; hot" EXIT; :'
run source 'echo "kid &" > '"$t"'/src; . '"$t"'/src; waitstop; hot'
run jobctl 'set -m; kid & waitstop; hot'
run jobctl-sub 'set -m; ( kid ) & waitstop; hot'
run jobctl-off 'set -m; set +m; kid & waitstop; hot; set -m'
rm -rf "$t"
