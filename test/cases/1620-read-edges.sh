# read: edge cases of bash's read builtin (builtins/read.def) not covered elsewhere:
# option-argument validation and its diagnostics, the early first-name check (made
# before any input is consumed), -n/-N/-d/-t/-u corners, NUL and CTLESC bytes,
# backslash at EOF, IFS trailing-delimiter rules, and assignment targets (readonly,
# -a on scalars/assoc arrays, integer/case attributes, namerefs, array elements).
e() { "$@" 2>&1 | sed 's/^.*line [0-9]*: //'; echo "st=${PIPESTATUS[0]}"; }
q() { printf '%q ' "$@"; echo; }
printf 'l1\nl2\n' > f

# --- option arguments: legal_number / uconvert / sh_validfd, with exact messages
e read -z x
e read -a
e read -n abc x <<< hi
e read -n -2 x <<< hi
e read -n 99999999999 x <<< hi
e read -n 4294967297 x <<< hello
e read -n 0x2 x <<< hi
e read -n 09x x <<< hi
e read -t abc x <<< hi
e read -t -1 x <<< hi
e read -t 1e1 x < f
e read -t ' 2' x < f
e read -t 0x10 x < f
e read -t '' x < f
e read -u abc x
e read -u 3x x
e read -u 99999999999 x
e read -u ' 7' x
exec 4> out; e read -u 4 x; exec 4>&-
e read x < .
read -n 0 x < .; echo "n0dir=$?"

# --- the first name is checked before reading: nothing is consumed (even with -a);
# a later bad name fails only after the line is read and earlier names are set
{ read 1bad; echo "st=$?"; read x; echo "x=$x"; } < f 2>&1 | sed 's/^.*line [0-9]*: //'
{ read -a arr 1bad; echo "st=$?"; read x; echo "x=$x"; } < f 2>&1 | sed 's/^.*line [0-9]*: //'
{ read 'a[x' b; echo "st=$?"; read x; echo "x=$x"; } < f 2>&1 | sed 's/^.*line [0-9]*: //'
{ read ok 'a-b' c; echo "st=$? ok=$ok"; } <<< 'p q r' 2>&1 | sed 's/^.*line [0-9]*: //'
{ read -n 0 ok; echo "st=$? ok=[$ok]"; read x; echo "x=$x"; } < f

# --- -t: 0 polls without consuming; a regular file disables the timeout; a timeout
# keeps the partial input with status 142; a bad $TMOUT is ignored
{ read -t 0 x; echo "t0=$? x=[${x-unset}]"; read x; echo "x=$x"; } < f
read -t 0 1bad < f; echo "t0bad=$?"
read -t 5 a < f; echo "tfile=$? a=$a"
{ printf 'a b c'; sleep 0.1; } | { read -t 0.01 x y; echo "st=$?"; q "$x" "$y"; }
{ printf 'x\\'; sleep 0.1; } | { read -t 0.01 a; echo "st=$?"; q "$a"; }
TMOUT=abc; read a < f; echo "tmoutbad=$? a=$a"; unset TMOUT
read -p PROMPT -s -e -i init a <<< 'y' 2>&1; echo "pse: $a"

# --- a backslash at EOF is dropped (not kept literally)
printf 'a b\\' | { read x y; echo "st=$?"; q "$x" "$y"; }
printf 'a\\' | { read; echo "st=$?"; q "$REPLY"; }
printf 'a\\' | { read -a arr; echo "st=$?"; q "${arr[@]}"; }
printf 'ab\\' | { read -N 3 x; echo "st=$?"; q "$x"; }

# --- NUL bytes are skipped unless -d ''; CTLESC/DEL bytes pass through
printf 'a\0b\0c\n' | { read a; q "$a"; }
printf 'a\0b\0c\n' | { read -n 2 a; q "$a"; }
printf 'x\001y\177z\n' | { read a; q "$a"; }
printf 'x\177y\177z\n' | { IFS=$'\177' read a b c; q "$a" "$b" "$c"; }
# IFS containing CTLESC: backslash no longer protects, and \001 splits
printf 'x\001y\001z\n' | { IFS=$'\001' read a b; q "$a" "$b"; }
IFS=$'\001:' read a b <<< 'x\:y:z'; q "$a" "$b"

# --- -n counts characters: an escaped multibyte char is one char
export LC_ALL=C.UTF-8
read -n 2 a <<< 'éàx'; q "$a"
read -n 2 a <<< '€\é'; q "$a"
LC_ALL=C

# --- IFS non-whitespace trailing-delimiter rules for the last variable
IFS=: read a b <<< 'x:y:'; q "$a" "$b"
IFS=: read a b <<< 'x:y::'; q "$a" "$b"
IFS=: read a b <<< 'x:y:z:'; q "$a" "$b"
IFS=': ' read a b <<< 'x : y : z :  '; q "$a" "$b"
read a b <<< 'x y z\ '; q "$a" "$b"
IFS=', ' read -a arr <<< ' , a ,, b , '; declare -p arr

# --- assignment targets
f1() { readonly ro=1; read b ro c <<< 'x y z'; echo "st=$? b=[$b] c=[$c]"; }; e f1
f5() { readonly REPLY=r; read <<< x; echo "st=$? R=$REPLY"; }; e f5
f2() { readonly -a ra=(1 2); read -a ra <<< 'x y'; echo "st=$? ${ra[*]}"; }; e f2
f3() { declare -A as=([k]=v); read -a as <<< 'x y'; echo "st=$? $(declare -p as)"; }; e f3
s=scalar; read -a s <<< 'x y'; declare -p s
arr=(1 2 3); read -a arr < /dev/null; echo "st=$?"; declare -p arr
read -a arr x <<< 'p q'; echo "${arr[*]} x=[$x]"
declare -i n; read n <<< '1+2'; echo "n=$n"
declare -i n2; read -n 3 n2 <<< '2+30'; echo "n2=$n2"
declare -i n3; read -d '' n3 <<< '5+5'; echo "n3=$n3"
f4() { declare -i o; read o <<< '2*3 x'; echo "after o=$o"; }; f4 2>&1 | sed 's/^.*line [0-9]*: //'
declare -u up; declare -l lo; read up lo <<< 'abc DEF'; echo "$up $lo"
declare -n r='x[2]'; unset x; read r <<< 'val'; declare -p x
read 'el[1]' 'el[3]' <<< 'x y z'; declare -p el
declare -A h; read 'h[k k]' <<< 'v w'; declare -p h
