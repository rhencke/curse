# While background jobs live, the FOREGROUND is time-sliced: bash's job is a process the
# kernel runs beside the shell, so a foreground that computes (a loop, pure recursion)
# without ever blocking still sees the job make progress. curse runs jobs in-process: the
# foreground yields to them at loop heads and function entries when its slice runs out.
d=${TMPDIR:-/tmp}/ts$$; mkdir -p "$d"
spin() { # FILE: busy-wait with builtins only, bounded by 5s of wall clock
	local end=$((SECONDS + 5))
	while [ ! -s "$1" ]; do [ $SECONDS -ge $end ] && return 1; done
	return 0
}
{ echo grp >"$d/a"; } &
spin "$d/a" && echo "group job ran during a busy loop" || echo "group job starved"
( echo sub >"$d/b" ) &
spin "$d/b" && echo "subshell job ran during a busy loop" || echo "subshell job starved"
# a job that needs many turns: it counts to 300 while the foreground spins
{ n=0; while [ $n -lt 300 ]; do n=$((n + 1)); done; echo $n >"$d/c"; } &
spin "$d/c" && echo "counting job finished: $(<"$d/c")" || echo "counting job starved"
# pure recursion (no loop head): the function entry yields
rec() { [ -s "$d/e" ] && return 0; [ $SECONDS -ge $end ] && return 1; rec; }
end=$((SECONDS + 5))
{ echo rec >"$d/e"; } &
rec && echo "job ran during recursion" || echo "job starved by recursion"
wait
echo "-- hot: 150 jobs, each seen by a busy loop"
k=0
for ((i = 0; i < 150; i++)); do
	rm -f "$d/h"
	{ echo $i >"$d/h"; } &
	spin "$d/h" && [ "$(<"$d/h")" = $i ] && k=$((k + 1))
done
wait
echo "seen: $k"
rm -rf "$d"
