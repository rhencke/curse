# A function definition's status is 0: `false; g () { :; }; echo $?` prints 0. The compiled
# tier's definition (a hoisted function) left $? as it was (fuzz F67).
false; g () { :; }; echo "def $?"
false; function h { :; }; echo "kw $?"
f() { false; k() { :; }; echo "nested $?"; }; f
eval 'false; e() { :; }; echo "eval $?"'
false; g () { :; } && echo "and $?"
i=0; while [ $i -lt 150 ]; do false; m() { :; }; s=$s$?; i=$((i + 1)); done; echo "loop ${#s} ${s%%1*}"
