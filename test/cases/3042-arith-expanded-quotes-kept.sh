# Double quotes that come from an EXPANSION are characters to the arithmetic: bash strips
# only the source text's quotes (`$(( "1" + 2 ))` is 3), so `e='2**"1"'; $(( $e ))` is an
# operand-expected error naming `"1"`. curse stripped them from the expanded text too (fuzz F101).
t() { local e=$1; ( echo "$(( $e ))" ); echo "st $?"; }
t '2**"1"'
t 'up="1"'
t '"1"A[1]'
t '"1" + 1'
e='"3"'; ( echo $(( $e * 2 )) ); echo "st $?"
x='"2"'; ( echo $(( x )) ); echo "var $?"
[[ 1 -eq '"1"' ]]; echo "cond $?"
a=(5 6); t 'a["1"]'
echo "$(( "1" + 2 ))" $(( "1+2"*3 ))
eval 't "\"4\""'
printf 't "(\\"5\\")"\n' > s3042.sh; . ./s3042.sh
trap 't "7-\"1\""' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do t "\"$i\"+1"; i=$((i + 1)); done 2>&1 | sed 's/[0-9][0-9]*/N/g' | sort | uniq -c
rm -f s3042.sh
