#@ guards: signal traps (INT TERM HUP USR1 USR2) delivered while the shell is inside a builtin (read, wait), a redirection being applied, $(…), a pipeline stage, a subshell, eval, a sourced file, a function and a hot compiled loop; the preemptive VM-hook + EINTR delivery (signal-preemption) and the in-process comsub/pipeline/subshell swap (inproc-subshells)
#@ timeout: 30
# Deterministic: every external signal is sent by `sthelp sendwhen` only once the shell
# sleeps in a system call, so bash runs each trap at one fixed point.
H=$STH
f=${TMPDIR:-/tmp}/ctx.$$
mkfifo "$f" || exit 9
for sig in INT TERM HUP USR1 USR2; do
	signo=$(kill -l $sig)
	n=0
	trap 'n=$((n+1)); echo "  trap $sig n=$n"' $sig
	echo "== $sig"
	echo "-- a redirection being applied (open of a fifo blocks)"
	"$H" sendwhen $$ $signo 5000 any "$f" &
	read x <"$f"; echo "read st=$? x=$x"
	wait $!; echo "sender st=$?"
	echo "-- the read builtin"
	exec 3<>"$f"
	"$H" sendwhen $$ $signo 5000 any "$f" &
	read x <&3; echo "read st=$? x=$x"
	wait $!
	exec 3<&-
	echo "-- the wait builtin"
	"$H" sendwhen $$ $signo 5000 any &
	sp=$!
	wait $sp; echo "wait st=$?"
	echo "-- \$(…) (bash: the parent traps while reading it)"
	x=$("$H" sendwhen $$ $signo 5000 any; echo in-comsub)
	echo "comsub st=$? x=[$x]"
	echo "-- a pipeline stage (a child signals \$\$)"
	{ kill -$sig $$; echo stage; } | cat
	echo "pipe st=${PIPESTATUS[*]}"
	echo "-- a subshell"
	( kill -$sig $$; echo in-subshell )
	echo "subshell st=$?"
	echo "-- eval"
	eval 'kill -$sig $$; echo in-eval'
	echo "-- a sourced file"
	printf 'kill -%s $$\necho in-source\n' $sig >"$f.src"
	. "$f.src"; rm -f "$f.src"
	echo "-- a function"
	fn() { local l=1; kill -$sig $$; echo "in-fn l=$l"; return 3; }
	fn; echo "fn st=$?"
	echo "-- a hot loop, stopped by the trap"
	trap 'n=$((n+1)); stop=1' $sig
	stop=0 i=0
	rm -f hd; "$H" hammer $$ $signo 1 30000 30000 hd # (detached: the loop never yields)
	while [ $stop = 0 ]; do i=$((i+1)); done
	until [ -e hd ]; do sleep 0.01; done; rm -f hd
	echo "loop stopped: $stop"
	trap - $sig
	echo "total $sig traps: $n"
done
rm -f "$f"
"$H" probe
