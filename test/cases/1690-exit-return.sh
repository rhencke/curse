# exit / return, from bash's builtins/exit.def, return.def and get_exitstat
# (common.c): an optional `--`; the status is legal_number & 255 (exact for
# 64-bit values; `1e1`, `0x3`, overflow are "numeric argument required", 2);
# a bare `exit` in the EXIT trap uses the status from before the trap ran;
# `logout` outside a login shell; `return` outside a function is reported (2),
# also as a pipeline stage; returns from sourced files, subshells and $( ).
e() { sed 's/^.*line [0-9]*: //'; }
for a in -- '-- 3' "' 3 '" +3 -1 256 257 9223372036854775807 -9223372036854775808; do
  eval "( exit $a )"; echo "exit $a -> $?"
done
for a in 1e1 0x3 '' 3x 99999999999999999999 -x; do
  ( exit "$a" ) 2>&1 | e; ( exit "$a" ) 2>/dev/null; echo "exit [$a] -> $?"
done
( exit 3 4; echo "after too-many st=$?" ) 2>&1 | e; echo "sub st=${PIPESTATUS[0]}"
( false; exit ); echo "bare exit -> $?"
( trap 'echo "in trap \$?=$?"; exit' EXIT; false ); echo "trap exit -> $?"
( trap 'echo "trap2"; (exit 7); exit' EXIT; exit 3 ); echo "trap exit keeps -> $?"
( trap 'exit 9' EXIT; exit 3 ); echo "trap exit N -> $?"
( trap 'exit' USR1; kill -USR1 $BASHPID; echo notreached ); echo "usr1 exit -> $?"
( false; trap 'exit' USR1; kill -USR1 $BASHPID ); echo "usr1 exit2 -> $?"
logout 2>&1 | e; echo "logout st=${PIPESTATUS[0]}"
f() { return; }; false; f; echo "ret bare -> $?"
f() { return --; }; false; f; echo "ret -- -> $?"
f() { return -- 3; }; f; echo "ret -- 3 -> $?"
f() { return ' 4 '; }; f; echo "ret sp -> $?"
f() { return -1; }; f; echo "ret -1 -> $?"
f() { return 300; }; f; echo "ret 300 -> $?"
f() { return 1e1; echo "after bad"; }; f 2>&1 | e; f 2>/dev/null; echo "ret 1e1 -> $?"
f() { return 0x3; echo "after bad2"; }; f 2>/dev/null; echo "ret 0x3 -> $?"
f() { return 3 4; echo "after too many"; }; f 2>&1 | e; echo "piped"
g() { f; echo "g after f st=$?"; }; g 2>/dev/null; echo "g st=$?"
return 2>&1 | e; echo "top return st=${PIPESTATUS[0]}"
return 5 2>/dev/null; echo "top return 5 st=$?"
printf 'echo in-src; return 6; echo no\n' > s.sh; . ./s.sh; echo "source ret -> $?"
printf 'false; return\n' > s2.sh; . ./s2.sh; echo "source bare -> $?"
printf 'return -- 2\n' > s3.sh; . ./s3.sh; echo "source -- -> $?"
m() { (return 4); echo "subshell ret $?"; return 5; }; m; echo "m -> $?"
n() { x=$(return 6; echo no); echo "cs ret $? [$x]"; }; n
