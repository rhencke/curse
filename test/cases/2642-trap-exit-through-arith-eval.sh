# A trap's `exit` raised while the shell evaluates an arithmetic VALUE (a variable holding
# an expression, `$(( v ))`) ends the shell with the trap's status (bash). curse's
# arith resolver pcalls the parse and the evaluation of such a value, and took the trap's
# exit for "not an expression": the loop ran on ("syntax error in expression", or 0).
# One shared test (parser.cf_raise) now lets a trap's control flow through every such
# classifying pcall.
S=${THIS_SH:-bash}
f=${TMPDIR:-/tmp}/sig2642.$$
run() { # $1: the loop body; a TERM arrives while it spins
	rm -f "$f"
	"$S" -c 'trap "echo in trap; exit 8" TERM; echo $$ >"$1"; i=0
		while (( SECONDS < 5 )); do
			v="1+$i*2+($i%7)-3*$i+$i/3+$i*$i-($i<<2)+($i>>1)"
			'"$1"'
			i=$((i+1))
		done; echo "no trap; loop ended"; exit 3' _ "$f" &
	local p=$! k
	for ((k = 0; k < 200; k++)); do [ -s "$f" ] && break; sleep 0.01; done
	sleep 0.3; kill -TERM "$(cat "$f")"; wait $p; echo "$1: rc=$?"
}
run 'x=$(( v ))' 2>&1
run 'eval "x=\$(( v ))"' 2>&1
run 'let "x = v"' 2>&1
run '[[ v -gt 0 ]]' 2>&1
rm -f "$f"
