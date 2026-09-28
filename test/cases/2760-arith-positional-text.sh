# A positional parameter in arithmetic is substituted as TEXT before the expression is
# parsed, like $name: `set -- 1+2; $(( $1*3 ))` is 1+2*3 = 7, not 3*3 (leftover L1).
# A value that is a plain number binds like an atom (octal/hex text keeps its base).
# (POSIX: dash agrees)
set -- 1+2 5 010 0x10
echo $(( $1*3 )) $(( $1 * 3 )) $(( 3*$1 )) $(($2*3)) $(( ${1}*3 )) $(( $3*3 )) $(( $4 ))
x=$(( 2*$1 )); echo "$x"
f() { echo $(( $1*3 )) $(( $1 - 1 )); }
f 1+2; f 4; f 010; f "2 + 2"; f -3
g() { r=$(( $1 * 2 )); echo "$r"; }
i=0
while [ $i -lt 150 ]; do
	g "$i+1"; g "$i"; g $((i + 1))
	i=$((i + 1))
done | sort | uniq -c | sort -k2n | tail -3
j=0
while [ $j -lt 150 ]; do set -- "$j-1"; s=$(( $1*2 )); j=$((j + 1)); done; echo "$s"
eval 'set -- 2+3; echo $(( $1*4 ))'
printf 'set -- 1+1; echo $(( $1*5 ))\n' > s2760.sh; . ./s2760.sh
trap 'echo trap $(( $1*3 ))' USR1; set -- 4+4; kill -USR1 $$; trap - USR1
h() { echo $(( $2*3 )); }; (h 1) 2>/dev/null || echo "status $?"
rm -f s2760.sh
