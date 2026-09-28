# Inside ${…} a "…" nests its own expansions, as parse_matched_pair reads it: in
# `"${x%${}"${"}"…` the `${` in the inner "…" is still open at the end of the input, so the
# text is bash's syntax error `unexpected EOF while looking for matching `}'` (a $[…] in a
# ${…} likewise). The word was accepted whole, and re-reading its operand at expansion
# raised the scanner's error as an escaped Lua error (fuzz F48).
x=1
eval 'echo "${x%${}"${"}"; echo after'; echo "eval $?"
eval 'echo "${x%${}"${; echo after'; echo "eval2 $?"
eval 'echo "${x#$[}"; echo after'; echo "eval3 $?"
eval 'echo ${x:-$[}; echo after'; echo "eval4 $?"
eval 'x=abc; echo "${x%"$(echo c)"}" ${x#"${x%?}"} "${x/"${x#a}"/-}"'
printf 'echo "${x%%${}"${"}"\necho after\n' > s2729.sh
. ./s2729.sh; echo "source $?"
f() { eval 'echo "${x%${"}";'; echo "function $?"; }; f
trap 'eval "echo \"\${x%\${}\"\${\"}\""; echo "trap $?"' USR1; kill -USR1 $$; trap - USR1
j=0; while [ $j -lt 150 ]; do eval 'echo "${x%${}"${"}"'; echo "st $?"; eval 'echo "${x%"${x#?}"}"'; j=$((j + 1)); done 2>&1 | sort | uniq -c
rm -f s2729.sh
