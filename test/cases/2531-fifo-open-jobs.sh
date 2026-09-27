# A FIFO's open returns once its OTHER end is open — bash's open(2) blocks only until
# then, whoever opens it (here: a background job, which curse runs in-process), not until
# data arrives. And the shell writing into a full pipe whose reader is a job must let the
# job run. Neither may deadlock the shell against its own jobs.
d=${TMPDIR:-/tmp}/ff$$; mkdir -p "$d"
spin() { # FILE: busy-wait with builtins only, bounded by 5s of wall clock
	local end=$((SECONDS + 5))
	while [ ! -s "$1" ]; do [ $SECONDS -ge $end ] && return 1; done
	return 0
}
mkfifo "$d/f" "$d/g" "$d/h"
echo "-- the shell reads: its open returns when the job's write end is open"
{ exec 4>"$d/f"; spin "$d/go" && echo data >&4 || echo "no go" >&4; } &
exec 3<"$d/f"
echo go >"$d/go"
read -r x <&3; echo "read: $x"
exec 3<&-
wait
echo "-- the shell writes: its open returns when the job's read end is open"
{ exec 5<"$d/g"; spin "$d/go2" && read -r y <&5; echo "job read: $y" >"$d/out"; } &
exec 6>"$d/g"
echo go >"$d/go2"
echo hello >&6
exec 6>&-
wait; cat "$d/out"
echo "-- the shell fills the pipe a builtin job reads (300 x 1K lines)"
{ n=0; while read -r l; do n=$((n + 1)); done <"$d/h"; echo $n >"$d/cnt"; } &
s=$(printf '%01024d' 0)
exec 7>"$d/h"
for ((i = 0; i < 300; i++)); do echo "$s" >&7; done
exec 7>&-
wait; echo "lines: $(<"$d/cnt")"
echo "-- hot: 150 handshakes"
k=0
for ((i = 0; i < 150; i++)); do
	{ exec 4>"$d/f"; echo "m$i" >&4; } &
	exec 3<"$d/f"; read -r x <&3; exec 3<&-
	[ "$x" = "m$i" ] && k=$((k + 1))
	wait
done
echo "matched: $k"
rm -rf "$d"
