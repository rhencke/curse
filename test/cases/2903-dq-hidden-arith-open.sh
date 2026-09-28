# Expanding a "…" word extracts every $( … ) / $(( … )) in it — also where the parser saw
# none: after the `$` of `$$`, or inside a ${…} operand's single quotes (in "…" they don't
# quote). A $(( … )) that never closes is "bad substitution: no closing `)' in WORD" (the
# whole word; status 1, the command not run) even when the operand isn't used; an open
# $( … ) is a command substitution's syntax error (leftover L5).
u=; echo "${u-'$(('}"; echo "st $?"
unset u; echo "${u-'$(('}"; echo "st $?"
u=; echo "${u#'$(('}"; echo "st $?"
u=; echo "${u-'$((1))'}" "${u-'$((' }"; echo "st $?"
u=; echo "${u-'$('}"; echo "st $?"
x="$$(("; echo "st $?"
echo a"x$$((y"b"c" d; echo "st $?"
echo "$$(( ')' "; echo "st $?"
echo "$$(( ( 1 ) ))" | tr -d 0-9
echo ${u-'$(('} ok
f() { echo "${u-'$(('}"; echo "f $?"; }; f; echo "st $?"
eval 'echo "$$((1)"'; echo "eval $?"
printf 'echo "${u-'"'"'$(('"'"'}"\necho "src $?"\n' > s2903.sh; . ./s2903.sh; echo "st $?"
trap 'echo "$$(("; echo "trap $?"' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do y="$$(( $i"; i=$((i + 1)); done; echo "loop $? $i"
i=0; while [ $i -lt 150 ]; do eval 'y="$$(( $i"'; i=$((i + 1)); done 2>&1 | sort | uniq -c
rm -f s2903.sh
