# An unquoted ${…} whose NAME has a subscript is re-extracted as the word expands
# (extract_dollar_brace_string): its subscript skips to its `]` past a `}` — `${a[@}]}` is
# a[@}] and `[${!a[@}]` runs to the word's end — an arith error on `@}` (leftover L13).
a=(1 2); echo [${!a[@}]; echo "st $?"
echo next
echo ${a[@}]}; echo "st $?"
echo ${a[0}]-x}; echo "st $?"
echo "[${!a[@}]"; echo "st $?"
echo x${a[1}y
echo after
f() { echo ${a[1}]}; echo "f $?"; }; f; echo "st $?"
eval 'echo [${!a[@}]'; echo "eval $?"
printf 'echo ${a[@}]}\necho "src $?"\n' > s2912.sh; . ./s2912.sh
trap 'echo ${a[@}]}; echo no' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do y=${a[@}]}; i=$((i + 1)); done 2>&1 | sort | uniq -c
rm -f s2912.sh
