# $! belongs to the shell that started the job: a job started inside `( … )`, `$( … )`
# or a pipeline stage is that child's (bash forks it: the child's last_asynchronous_pid),
# and the parent's $! is unchanged — curse runs those children in-process.
/bin/true & a=$!
( /bin/true & )
[ "$!" = "$a" ] && echo "unchanged by a subshell's job" || echo "CHANGED by a subshell's job"
x=$(/bin/true & echo)
[ "$!" = "$a" ] && echo "unchanged by a comsub's job" || echo "CHANGED by a comsub's job"
{ /bin/true & } | cat
[ "$!" = "$a" ] && echo "unchanged by a pipeline stage's job" || echo "CHANGED by a pipeline stage's job"
( b=$!; /bin/true & [ "$!" != "$b" ] && echo "the subshell's own \$! is set" )
y=$(/bin/true & [ -n "$!" ] && echo "set inside the comsub")
echo "$y"
wait
echo "-- hot"
k=0
for ((i = 0; i < 150; i++)); do
	{ :; } & a=$!
	( { :; } & ); z=$({ :; } & echo)
	[ "$!" = "$a" ] && k=$((k + 1))
done
wait
echo "kept: $k"
