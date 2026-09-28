# Pinned bash behaviour: a backslash-newline inside or right after a reserved word is
# removed from the input before the word is read, so `}`, `fi`, `done`, `esac` split or
# followed that way still close their compound command; the continuation line still
# counts for $LINENO.
{ echo "a $LINENO"; }\

echo "b $LINENO"
if true; then echo "c $LINENO"; fi\

echo "d $LINENO"
f() {
	for ((i = 0; i < 160; i++)); do n=$((n + 1)); do\
ne
	echo "f $n $LINENO"
}\

f
declare -f f
w\
hile false; do :; done; echo "e $LINENO"
{ echo g; }\
; echo "h $LINENO"
case x in x) echo "i $LINENO" ;; es\
ac
echo "j $LINENO"
