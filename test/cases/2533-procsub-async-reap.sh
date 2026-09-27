# A process substitution's child is reaped asynchronously: bash never waits for it when
# the command it was expanded for ends (only `wait` does: procsub_waitpid/procsub_waitall).
# So a >(cat) whose pipe `exec 3>` still holds can't block the shell, and
# `read -t .5 < <(sleep 2)` times out after .5s, not 2s.
d=${TMPDIR:-/tmp}/pa$$; mkdir -p "$d"; cd "$d" || exit
echo "-- exec 3> >(cat >out)"
exec 3> >(cat >out)
echo hi >&3
echo two >&3
exec 3>&-
wait # (waits for the procsub too)
cat out
echo "-- read -t .5 < <(sleep 2)"
t0=${EPOCHREALTIME/./}
read -t .5 x < <(sleep 2)
echo "read: $?"
t1=${EPOCHREALTIME/./}
kill $! 2>/dev/null
(( t1 - t0 < 1500000 )) && echo "not waited for" || echo "waited: $(( (t1 - t0) / 1000 ))ms"
echo "-- wait \$! gets a procsub's status"
: <(exit 3)
wait $!; echo "status: $?"
echo "-- hot: 150 exec'd >() writers"
for ((i = 0; i < 150; i++)); do
	exec 4> >(cat >>lines)
	echo "l$i" >&4
	exec 4>&-
done
wait
wc -l <lines | tr -d ' '
cd / && rm -rf "$d"
