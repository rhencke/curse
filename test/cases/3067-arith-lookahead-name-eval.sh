# bash evaluates arithmetic while it parses: reading a NAME token (its one-token lookahead)
# evaluates the variable at once unless an `=` follows — so where that name is the
# unexpected token of a syntax error, its own error comes first (`p='*o*'; $(( 1 p ))`:
# operand expected at `*o*`), and in a short-circuited operand it isn't read. curse
# reported the syntax error without reading it (fuzz F107: `${t:gggg:+$@}` evaluates
# `+p1 p 2  *`).
p='*o*' q=1+ r=7
e() { eval "$1"; echo "st $?"; }
e 'echo $(( 1 p ))'
e 'echo $(( 1 p 2 ))'
e 'echo $(( 3 q ))'
e 'echo $(( 3 r ))'
e 'echo $(( (1 p) ))'
e 'echo $(( 1 ? 2 p : 3 ))'
e 'echo $(( 0 ? 2 p : 3 ))'
e 'echo $(( 1 x[1] ))'
e 'a=("*o*"); echo $(( 1 a[0] ))'
e 'echo $(( 1 p++ ))'
e 'echo $(( 1 p=2 ))'
e 'echo $(( 1 p+=2 ))'
e 'echo $(( 1 p==2 ))'
e 'echo $(( 0 && 1 p ))'
e 'echo $(( 0 || 1 p ))'
e 'echo $(( 1 ? 2 : 3 p ))'
e 'echo $(( 0 ? 2 : 3 p ))'
e 'echo $(( -1 p ))'
e 'echo $(( q p ))'
e 'x=1; : $(( x = 5 p )); echo x=$x'
e 'x=1; : $(( x = 5 r )); echo x=$x'
e 'x=1; : $(( x++ p )); echo x=$x'
e 'let "1 p"'
e '(( 1 p ))'
set -- p1 'p 2' '' '*'; t=$'\t x \t'
e 'echo ${t:gggg:+$@}'
e 'echo ${t:1:2 p}'
printf 'echo $(( 2 p ))\n' > s3067.sh; . ./s3067.sh; echo "src $?"
trap 'echo $(( 3 p ))' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do ( echo $(( i p )) ); i=$((i + 1)); done 2>&1 | sort | uniq -c
rm -f s3067.sh
