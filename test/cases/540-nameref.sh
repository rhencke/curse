# declare -n nameref: reads follow, writes go through to the target
declare -n ref=target
target=hello
echo "via ref: $ref"
ref="world"
echo "target now: $target"

# nameref to an array
declare -a arr=(a b c)
declare -n aref=arr
echo "aref0: ${aref[0]} all: ${aref[*]} len: ${#aref[@]}"
aref[1]=BB
echo "arr now: ${arr[*]}"

# pass a variable to a function by reference
setval() {
  local -n out=$1
  out="set by func"
}
myvar=original
setval myvar
echo "myvar: $myvar"

# append to an array through a nameref
append() {
  local -n a=$1
  a+=(new)
}
declare -a list=(x y)
append list
echo "list: ${list[*]}"

# re-point a nameref
declare -n p=first
first=1; second=2
echo "p=$p"
declare -n p=second
echo "p=$p"

# unset through a nameref removes the target
val=here
declare -n r=val
unset r
echo "after unset: [${val-gone}]"
