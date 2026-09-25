# =~ RHS forms emit_regex_glob refuses (quoted text inside a bracket expression, a
# word-initial ~): the leaf takes the shared regex-word expander (rt.db_regex_rhs).
[[ a =~ ["a-z"] ]]; echo $? ${BASH_REMATCH[@]}
[[ '-' =~ ['a-z'] ]]; echo $?
[[ ']' =~ [']'] ]]; echo $?
[[ '.' =~ ["."] ]]; echo $? ; [[ 'x' =~ ["."] ]]; echo $?
HOME=/h; [[ /h/x =~ ~/x ]]; echo tilde=$?
[[ foo-1.2-x-007.tgz =~ ([^-]+)-([^-]+)-([^-]+)-0*([1-9][0-9]*)\.tgz ]] && echo "${BASH_REMATCH[4]}"
x=1; [[ $x == 1 && ab =~ a"b" ]] && echo nest
