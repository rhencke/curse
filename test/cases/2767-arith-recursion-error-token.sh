# bash's "expression recursion level exceeded" is reported in the ENCLOSING expression, at
# the token of the variable whose value would nest one level too deep (`x=1+x` → token
# "x"); a value that fails to parse is still read up to its error first, so a variable
# before it recurses (`(( !!BASH_COMMAND & $A ))`). curse named the whole value, missed the
# recursion there ("syntax error in expression"), and compiled lost the line (fuzz F72).
e() { eval "$1"; echo "st $?"; }
e '(( BASH_COMMAND ))'
e '(( !!BASH_COMMAND & $A ))'
e 'x=x; echo $((x))'
e 'x="1+x"; echo $((x))'
e 'x="1 + x * 2"; echo $(( 3 + x ))'
e 'a=b; b="a+1"; echo $(( 5 * a ))'
e 'x="(x)"; echo $((x))'
e 'a=(x); x="a[0]"; echo $((x))'
(( BASH_COMMAND )); echo "top $?"
f() { local y="y+1"; echo $(( y )); }; f; echo "f $?"
i=0; while [ $i -lt 150 ]; do x=x; ( echo $((x)) ); i=$((i + 1)); done 2>&1 | sort | uniq -c
