# Arithmetic blanks are expr.c's cr_whitespace — space, tab, newline — so a form feed,
# vertical tab or carriage return is a bad character, never an empty (0) expression;
# and a $'…' in source arithmetic is translated and single-quoted as bash's parser does
# (`(( $'\f' ))` reads `'<FF>'`). curse took \f \v \r as blanks (fuzz F104).
t() { local e=$1; ( echo "$(( $e ))" ); echo "st $?"; }
t $'\f\f'
t $'\v'
t $'\r'
t $'1\f+2'
t $' \t\n'
x=$'\f'; ( echo $(( x )) ); echo "var $?"
x=$'5\f'; ( echo $(( x + 1 )) ); echo "var $?"
( let $'\f' ); echo "let $?"
( (( $'\f' )) ); echo "arith $?"
( (( $'\x31' )) ); echo "arith $?"
( echo $(( 1+$'a\'b' )) ); echo "st $?"
echo $(( $"2" + 1 )) $(( "" )) $(( " " ))
eval 't $'"'"'\f1'"'"
printf 't "$(printf "\\f")"\n' > s3045.sh; . ./s3045.sh
trap 't $'"'"'2\v'"'"'' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do t "$i"$'\f'; i=$((i + 1)); done 2>&1 | sed 's/[0-9][0-9]*/N/g' | sort | uniq -c
rm -f s3045.sh
