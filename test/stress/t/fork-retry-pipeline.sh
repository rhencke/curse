#@ guards: a pipeline longer than the processes to be had (a cgroup TasksMax, as a container's pids limit) gets through: bash's make_child says `fork: retry: …`, sleeps 1, 2, 4, 8 s and forks again as the earlier stages end (stress-attack S15: curse hung with 600 of 800 stages started, then reported EAGAIN as `Permission denied`). The shell runs under its own tools/capped scope (TasksMax 300); in the daemon modes the pipeline runs in the worker, outside it — the result must match all the same. How many retries it takes varies with timing: only whether the pipeline got through is compared.
#@ timeout: 90
#@ nested: yes
uid=$(id -u)
pipe=$(printf ' | cat%.0s' $(seq 800))
run() { # the retries and their count vary: shown as a yes/no
	XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus CAPPED= \
		CAP_TASKS=300 CAP_MEM=2G "$REPO_TOOLS/capped" env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" "$THIS_SH" -c "$1" 2> "$TMPDIR/err.$$"
	echo "status $?"
	grep -v "fork: retry: Resource temporarily unavailable$" "$TMPDIR/err.$$"
	rm -f "$TMPDIR/err.$$"
}
REPO_TOOLS=$STRESS_REPO/tools
run "y=\$(echo 1$pipe); echo \"comsub: \$y\""
run "echo 2$pipe; echo \"pipeline: \${PIPESTATUS[0]} \${#PIPESTATUS[@]}\""
run "f() { echo 3$pipe; }; f; eval 'echo 4$pipe'"
