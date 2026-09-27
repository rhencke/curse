# A redirection resolves its file against THIS shell's cwd as of the redirection (redir.c
# redir_open: open(2) of the name as written). curse runs background jobs in-process —
# each chdir()s the process to its own cwd whenever it runs — and a FIFO's open waits on
# a helper thread while the jobs run: that open must still land in the shell's directory
# (and use its umask), never in a busy job's. Here a job spins in b/, which holds a
# regular file p; the shell, in a/, writes to a/p — a FIFO read by another job.
d=${TMPDIR:-/tmp}/oc$$; rm -rf "$d"; mkdir -p "$d/a" "$d/b"; mkfifo "$d/a/p"
echo precious >"$d/b/p"
cd "$d/a"
(cd "$d/b"; umask 077; while :; do :; done) &
busy=$!
put() { # WORD: the shell writes WORD into p (relative) while a job reads it
	{ read -r l <"$d/a/p"; echo "$l" >"$d/got"; } &
	local r=$!
	echo "$1" >p
	wait $r
	cat "$d/got"
}
put plain
eval 'put eval'
echo 'put sourced' >"$d/s.inc"; . "$d/s.inc"
trap 'put trap' USR1; kill -USR1 $$; trap - USR1
echo "-- a job's own relative open, while another job spins elsewhere"
{ cd "$d/a"; read -r l <p; echo "job read: $l"; } &
r=$!
echo relative >"$d/a/p"
wait $r
echo "-- hot: 150 writes"
k=0
for ((i = 0; i < 150; i++)); do
	{ read -r l <"$d/a/p"; echo "$l" >"$d/got"; } &
	r=$!
	echo "w$i" >p
	wait $r
	[ "$(<"$d/got")" = "w$i" ] && k=$((k + 1))
done
echo "matched: $k"
kill $busy; wait $busy 2>/dev/null
echo "b/p: $(<"$d/b/p")"
ls "$d/b"
cd /; rm -rf "$d"
