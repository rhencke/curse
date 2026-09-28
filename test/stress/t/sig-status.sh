#@ guards: exit statuses of shells and jobs killed by signals are 128+sig (the daemon relays a killed script's signal to its client: the 0x10000 status bit), the EXIT trap runs before a trapped signal's `exit`, and a shell killed by an untrapped signal dies of it (no EXIT trap, as bash); nested shells go through $THIS_SH (the daemon for dcold/dwarm)
#@ timeout: 40
#@ nested: yes
S=$THIS_SH
for sig in HUP INT QUIT TERM USR1 USR2 ALRM PIPE; do
	"$S" -c 'kill -'$sig' $$; echo not-reached'
	echo "$sig untrapped: st=$?"
done
for sig in HUP TERM USR1; do
	"$S" -c 'trap "echo \"  EXIT trap\"" EXIT; trap "echo \"  '$sig' trap\"; exit 3" '$sig'; kill -'$sig' $$; echo not-reached'
	echo "$sig trapped+exit: st=$?"
	"$S" -c 'trap "echo \"  EXIT trap\"" EXIT; kill -'$sig' $$; echo not-reached'
	echo "$sig with only an EXIT trap: st=$?"
done
echo "-- killed from outside while blocked"
f=${TMPDIR:-/tmp}/ss.$$; mkfifo "$f"
"$S" -c 'exec 3<>"$1"; read -r x <&3' _ "$f" &
p=$!
"$STH" sendwhen $p 15 5000 any || { echo "  could not signal \$! from an external"; kill -KILL $p; }
wait $p; echo "TERM while blocked: st=$?"
# (the script says when its trap is set: through the daemon $! is the CLIENT, blocked from
# the start — sendwhen alone let the TERM land before the worker had run `trap`: 143, not 9)
"$S" -c 'trap "echo \"  TERM trap, exiting\"; exit 9" TERM; : > "$1.ready"; exec 3<>"$1"; read -r x <&3; echo "read returned $?"' _ "$f" &
p=$!
SECONDS=0; until [ -e "$f.ready" ] || ((SECONDS >= 5)); do sleep 0.01; done
"$STH" sendwhen $p 15 5000 any || { echo "  could not signal \$! from an external"; kill -KILL $p; }
wait $p; echo "trapped TERM while blocked: st=$?"
rm -f "$f.ready"
rm -f "$f"
echo "-- a pipeline's statuses when a stage dies of a signal"
"$S" -c 'kill -TERM $$' | cat; echo "PIPESTATUS=${PIPESTATUS[*]}"
yes | head -1 >/dev/null; echo "SIGPIPE stage: ${PIPESTATUS[*]}"
"$STH" probe
