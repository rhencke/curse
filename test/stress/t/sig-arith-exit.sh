#@ guards: an external TERM while the shell evaluates an arithmetic VALUE (`$(( v ))` of a variable holding an expression, `let`, `[[ -gt ]]`, eval'd): the trap's `exit 8` ends the shell with 8 every time — never swallowed by a pcall that classifies failures as "syntax error in expression" or "doesn't compile" (parser.trap_flow), in every tier, cold or warm
#@ timeout: 60
#@ iters: 5
f=$HOME/pid.$$
for body in 'x=$(( v ))' 'eval "x=\$(( v ))"' 'let "x = v"' '[[ v -gt 0 ]]'; do
	for ((k = 0; k < 4; k++)); do
		rm -f "$f"
		"$THIS_SH" -c 'trap "echo in trap; exit 8" TERM; echo $$ >"$1"; i=0
			while (( SECONDS < 10 )); do
				v="1+$i*2+($i%7)-3*$i+$i/3+$i*$i-($i<<2)+($i>>1)"
				'"$body"'
				i=$((i+1))
			done; echo "no trap; loop ended"; exit 3' _ "$f" >"$f.out" 2>&1 &
		p=$!
		for ((w = 0; w < 500; w++)); do [ -s "$f" ] && break; sleep 0.01; done
		sleep 0.$((1 + k * 2))
		kill -TERM "$(cat "$f")"; wait $p; st=$?
		o=$(tr '\n' '|' <"$f.out")
		[ "$st.$o" = "8.in trap|" ] || echo "$body, $k: status $st, output $o" >&2
		echo "$body: $([ "$st.$o" = "8.in trap|" ] && echo ok || echo WRONG)"
	done
done
rm -f "$f" "$f.out"
"$STH" probe
