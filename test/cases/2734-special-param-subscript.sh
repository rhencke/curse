# A subscript on a special or positional parameter — `${*[0]}`, `${@[0]}`, `${1[0]}`,
# `${2[-1]~}`, `${#*[0]}` — is a bad substitution (bash reads a subscript after a NAME
# only): curse read the parameter and dropped the subscript (fuzz F35).
set -- a b
eval 'echo "${*[0]}"'; echo "a $?"
eval 'echo "${@[0]}"'; echo "b $?"
eval 'echo "${1[0]}"'; echo "c $?"
eval 'echo "${2[-1]~}"'; echo "d $?"
eval 'echo "${*[-1]@a}"'; echo "e $?"
eval 'echo "${#*[0]}" "${!*[0]}"'; echo "f $?"
eval 'echo "${*[0]:-x}"'; echo "g $?"
echo ${*} ${@:1} "${#1}" ${#*} ${1:-x} ${!#} "${@: -1}" "${?}"
f() { eval 'echo "${1[0]}"'; echo "function $?"; }; f x
printf 'echo "${@[1]}"\necho after\n' > s2734.sh; . ./s2734.sh; echo "source $?"
trap 'eval "echo \${*[0]}"; echo "trap $?"' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do (eval 'echo "${2[0]}"'); echo "st $? ${2}"; i=$((i + 1)); done 2>&1 | sort | uniq -c
rm -f s2734.sh
