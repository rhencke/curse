# An assignment operator after an operand that is no variable is "attempted assignment to
# non-variable" wherever bash reads an assignment expression: the top level, inside ( ), a
# ternary's middle. curse said "`:' expected" / "missing `)'" there (fuzz F74).
e() { eval "$1"; echo "st $?"; }
e 'echo $(( 1 ? (0) ? ~x *= 1 : 2 : 3 ))'
e 'echo $(( ((b) ^ A /= 2) ))'
e 'echo $(( 1 ? ~x *= 1 : 2 ))'
e 'echo $(( (0) ? ~x = 1 : 2 ))'
e 'echo $(( (x) = 2 ))'
e 'echo $(( 1 ? (x) = 2 : 3 ))'
e 'echo $(( (1 + 2 == 3) )) $(( 1 ? 5 == 5 : 2 )) $(( (y = 4) + y ))'
e '(( (z) += 1 ))'
i=0; while [ $i -lt 150 ]; do ( echo $(( (i) = 1 )) ); i=$((i + 1)); done 2>&1 | sort | uniq -c
