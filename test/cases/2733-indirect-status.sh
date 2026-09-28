# `${!?}` is indirect expansion through $? (bash's VALID_INDIR_PARAM), and an operator after
# the `?` applies to that — never `${!?word}` on $!. Other text after the `?` names no
# parameter: a bad substitution (fuzz F34). In posix mode `?` isn't one: `${!?word}` is $!.
set -- a b
( set -o posix; echo "[${!?}]"; echo "not reached" ); echo "posix $?"
( set -o posix; : & x=${!?w]}; echo "posix2 $? ${x:+set}" )
false; echo "[${!?}]"
true; echo "[${!?}]" "[${!?:-w}]" "[${!?-w}]" "[${!?%S}]" "[${!??}]" "[${!?@Q}]"
false; echo "[${!?:+alt}]" "[${!?/b/B}]"
eval 'echo "${!?x]}"'; echo "a $?"
eval 'echo "${!?x}"'; echo "b $?"
eval 'echo "${!?^}"'; echo "c $?"
f() { false; echo "function [${!?}]"; eval 'y=${!?z}'; echo "function $?"; }; f
printf 'false; echo "[${!?}]"\necho "${!?q}"\necho after\n' > s2733.sh; . ./s2733.sh; echo "source $?"
trap 'false; echo "trap [${!?}]"' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do false; echo "${!?}"; (eval 'echo "${!?w}"'); i=$((i + 1)); done 2>&1 | sort | uniq -c
rm -f s2733.sh
