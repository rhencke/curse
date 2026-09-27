# Pinned bash behaviour: a $( … ) inside ${ … } — quoted or not, in a nested "…" or ${ … } —
# is syntax-checked as the line is READ (parse_matched_pair reads each `$(` with
# parse_comsub), so a bad body fails the whole text before any of it runs (in an eval:
# parse_comsub's FORCE_EOF ends the shell, status 1); a '…' or `…` in the ${ … } is read
# as a quoted string, and a \$( is no comsub at all.
f() {
	(eval 'echo a; echo "${x:-$(if)}"; echo A') 2>/dev/null; r1=$?
	(eval 'echo b; echo ${x:-"$(case)"}') 2>/dev/null; r2=$?
	(eval 'echo c; echo "${x:-${y#$(fi)}}"') 2>/dev/null; r3=$?
	eval 'echo "${x:-\$(if)}" ${x:-'"'"'$(if)'"'"'}'; r4=$?
	x=1; eval 'echo "${x:+$(echo ok)}"'; unset x
	echo "$r1 $r2 $r3 $r4"
}
f
for ((i = 0; i < 200; i++)); do f; done | sort | uniq -c
echo z; echo "${x:-$(if)}"
echo never
