# expr.c: shell arithmetic -- operators, precedence/associativity, ++/-- parse
# rules, bases, overflow, noeval short-circuiting, recursive variable values,
# evaluate-while-parsing side effects, and the exact evalerror text
# ("EXPR: MSG (error token is "TOK")"), incl. which prefix of EXPR is shown.
t() { ( eval "$1" ) 2>&1 | tr '\r' R | sed 's/^.*line [0-9]*: //'; echo "st=${PIPESTATUS[0]}"; }

# precedence / associativity / unary stacking
echo $(( 1 + 2 * 3 ** 2 )) $(( 2 ** 3 ** 2 )) $(( -2 ** 2 )) $(( 1 << 2 + 1 )) $(( 6 & 3 ^ 1 | 8 ))
echo $(( 10 - 3 - 2 )) $(( 100 / 10 / 5 )) $(( 1 < 2 < 3 )) $(( 1 || 0 && 0 )) $(( 0 ? 2 : 0 ? 4 : 5 ))
echo $(( !0 )) $(( ~~5 )) $(( - - 3 )) $(( -+-3 )) $(( !-~1 )) $(( + + + 4 )) $(( -7 / 2 )) $(( 7 % -2 ))
# ++/-- lexing: x+++y, x---y, - -x, +++x, 3 --x, ++x++, x++ ++
x=5; y=2; echo $(( x+++y )) $x $y; x=5; echo $(( x---y )) $x; x=5; echo $(( - -x )) $(( +++x )) $x
x=4; echo $(( x-- - --x )) x=$x; x=4; echo $(( ++ x )) $(( -- x )) x=$x; echo $(( --5 )) $(( ++4 ))
t 'x=4; echo $(( 3 --x ))'
t 'x=1; echo $(( ++x++ ))'
t 'x=1; echo $(( x++ ++ ))'
t 'x=1; echo $(( x++ = 3 ))'
t 'echo $(( (x) = 4 ))'
# assignment operators, chained, on array/assoc elements, recursive values
a=5; (( a += 3, a -= 1, a *= 2, a /= 3, a %= 3 )); echo $a
a=1; (( a <<= 4, a >>= 1, a |= 3, a &= 10, a ^= 15 )); echo $a; b=2; echo $(( a += b += 3 )) $a $b
arr=(1 2 3); (( arr[1] += 10, arr[2]++, ++arr[0] )); echo "${arr[@]}"
declare -A h; (( h[x] += 4, h[y]++ )); echo "${h[x]} ${h[y]}"
x="y"; y=3; (( x += 2 )); echo x=$x
x="1+2"; (( x *= 2 )); echo x=$x; x="1+2"; (( x++ )); echo x=$x; x="1+2"; let '++x'; echo x=$x
x="1+2"; echo $(( x -= 1 )); a=("1+2"); (( a[0] += 1 )); echo ${a[0]}
a=(1 2); b="a[1]"; echo $(( b + 1 )) $(( b = 9 )) "${a[@]}"
# side effects inside subscripts, incl. function locals
i=0; arr=(); (( arr[i++] = 5, arr[i++] = 6 )); echo "${arr[@]} i=$i"
sub() { local i=0; local -a arr; (( arr[i++] = 5 )); (( arr[++i] = 7 )); x=$(( arr[i++] + 1 )); echo "${!arr[@]} i=$i x=$x"; }; sub
# bases
echo $(( 2#101 )) $(( 36#z )) $(( 36#Z )) $(( 64#a )) $(( 64#A )) $(( 64#@ )) $(( 64#_ )) $(( 0X1F )) $(( 017 )) $(( 00 )) $(( 10#012 )) $(( 0x + 1 ))
t 'echo $(( 2#102 ))'
t 'echo $(( 1 + 65#1 ))'
t 'echo $(( 0#1 ))'
t 'echo $(( 2# ))'
t 'echo $(( 0x1#1 ))'
t 'echo $(( 2#1#1 ))'
t 'echo $(( 12abc + 1 ))'
# base errors name the expression only up to the end of the bad number
t 'echo $(( 1 + 09 + 2 ))'
t 'echo $(( (08) ))'
t 'n=1; x=$(( n=08, 1 )); echo x=$x'
t 'let "y = 4#5 + 1"'
t '(( z = 3#4 ))'
t 'declare -i di; di="5 + 09"'
t 'echo $(( 0 && 08 ))'
# overflow wraps; INT64_MIN / -1 and % -1; shifts use count mod 64
echo $(( 9223372036854775807 + 1 )) $(( 2 ** 64 )) $(( 3 ** 40 )) $(( 0xffffffffffffffff )) $(( 9223372036854775808 ))
echo $(( -9223372036854775808 / -1 )) $(( -9223372036854775808 % -1 ))
m=-9223372036854775808; (( m /= -1 )); echo $m; (( m %= -1 )); echo $m
echo $(( -1 ** 9223372036854775807 )) $(( 1 ** 3000000000 ))  # ipow: square-and-multiply, not a loop
echo $(( 1 << 63 )) $(( 1 << 64 )) $(( 1 << -1 )) $(( -8 >> 1 )) $(( -1 >> 70 )) $(( 8 >> -1 ))
# division by zero / exponent < 0: error token starts at the divisor
t 'echo $(( 5/0+1 ))'
t 'echo $(( (5) / (0) ))'
t 'echo $(( 1 + 5 /  0 + 2 ))'
t 'x=3; (( x %= 0 )); echo x=$x'
t 'echo $(( 2 ** 0 ** -1 ))'
# noeval: untaken branches suppress side effects and division errors,
# but NOT the exponent check or lexical errors
x=0; echo $(( 0 && x++ )) $(( 1 || x++ )) $(( 1 ? 3 : x++ )) $(( 0 ? x++ : 4 )) $(( 0 && 1/0 )) $(( 0 && (x /= 0) )) x=$x
x="1/0"; echo $(( 0 && x )) $(( 1 || x )); x=0; echo $(( 1 ? x=8 : 9 )) x=$x
t 'echo $(( 0 && 2 ** -1 ))'
t 'echo $(( 0 && (1 +) ))'
t 'x=0; echo $(( 0 ? x=8 : x=9 ))'
# syntax errors: exact message kinds
t 'echo $(( 1 $ 2 ))'
t 'echo $(( 1.5 ))'
t 'echo $(( 3 ! 4 ))'
t 'echo $(( 1 ? 2 ))'
t 'echo $(( 1 ? : 2 ))'
t 'echo $(( 3 =< 4 ))'
t 'x=2; echo $(( x **= 2 ))'
t 'x=1; echo $(( x ; ))'
t 'echo $(( a[1 ))'
t 'echo $((   1 +   ))'
# variables holding expressions: errors name the inner expression
t 'a="1 +"; echo $(( 3 + a ))'
t 'a="(1"; echo $(( a ))'
t 'a="b"; b="a"; echo $(( a + 1 ))'
t 'x=$'"'"'1\r+ 1'"'"'; echo $(( x ))'
a=""; b="  "; echo $(( a + 1 )) $(( b + 1 )) $(( nosuch + 1 ))
# bad subscripts are non-fatal
t 'a=(1 2 3); echo $(( a[@] )) $(( a[*] ))'
t 'echo $(( a[] ))'
t 'a=(10 20 30); (( a[-4] = 1 )); echo next $?'
t 'a=(10 20 30); echo $(( a[-4] )); echo next $?'
# set -u: declared-but-unset and indirectly-named variables are unbound
t 'set -u; declare x; echo $(( x + 1 )); echo after'
t 'set -u; declare -A hh; echo $(( hh[k] )); echo after'
t 'set -u; x=nosuch; echo $(( x )); echo after'
t 'set -u; echo $(( 0 && nosuch )) $(( 1 ? 2 : nosuch )); echo after'
# bash evaluates while parsing: side effects before a syntax error stick
t 'a=1; let "b=a++ +"; echo a=$a'
t 'a=1; (( b=a++ + )); echo a=$a'
t 'c=0; (( c=5, 1 +/ 2 )); echo c=$c'
t 'x=0; (( x=1, 1/0 )); echo x=$x'
# ... but a bad CHARACTER is met as the lookahead: the pending assignment never ran
t 'x=1 y=0; let "x++, y = 3 @"; echo x=$x y=$y; let "(y=2) # c"; echo y=$y'
# arithmetic for: an error is a ((: failure, the shell goes on
t 'for (( i=0; i<1/0; i++ )); do :; done; echo next $?'
t 'for (( i=0; i<2; i+=1/0 )); do echo i$i; done; echo next $?'
# errors inside function bodies (compiled path)
fe1() { echo $(( 1/0 )); echo no; }; fe1 2>&1 | sed 's/^.*line [0-9]*: //'; echo r1
fe2() { if (( 2 ** -1 )); then echo T; else echo F; fi; }; fe2 2>&1 | sed 's/^.*line [0-9]*: //'
fe3() { echo $(( 1 $ 2 )); }; fe3 2>&1 | sed 's/^.*line [0-9]*: //'
fe4() { echo $(( 1 +/ 2 )); }; fe4 2>&1 | sed 's/^.*line [0-9]*: //'
# (( )) conditions set $? and fail like the (( )) command; subscript side effects in loops
fe5() { x='1 +'; if (( x )); then echo T; else echo F; fi; false; if (( 1 )); then echo s=$?; fi; y=0; while (( y < 3 / y )); do :; done; echo w=$?; }; fe5 2>&1 | sed 's/^.*line [0-9]*: //'
fe6() { local i=0 k; local -a q; for ((k=0; k<3; k++)); do (( q[i++] = k )); done; echo "${q[@]} i=$i"; }; fe6
fe7() { local n=3 s=0 i; for ((i=0; i<n/i; i++)); do s=1; done; echo "s=$s st=$?"; }; fe7 2>&1 | sed 's/^.*line [0-9]*: //'
# outside expr.c: ${#a[@]} under set -u, an unset ${x:off} evaluates nothing, `#` in $(( ))
t 'set -u; echo ${#nosuch[@]}; echo after'
t 'set -u; a=(); s=x; echo ${#a[@]}; echo ${#s[@]}; echo after'
t 'unset x; echo "[${x:1/0}]"; x=; echo "[${x:1/0}]"; echo after'
t 'echo $(( 1 # 2 )); echo after'
echo end
