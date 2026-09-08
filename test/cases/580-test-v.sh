# [[ -v ]] with array elements, assoc keys, and @/*
declare -a arr=(a b c)
arr[7]=sparse
[[ -v arr[0] ]] && echo "arr0 set"
[[ -v arr[2] ]] && echo "arr2 set"
[[ -v arr[5] ]] || echo "arr5 unset"
[[ -v arr[7] ]] && echo "arr7 set"
[[ -v arr[@] ]] && echo "arr has elements"

# negative index
[[ -v arr[-1] ]] && echo "arr[-1] set"

# associative
declare -A m=([alice]=1 [bob]=2)
[[ -v m[alice] ]] && echo "m.alice set"
[[ -v m[carol] ]] || echo "m.carol unset"
[[ -v m[@] ]] && echo "m has keys"

# plain scalar (element 0), including empty
s=hello
[[ -v s ]] && echo "s set"
[[ -v s[0] ]] && echo "s0 set"
[[ -v s[1] ]] || echo "s1 unset"
empty=
[[ -v empty ]] && echo "empty is set"
[[ -v nope ]] || echo "nope unset"

# computed subscript
i=2
[[ -v arr[$i] ]] && echo "arr[i] set"
[[ -v arr[i+5] ]] && echo "arr[i+5] set"
