# bash's [[ ]] parser reads its tokens one at a time: a grammar error on a token
# before an unclosed quote wins (`[[ a == ⏎"b` — a newline where the right operand
# belongs); when the grammar READS the word that ran into end of input, bash reports
# parse_matched_pair's EOF error and then cond_term's, for its error token (none to
# name, or `\377'), at the end of the input — and no `syntax error near` line.
exec 2>&1
n=0
for body in '[[ a == 
"b ]]' '[[ a == "b ]]' '[[ -n 
"b ]]' '[[ a 
"b ]]' '[[ "a' '[[ a && 
"b ]]' '[[ ( a == 
"b ]]' "[[ a =~ 
'b ]]" '[[ ( "b' '[[ -n "b' '[[ a "b' '[[ a == b && "c'; do
	eval "$body"; echo "eval st=$?"
	printf '%s\necho after $?\n' "$body" > db.sh
	"$THIS_SH" db.sh; echo "file st=$?"
	printf '%s' "$body" > db.sh
	"$THIS_SH" db.sh; echo "nonl st=$?"
done 2>&1 | od -c | sed 's/^[0-7]* *//' | tr -s ' '
for i in $(seq 160); do eval '[[ a == 
"b ]]' 2>/dev/null; n=$((n + $?)); eval '[[ x == "y ]]' 2>/dev/null; n=$((n + $?)); done
echo "n=$n"
rm -f db.sh
