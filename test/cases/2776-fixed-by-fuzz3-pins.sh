# Pins for findings the fix-fuzz3 changes fixed before they were worked on: a trap handler
# re-entered from itself numbers its lines from the trapped line (F64, via F40); a second
# here-document on a line whose first ran to EOF warns at the line its reading began (F80,
# via F47); a missing operand after `?:` is diagnosed on every tier (F61, via F36).
trap '((n++ < 2)) && kill -USR1 $$
echo "a$n $LINENO"
foo' USR1

kill -USR1 $$
trap - USR1
printf 'cat << A << B\nx' > s2776.sh; . ./s2776.sh; echo "src $?"
printf 'cat << A << B\nx\ny\n' > s2776.sh; . ./s2776.sh
e() { eval "$1"; echo "st $?"; }
e 'echo $(( i ? $v ? 1 : 2 : 3 ))'
e 'echo $(( 0 ? 1 : a && $a ))x'
e 'echo $[(FUNCNAME) ? $b : x]'
i=0; while [ $i -lt 150 ]; do e 'echo $(( 1 ? $w ? 1 : 2 : 3 ))'; i=$((i + 1)); done 2>&1 | sort | uniq -c
rm -f s2776.sh
