# variables.c tempenv: `arr=z cmd` binds a temporary SCALAR that shadows the array for the
# command (a function sees "z", one element); the array is untouched afterwards (curse wrote
# element 0). Same for an associative array and for builtins.
arr=(a b c)
f() { echo "in: ${arr[@]} ${#arr[@]}"; }
arr=z f
echo "out: ${arr[@]} ${#arr[@]}"
declare -A h=([k]=v)
h=z f
declare -p h
arr=(a b); arr=z true; declare -p arr
arr=z :; declare -p arr
