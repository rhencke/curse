# ${!ref} indirect expansion to scalars, array elements, and assoc keys
target=hello
ref=target
echo "scalar: ${!ref}"

# indirect to an array element
arr=(a b c d)
p='arr[2]'
echo "elem: ${!p}"
i=1
q="arr[$((i+1))]"
echo "computed elem: ${!q}"

# indirect to a whole array (all elements)
all='arr[@]'
echo "all: ${!all}"

# indirect to an associative key
declare -A m=([name]=Alice [role]=admin)
k='m[role]'
echo "assoc: ${!k}"

# indirect through a nameref (declare -n) reads the target
declare -n nr=target
echo "via nameref: $nr"

# chained: ref -> name -> value
a=b
b=c
c=final
r=a
echo "one hop: ${!r}"

# unset indirect target -> empty
unset target
u=target
echo "unset: [${!u}]"
