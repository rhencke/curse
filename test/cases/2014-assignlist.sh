# Assignment lists (a=1 b=$x … with no command) compiled binding by binding: order,
# $? = the last command substitution's, one DEBUG, errexit on the final status only.
a=1 b=$(echo 2) c=3
echo $a$b$c $?
x=$(exit 3) y=1; echo $?
x=$(exit 3) y=$(true); echo $?
p=1 q=$p r=$((q+1)); echo $p$q$r
arr=(); i=0 arr[i]=z arr[1]=$i; echo "${arr[@]}"
m=5 n=$(( m * 2 )); echo $n
declare -a z; z[-9]=1 w=2; echo "st=$? w=${w-unset}"
set -e
u=$(false) v=$(true); echo "survived $?"
readonly ro=1
f() { local l=1 k=$l; echo "$l$k"; }; f
set +e
trap "echo D" DEBUG
a=1 b=$(echo 2) c=3
trap - DEBUG
echo "$a$b$c"
