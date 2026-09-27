# A function's own redirections are applied at the line its body starts on (bash's
# execute_function: line_number = function_line_number = the body's line), so a failed
# one — and a $LINENO in its word — names that line, not the call's. That is parse.y's
# function_bstart, set only by a `{` body: any other compound body carries the last
# `{`-bodied definition's line (0 — no line — before any), and a `( … )` body applies
# them in the subshell, at the line it closes on.
S=${THIS_SH:-bash}
u=/nonexistent/dir/file
$S -c 'm() if :; then :; fi >/nonexistent/m
m' 2>&1 | sed 's/^[^:]*: //'
f() { :; } {r}>$u
f
echo "st=$?"
g()


{
	:
} >$u
g
h() { :; } >/dev/null 2>&1 {r}>$u; h; echo "h st=$?"
k() { :; } >/nonexistent/at$LINENO

k
e() { :; } >$u
for ((i = 0; i < 200; i++)); do e; done 2>&1 | sort | uniq -c | sed 's/^ *//'
w() { for ((i = 0; i < 200; i++)); do e; g; done; }
w 2>&1 | sort | uniq -c | sed 's/^ *//'
n() for i in 1; do :; done >$u
n
p() (
	:
) >$u

p
q() [[ -n x ]] >$u; q
declare -f n q
eval 'x() { :; } >$u
x'
# (in the EXIT trap after end of input bash isn't `executing`: q's error takes tc->line)
trap q EXIT
