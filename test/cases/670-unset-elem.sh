# unset an array element / assoc key; test -v with subscripts
a=(a b c d e)
unset 'a[1]'
echo "after unset a1: ${a[*]}  len=${#a[@]}  idx=${!a[*]}"
unset 'a[-1]'
echo "after unset last: ${a[*]}  len=${#a[@]}"

# unsetting one element leaves others (sparse)
b=(0 1 2 3)
unset 'b[0]' 'b[2]'
echo "b: ${b[*]}  idx: ${!b[*]}"

# associative key
declare -A m=([x]=1 [y]=2 [z]=3)
unset 'm[y]'
echo "m count: ${#m[@]}"
echo "m.x=${m[x]} m.y=[${m[y]}] m.z=${m[z]}"

# test -v with array element (the test builtin, not [[ ]])
arr=(10 20 30)
[ -v 'arr[0]' ] && echo "arr0 set"
[ -v 'arr[9]' ] || echo "arr9 unset"
i=2
[ -v "arr[i]" ] && echo "arr-i set"
unset 'arr[2]'
[ -v 'arr[2]' ] || echo "arr2 now unset"

# scalar unset via [0]
s=hello
unset 's[0]'
[ -v s ] || echo "scalar gone"
