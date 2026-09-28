# `${!a[@]x}`: after the subscript of an indirect key list, anything but an operator is
# bash's bad substitution — curse expanded the keys and used them as an indirect name
# (fuzz F31). Operators after it keep their indirect reading.
a=(1 2); x=5
eval 'echo "${!a[@]x}"'; echo "eval $?"
eval 'echo "${!a[*]while{a[@]}"'; echo "eval2 $?"
eval 'echo ${!a[@]{a[}'; echo "eval3 $?"
b=(x); echo "${!b[@]-d}" "${!b[@]@Q}" "${!b[*]:+alt}" "${!b[@]~}"
f() { eval 'echo "${!a[@][a-z]}"'; echo "function $?"; }; f
printf 'echo "${!a[@]y}"\necho after\n' > s2730.sh; . ./s2730.sh; echo "source $?"
trap 'eval "echo \${!a[@]z}"; echo "trap $?"' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do (eval 'echo "${!a[@]q}"'); echo "st $?"; echo "${!b[@]}"; i=$((i + 1)); done 2>&1 | sort | uniq -c
rm -f s2730.sh
