# ERR trap fires when a command fails at the top level
trap 'echo "ERR status=$?"' ERR

false
echo "after false"

true
echo "after true"

# not in an if-condition
if false; then echo no; fi
echo "after if"

# not the non-final side of || / &&
false || echo "or-ran"
echo "after or"
true && false
echo "after and-final"

# fires again in a ; list, and $? reflects the failing command
false; echo "list continues"

# a failing subshell and a false (( )) / [[ ]] fire ERR too
(exit 7)
echo "after subshell"
(( 0 ))
echo "after arith"
[[ 1 == 2 ]]
echo "after dbracket"

# clearing ERR stops it
trap - ERR
false
echo "after clear"
