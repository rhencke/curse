# SECONDS gets the integer attribute the first time it is READ (variables.c get_seconds:
# set_int_value(var, …, 1)); assign_seconds then evalexp's an integer SECONDS (an
# overflowing literal wraps mod 2^64, an error is reported but the line goes on with 0)
# and legal_number's one that is not (ERANGE or text: 0). Every read form counts —
# $SECONDS, $((SECONDS)), ${#SECONDS}, test -v, ${!x}, declare -p, `local SECONDS`, an
# arith assignment's operand — while set/export -p listings and ( … ) don't reach the
# parent; `declare +i` drops it till the next read. `+=` appends to value_cell — the
# value last assigned or read, not the clock's — (make_variable_value), evaluated when
# integer. (Values /1000: the clock ticks.)
s() { echo "$1 $((SECONDS / 1000))"; }
SECONDS=4000+1000; SECONDS=99999999999999999999999; SECONDS+=5000; s unread
SECONDS=99999999999999999999999; s read-overflow
SECONDS=-99999999999999999999999; s read-neg-overflow
SECONDS=4000+1000; s read-expr
{ SECONDS='1+'; } 2>&1 | sed 's/^.*line [0-9]*: //'
{ SECONDS='1+'; } 2>/dev/null; echo "err st=$? $((SECONDS / 1000))"
declare +i SECONDS; SECONDS=4000+1000; s plus-i
SECONDS=4000+1000; s plus-i-then-read
declare +i SECONDS; declare -p SECONDS
for r in ': $((SECONDS))' 'x=${#SECONDS}' 'test -v SECONDS' 'x=SECONDS; : ${!x}' 'declare -p SECONDS >/dev/null' \
	'f() { local SECONDS; }; f' ': $((SECONDS = 7000))' 'SECONDS+=0' 'set >/dev/null' 'export -p >/dev/null' \
	'(: $SECONDS)' ': "$(echo $SECONDS)"'; do
	declare +i SECONDS; eval "$r"; SECONDS=4000+1000; s "$r"
done
declare +i SECONDS; SECONDS=5000; SECONDS+=0; s append-text
SECONDS=5000; : $SECONDS; SECONDS+=1000; s append-int
SECONDS=4000+1000; SECONDS+=0; s append-after-int-assign
RANDOM=5; { RANDOM='1+'; } 2>/dev/null; echo "random st=$?"; a=$RANDOM
RANDOM=5; [ "$a" = "$RANDOM" ] && echo "random unseeded"
hot() {
	local i n=0 m=0 k=0
	for ((i = 0; i < 150; i++)); do
		declare +i SECONDS
		SECONDS=6000+1000; ((SECONDS / 1000 == 0)) && n=$((n + 1))
		SECONDS=99999999999999999999999; ((SECONDS / 1000 == 200376420520689)) && m=$((m + 1))
		SECONDS=5000; SECONDS+=1000; ((SECONDS / 1000 == 6)) && k=$((k + 1))
	done
	echo "hot $n $m $k"
}
hot
