# Background jobs start in launch order: bash forks each `&` job at once, so
# `echo a & echo b &` prints a then b. curse runs jobs as coroutines; a job must get its
# first run before any job launched after it, even when the foreground's time slice
# expired meanwhile (a stale preemption flag made the first job yield at its first
# function call, and the second printed first).
f() { echo "$1"; }
big=$(printf '%030000d' 0)
for i in 1 2 3; do
	{ f word_a$i; } &
	: "${big//0/y}" # (the foreground computes: its slice runs out)
	echo word_b$i &
	wait
done
echo "-- oil shell-grammar#4"
echo word_a & echo word_b &
wait
echo "-- hot: 150 rounds"
mid=$(printf '%08000d' 0)
bad=0
for ((i = 0; i < 150; i++)); do
	out=$({ f a; } & : "${mid//0/y}"; echo b & wait)
	[ "$out" = $'a\nb' ] || bad=$((bad + 1))
done
echo "out of order: $bad"
