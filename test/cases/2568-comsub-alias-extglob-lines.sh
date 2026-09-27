# Pinned bash behaviour: a $( … ) / `…` body runs through parse_and_execute — each command
# read after the one before it ran — so an alias the body defines expands on its later
# lines; but the body is first READ whole (parse_comsub) under the extglob state of the
# moment, so a `shopt -s extglob` inside it doesn't make a later @( … ) valid: that is a
# syntax error before anything runs, reported at the body line holding it.
exec 2>&1
x=$(shopt -s expand_aliases; alias f_="echo 2"
f_ y); echo "$x"
x=`shopt -s expand_aliases; alias g_="echo 3"
g_ z`; echo "$x"
h() {
	__o=$(
	shopt -s expand_aliases
	alias e_='echo 1
echo 2'
	e_ $1
	)
	echo "$__o" | tr '\n' ' '; echo
}
h a
for ((i = 0; i < 200; i++)); do h "$((i % 2))"; done | sort | uniq -c
(eval 'echo pre; x=$(
shopt -s extglob
echo @(a|b)
)'; echo "not reached") 2>&1
echo "st $?"
