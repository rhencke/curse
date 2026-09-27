# Pinned bash behaviour: a function name is any WORD (execute_intern_function's
# check_identifier only rejects `$` words and, in posix mode, non-identifiers): `!x()`
# names `!x` (a `!` negates only as a word of its own), `-x()`, `=()` and `==x=()` define
# functions too; `declare -F` lists a name holding `=`, and `declare -f a-b=c` shows it —
# only a NAME=… assignment word is "cannot use `-f' to make functions".
!x() { echo "bang $1"; }
-x() { echo "dash $1"; }
a-b=c() { echo "eq $1"; }
=() { echo "lone $1"; }
==x=() { :; }
!x 1; -x 2; a-b=c 3; = 4
declare -F
declare -f a-b=c; echo "st $?"
declare -f x=y 2>/dev/null; echo "st $?"
! x() { echo x; }; echo "neg $?"
eval '!y() { echo y; }'; !y
n=0
for ((i = 0; i < 200; i++)); do
	!x "$i" >/dev/null && -x "$i" >/dev/null && a-b=c >/dev/null && n=$((n + 1))
	eval '!z'$((i % 3))'() { echo z; }'
done
echo "$n"; declare -F | grep -c 'z[0-9]'
