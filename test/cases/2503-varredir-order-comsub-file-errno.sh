# `{v}>…` (redir.c): the target is opened / duplicated FIRST — its failure is the only
# error — then moved to a free fd >= 10, and only then assigned: v is left alone when the
# open fails, a readonly v (or noassign GROUPS) is reported only after a successful open.
# A `{v}>&N` of a closed N says "redirection error: cannot duplicate fd" first.
# $(< file) / <(< file) report open(2)'s own errno (subst.c file_error), and a <()
# body's lines count from its command's line.
T=$(mktemp -d) || exit 1; cd "$T" || exit 1
: > f; : > noperm; chmod 000 noperm
readonly w=5
: {w}< /nonexistent; echo "st=$?"
: {w}> /nonexistent/dir/x; echo "st=$?"
: {w}< "f"; echo "st=$?"
: {w}>&1; echo "st=$?"
: {w}>&7; echo "st=$?"
: {w}<<<hi; echo "st=$?"
: {GROUPS}< /nonexistent; echo "st=$?"
: {GROUPS}< "f"; echo "st=$?"
: {v}</nonexistent; echo "v=$v"
: {u}>&7; echo "u=$u"
v=old; : {v}>"$v"; ls; exec {v}>&-
x=$(< "f/x"); echo "st=$? [$x]"
x=$(< ""); echo "st=$? [$x]"
x=`< "f/x"`; echo "st=$? [$x]"
if [ -r "noperm" ]; then echo "x: Permission denied"; else x=$(< "noperm") 2>&1; fi 2>&1 | sed 's/^.*: \([^:]*: [^:]*\)$/\1/'
cat <(< "f/x"); echo "st=$?"
cat <(:
echo ${nosuch?unset}); echo
f() { cat <(< "f/x"); }; f
for ((i = 0; i < 150; i++)); do
	e=$( { : {w}< /nonexistent; x=$(< "f/x"); : {q}</nonexistent; } 2>&1 ); r=$?
done
echo "$r q=$q"; echo "$e"
chmod 600 noperm; cd / && rm -rf "$T"
