arr=(apple banana cherry)
echo "first: ${arr[0]}"
echo "all: ${arr[@]}"
echo "star: ${arr[*]}"
echo "count: ${#arr[@]}"
echo "indices: ${!arr[@]}"
echo "scalar: $arr"

arr[3]=date
echo "after add: ${arr[@]} (${#arr[@]})"
arr[1]=BANANA
echo "replaced: ${arr[1]}"

arr+=(elderberry fig)
echo "appended: ${arr[@]}"
echo "last: ${arr[-1]}"
echo "len of [0]: ${#arr[0]}"

for x in "${arr[@]}"; do echo "item: $x"; done

sparse=([2]=two [5]=five)
echo "sparse: ${#sparse[@]} indices ${!sparse[@]} five=${sparse[5]}"

words="a b c"
list=($words)
echo "from split: ${#list[@]} = ${list[@]}"

declare -a empty
echo "empty count: ${#empty[@]}"
empty+=(x)
echo "empty now: ${empty[@]}"

i=2
echo "arr[i]=${arr[i]} arr[i+1]=${arr[i+1]}"

s=foo
s+=bar
echo "concat: $s"
