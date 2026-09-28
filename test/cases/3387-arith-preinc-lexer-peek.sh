# Pinned bash behaviour: reading a NAME, bash's arithmetic lexer peeks at the token after
# it (for an `=`); a character that starts no token there is an error before anything is
# done with the name — so `++NAME @` increments nothing, while `NAME++ @` (the error comes
# a token later) does. Under assoc_expand_once a `let` subscript ends at its first `]`.
exec 2>&1
x=0 y=0 z=0
let "++x @"; echo "st=$? x=$x"
(( ++x # )); echo "st=$? x=$x"
echo $(( --y @ )); echo "st=$? y=$y"
let "z++ @"; echo "st=$? z=$z"
let "x = ++y @"; echo "st=$? x=$x y=$y"
shopt -s assoc_expand_once
declare -A a
let "++a[x']']"; echo "st=$?"; declare -p a
let "++a[x']"; echo "st=$?"; declare -p a
let "++a[q]" "++a[r']']"; echo "st=$?"; declare -p a
f() { let "++$1 @"; echo "f $? $1=${!1}"; }
f x
for ((i = 0; i < 150; i++)); do
	let "++x @"
	(( ++a[p] ))
done 2>/dev/null
echo "x=$x ${a[p]}"
