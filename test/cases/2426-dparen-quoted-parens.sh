# A `$(( … ))` / `(( … ))` body ends at the first `)` at paren depth 0, where parens inside
# quotes and nested expansions don't count (bash reads it with parse_matched_pair): one end
# rule decides both whether `((` is arithmetic and where its body stops.
x=3
echo $(( ${x:-")"} + 1 ))
(( ${x:-")"} > 2 )) && echo big
echo $(( $(echo "(" >/dev/null; echo 2) * 3 ))
echo $(( `echo ')' >/dev/null; echo 4` + 1 ))
for (( k = 0; k < ${x:-")"}; k++ )); do :; done; echo "k=$k"
echo "$(( ${x:-"("} + 2 ))"
# hot: compiled after OSR, and in a function called often
f() { echo $(( ${x:-")"} * 2 )); }
for i in $(seq 200); do f; s=$(( ${x:-")"} + i )); done | sort | uniq -c
echo "s=$s"
eval 'echo $(( ${x:-")"} - 1 ))'
# unset: the default ")" makes the expression bad — an ARITHMETIC error at run time
( y=$(( ${u:-")"} + 1 )); echo "y=$y" ) 2>&1 | sed 's/^[^:]*: line [0-9]*: //'
echo "st=${PIPESTATUS[0]}"
