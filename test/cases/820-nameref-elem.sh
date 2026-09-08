# namerefs to array elements and typeset +n removal

# plain nameref: read and write through
x=foo
declare -n r=x
echo "r=$r"
r=bar
echo "x=$x r=$r"

# typeset +n drops the nameref; value becomes the referenced name
typeset +n r
echo "after +n: r=$r"

# nameref to an indexed-array element
a=(zero one two three)
declare -n e='a[2]'
echo "e=$e"
e=CHANGED
echo "a2=${a[2]}"

# nameref to all elements
declare -n all='a[@]'
echo "all=$all"

# nameref to an associative element
declare -A m
m[key]=value
declare -n am='m[key]'
echo "am=$am"
am=updated
echo "m=${m[key]}"

# nameref that points at a plain var which is later reassigned
count=1
declare -n cref=count
count=42
echo "cref=$cref"
(( cref++ ))
echo "count=$count"

# nameref used as a function out-param (common bash idiom)
setval() {
  declare -n out=$1
  out="result:$2"
}
setval dest hello
echo "dest=$dest"
