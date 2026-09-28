# In "…" a ${…} whose parameter has a `[` that never closes runs off the end of the word
# when bash expands it (extract_dollar_brace_string skips the subscript): "bad substitution:
# no closing `}' in WORD", the whole word as written (fuzz F32). `${#a[@}` has no subscript
# to skip (the `#` makes it an operator): its own bad substitution.
eval 'echo "${!a[@}"'; echo "a $?"
eval 'echo "x${!a[@}y"'; echo "b $?"
eval 'echo z"${a[@}"'; echo "c $?"
eval 'echo "${!a[@]{a[}"'; echo "d $?"
eval 'echo "${#a[@}"'; echo "e $?"
eval 'echo ${a[1}'; echo "f $?"
a=(1 2); echo "${a[@]}" "${a[0]:-x}" "${x:-[}" "${x#[}" "${x/[/a}"
f() { eval 'echo "${a[0}"'; echo "function $?"; }; f
printf 'echo "${a[x}"\necho after\n' > s2731.sh; . ./s2731.sh; echo "source $?"
trap 'eval "echo \"\${a[@}\""; echo "trap $?"' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do (eval 'echo "${a[@}"'); echo "st $?"; echo "${a[1]}"; i=$((i + 1)); done 2>&1 | sort | uniq -c
rm -f s2731.sh
