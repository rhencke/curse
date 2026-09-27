#@ guards: a background job starts when `&` runs, not when the foreground next yields — a script that busy-waits (no external, no blocking builtin) for a background job's effect must see it (bash forks at once); background jobs as in-process coroutines (inproc-subshells) must not wait for a scheduling point; and $! set by a job inside a subshell, $(…) or pipeline stage must not leak into the parent
#@ timeout: 30
#@ iters: 0.25
d=$HOME/bg; mkdir -p "$d"
wait_for() { # FILE: busy-wait with builtins only, bounded by 3s of wall clock
	local end=$((SECONDS + 3))
	while [ ! -s "$1" ]; do [ $SECONDS -ge $end ] && return 1; done
	return 0
}
/bin/echo ext >"$d/a" &
wait_for "$d/a" && echo "external job ran" || echo "external job did NOT run while the foreground was busy"
{ echo grp >"$d/b"; } &
wait_for "$d/b" && echo "group job ran" || echo "group job did NOT run while the foreground was busy"
( echo sub >"$d/c" ) &
wait_for "$d/c" && echo "subshell job ran" || echo "subshell job did NOT run while the foreground was busy"
echo x | /bin/cat >"$d/e" &
wait_for "$d/e" && echo "pipeline job ran" || echo "pipeline job did NOT run while the foreground was busy"
wait
echo "-- \$! belongs to the shell that ran the job"
/bin/true & a=$!
( /bin/true & )
[ "$!" = "$a" ] && echo "unchanged by a subshell's job" || echo "CHANGED by a subshell's job"
x=$(/bin/true & echo)
[ "$!" = "$a" ] && echo "unchanged by a comsub's job" || echo "CHANGED by a comsub's job"
{ /bin/true & } | cat
[ "$!" = "$a" ] && echo "unchanged by a pipeline stage's job" || echo "CHANGED by a pipeline stage's job"
wait
rm -rf "$d"
"$STH" probe
