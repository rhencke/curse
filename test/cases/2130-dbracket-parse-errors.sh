# parse.y cond_term/cond_error: a malformed [[ ]] is a PARSE-time syntax error (the whole
# line runs nothing, status 2), reported with bash's specific message, then
# `syntax error near `TOK'` and the line. Each probe runs through eval so the file goes on.
for c in '[[ a b ]]' '[[ -z ]]' '[[ a < ]]' '[[ ( a ]]' '[[ a == b c ]]' '[[ ]]' '[[ a && ]]' \
	'[[ -q a ]]' '[[ ! ]]' 'echo x; [[ a b ]]; echo y' '[[ && a ]]' '[[ a || ]]' '[[ ( ]]' '[[ a ) ]]' \
	'[[ -z a b ]]' '[[ a -nt ]]' '[[ ! ! ]]' '[[ ( a b ) ]]' '[[ a =~ ]]' \
	'[[ -f ]]; echo' '[[ -f ]]>f' '[[ x -eq ]]|cat' '[[ -f ]]&& echo'; do
	eval "$c" 2>&1 | sed 's/^.*line [0-9]*: //'; eval "$c" 2>/dev/null; echo "st=$?"
done
# well-formed ones still run
[[ a && ( b || ! c ) ]] && echo ok; [[ "-z" ]] && echo quoted-op-is-a-word; [[ a == "==" ]]; echo $?
# only bash's own unary operators are unary: any other -X is a plain word
[[ -y ]] && echo dash-y-is-a-word; [[ -Q < b ]]; echo $?; [[ -Q = -Q && ! ( -Z ) ]] && echo y2
