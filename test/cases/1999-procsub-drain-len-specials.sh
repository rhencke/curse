# <()/>() drained per statement with main's pending/registered counts (a function arg
# <(…) stays open across an inner redirected compound), and ${##}/${#?}/${#-} segments.
f() { while read x; do echo "$x"; done < <(echo in); cat "$1"; }
f <(echo arg)
g() { { cat; } < <(echo in2); cat "$1"; }
g <(echo arg2)
set -- a b c
false
echo ${#?} ${##} ${#-} x
sleep 0 & wait
[ ${#!} -gt 0 ] && echo "bang-len-ok ${##}"
