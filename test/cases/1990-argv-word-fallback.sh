# Command words the compiled argv builder expands through the one-word expander
# (rt.word_fields) or natively as segments: ${…} test operators whose word holds "$@",
# @Q/@A transforms, $(…)/$((…)) glued to text, nested-side-effect and malformed
# $((…)) (an arith syntax error discards the rest of the line), and lifted loop
# variables written by the expansion (${z:=…}, $((i+=2))).
recho() { printf '<%s>' "$@"; echo; }
set -- a "b c" d
echo ${1:+"$@"} x
echo X${u-"$@"}Y
recho ${1:+"$@"} ${u-"a  b"} ${1:-no} ${9:-nine} "${1:+$@}"
f() { local i=0; while (( i < 3 )); do echo w ${z:=$i} $(( i -- - 4 )) $((i+=2)); i=$((i+1)); done; echo z=$z i=$i; }
f
echo pre$(echo a b)post "q$(echo c  d)q" $((3+4))x
recho pre$(echo a b)post "q$(echo c  d)q" $((3+4))x
x=abc; echo ${x@Q} "${x@A}" ${x/b/"$1"}
echo $(( 4 ++ )) no; echo nextline $?
echo reached $?
g() { y='bad name'; echo ${!y} no; echo notreached; }
g; echo afterg $?
arr=(a b c); echo "${arr[@]@Q}" ${arr[@]/b/X}
for k in 1 2; do recho ${1:+"$@"} $((k*2))$(echo -$k); done
printf '%s|' ${u-"p q"} $(( 2 ** 3 )); echo
: ${w:=assigned}; echo w=$w
