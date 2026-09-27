# `name+=value` on an EXPORTED variable: bash appends to the variable and builds the
# environment only when it runs a command, so a long append loop stays linear. The
# child's environment always holds the current value — exported, local -x, in a subshell,
# $(…) and a job, after unset / export -n, and under set -a (bind_variable auto-exports).
s=a; set -a; s+=b; env | grep '^s='; set +a
t=1; export t; t+=2; f() { local t+=3; t+=4; printenv t; }; f; printenv t
u=x; export u; u+=y; ( u+=z; printenv u ); printenv u; v=$(u+=w; printenv u); echo $v; printenv u
u+=q & wait; printenv u; u+=r; unset u; printenv u || echo unset; u+=s; printenv u || echo notexp
export w=1; w+=2; w=3; w+=4; printenv w; export -n w; w+=5; printenv w || echo unexp; echo $w
export y; for i in 1 2 3; do y+=$i; sh -c 'echo "sh:$y"'; done
echo "-- hot: 100000 appends to an exported variable, then a child reads it"
export big=
t0=${EPOCHREALTIME/./}
for ((i = 0; i < 100000; i++)); do big+=x; done
t1=${EPOCHREALTIME/./}
printenv big | wc -c | tr -d ' '
(( t1 - t0 < 4000000 )) && echo linear || echo "slow: $(( (t1 - t0) / 1000 ))ms"
set -a; sa=
for ((i = 0; i < 100000; i++)); do sa+=y; done
t2=${EPOCHREALTIME/./}; set +a
printenv sa | wc -c | tr -d ' '
(( t2 - t1 < 4000000 )) && echo linear || echo "slow: $(( (t2 - t1) / 1000 ))ms"
