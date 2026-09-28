#@ guards: trapped signals held while an in-process $(…) or subshell runs (rt.defer_signal) and flushed when it ends, under storms of many distinct signals whose traps themselves run $(…): a signal whose trap runs between flush_deferred's `if deferred_sigs` and `local d = deferred_sigs` flushed the set first, so the outer flush indexed nil ("attempt to index local 'd'"), surfacing as a trap "syntax error" or escaping the shell, which then died of SIGSEGV (stress-attack S1, all tiers, ~1 run in 3)
#@ timeout: 60
#@ iters: 3
# Properties only (the signals' timing is random): every line printed is a verdict.
H=$STH
declare -A cnt
sigs="HUP USR1 USR2 ALRM TERM URG WINCH PWR SYS XCPU PROF IO"
for s in $sigs; do trap "cnt[$s]=\$((cnt[$s]+1)); j=\$(echo \$s)" $s; done
for s in $sigs; do "$H" hammer $$ $(kill -l $s) 150 10 300 "$HOME/done.$s"; done
all() { for s in $sigs; do [ -e "$HOME/done.$s" ] || return 1; done; }
k=0 bad=0
until all; do
	k=$((k + 1))
	x=$(echo y); [ "$x" = y ] || bad=$((bad + 1))
	( z=$(echo w); [ "$z" = w ] ) || bad=$((bad + 1))
	for ((i = 0; i < 300; i++)); do :; done
done
trap - $sigs
over=0 none=0
for s in $sigs; do
	c=${cnt[$s]:-0} n=$(cat "$HOME/done.$s")
	[ "$c" -ge 1 ] || none=$((none + 1))
	[ "$c" -le "$n" ] || { over=$((over + 1)); echo "$s: $c traps for $n signals" >&2; }
done
echo "comsub results intact: $([ $bad = 0 ] && echo yes || echo "NO ($bad)")"
echo "no trap ran more often than its signal was sent: $([ $over = 0 ] && echo yes || echo NO)"
echo "every trap ran: $([ $none = 0 ] && echo yes || echo NO)"
rm -f "$HOME"/done.*
"$STH" probe
