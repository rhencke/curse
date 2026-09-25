# Loops and case the compiled tier used to hand to the interpreter: for (( )) slots the
# arith codegen refuses (rt.arith_slot), element writes in a slot, while (( )) reading
# $LINENO/$RANDOM, for-in words through rt.word_fields, a case subject through
# rt.word_str, and a malformed [[ ]] (a fatal syntax error, last).
a=(0 0 0 0)
for (( i = 0; i < 4; a[i] = i * 2, i++ )); do :; done; echo "${a[*]} i=$i"
for (( j = 0, k = 5; (k -= 1) > 2; j++ )); do echo "j=$j k=$k"; done
for (( x = LINENO; x < LINENO + 2; x++ )); do echo x=$x; done
for (( n = 0; n < 3; n++ )); do (( n == 1 )) && continue; echo n=$n; done
for (( m = '3'; m < 5; m++ )); do echo m; done; echo st=$?
for (( q = 0; q < 3; q += 1 / (q - q) )); do echo q=$q; done; echo st=$?
f() { local c; for (( c = 0; c < 2; b[c++] = c )); do :; done; echo "${b[@]}"; }; f
n=0
while (( LINENO > 0 && n < 2 )); do n=$((n+1)); echo $n; done
until (( RANDOM < 0 || n > 3 )); do n=$((n+1)); done; echo $n
set -- a "b c"
for x in ${1:+"$@"} z; do echo "[$x]"; done
f() { local i=0; for w in X${u-"$@"}Y $((i+=2)) ${a[$(echo 0)]:-q}; do echo "<$w> i=$i"; done; }
f p "q r"
y='bad name'; for v in 1 ${!y} 2; do echo $v; done; echo st=$?
echo end
declare -A A=([k]=v)
case ${A[$(echo k)]} in v) echo yes;; *) echo no;; esac
case ${u-"a b"} in "a b") echo ab;; esac
[[ a b ]]
echo notreached
