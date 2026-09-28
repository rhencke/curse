# Pinned bash behaviour: arithmetic source text is expanded as if in double quotes
# (expand_arith_string). Text with a `$`, `` ` `` or `~` is word-expanded — a backslash
# before $ ` " \ goes, and a subscript is expanded on its own and quoted again; text with
# none of those only has its quotes removed — every `"`, and a backslash before $ ` " \ —
# before it is evaluated. Errors show the text as evaluated.
exec 2>&1
declare -A A; A[\"]=2; A[x]=3; A['\x']=4; A['$x']=5; A['\']=6
x=1; a=(10 11 12)
echo $(( \" )); echo "st=$?"
echo $(( \\ )); echo "st=$?"
echo $(( \$x + 1 )); echo "st=$?"
echo $(( \` )); echo "st=$?"
echo $(( 1 \+ 2 )); echo "st=$?"
echo "$(( \" ))"; echo "st=$?"
(( \" )); echo "st=$?"
(( \$x == 3 )); echo "st=$?"
a[\"]=1; echo "st=$?"
echo $(( A[\x] )) $(( A[\$x] )) $(( A[\\x] )) $(( A[\\\\] )); echo "st=$?"
echo $(( A[\\] )); echo "st=$?"
echo $(( A[\"] )); echo "st=$?"
echo $(( A[a\\] )); echo "st=$?"
echo $(( a[\$x] )); echo "st=$?"
(( A[\\] == 6 )); echo "st=$?"
f() { echo $(( \" + $1 )); echo "f $?"; }
f 1
for ((i = 0; i < 150; i++)); do
	echo $(( A[\\x] + A[\x] ))
	( echo $(( \" + i )) )
	( (( A[\\] )) )
done 2>&1 | sort | uniq -c
