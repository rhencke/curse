# A bad substitution inside arithmetic names the WHOLE expression text, its blanks kept:
# bash expands `(( ${} ))`'s text as one word, so the message is ` ${} : bad substitution`
# (curse trimmed it to `${}`). A for (( )) slot drops only its leading blanks; an indexed
# array's `[k]=v` element names itself with its brackets quoted; a subscript's error is not
# reported a second time as an arithmetic syntax error. An integer variable's value is
# never expanded again: `declare -i n; n='1+${x}'` is bash's `operand expected` (fuzz F120).
x=1
( (( ${} )) ); echo "s $?"
( ((  ${}  )) ); echo "s $?"
( (( 1 + ${} )) ); echo "s $?"
( echo $(( 2 + ${x@Z} )) ); echo "s $?"
( echo "$(( ${} ))" ); echo "s $?"
( echo $[ ${} ] ); echo "s $?"
( for ((  i = ${} ; i < 1; i++ )); do :; done ); echo "s $?"
( for (( i = 0 ;  i < ${}  ; i++ )); do :; done ); echo "s $?"
( echo ${a[ ${} ]} ); echo "s $?"
( a[ ${} ]=1 ); echo "s $?"
( echo ${x: ${} } ); echo "s $?"
( a=( [ ${} ]=1 ) ); echo "s $?"
( a=( [0]=${} ) ); echo "s $?"
( declare -i n; n=' ${} '; echo "not reached" ); echo "s $?"
( declare -i n; n='1+${x}' ); echo "s $?"
( declare -i n; n='1+$x' ); echo "s $?"
( f() { local -i l='${x}+1'; }; f ); echo "s $?"
f() { (( ${} )); }
( f ); echo "function: $?"
( eval '(( 3 * ${} ))' ); echo "eval: $?"
trap '( (( ${}  )) ); echo "trap: $?"' USR1
kill -USR1 $$
for ((r = 0; r < 150; r++)); do
    ( (( r + ${} )) ) 2> /dev/null
    st=$st$?
done
echo "${#st} ${st:0:3}"
( for ((r = 0; r < 150; r++)); do (( r < 149 )) || (( r + ${} )); done )
echo "s $?"
