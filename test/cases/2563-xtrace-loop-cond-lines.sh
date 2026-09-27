# Pinned bash behaviour: set -x traces a loop's CONDITION under the condition command's own
# line — a `while`/`until` test ([ ], [[ ]], (( ))) on a line of its own, on every pass, not
# the body's last line — and every slot of a multi-line `for (( ; ; ))` (the step
# included) under the `for` line (eval_arith_for_expr: line_number = arith_lineno).
PS4='+$LINENO: '
f() {
	for ((i = 0;
	      i < 2;
	      i++)); do
		:
	done
	n=0
	while
	  [ $n -lt 2 ]
	do
	  n=$((n+1))
	done
	until
	  [[ $n -gt 3 ]]
	do n=$((n+1)); done
	while (( n >
	  2 )); do n=$((n-1)); done
}
exec 2>&1
set -x
f
set +x
for ((k = 0; k < 200; k++)); do
	(set -x; f)
done 2>&1 | sort | uniq -c
