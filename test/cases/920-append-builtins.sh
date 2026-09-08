# += (append) in the assignment builtins

typeset s=abc
typeset s+=def
echo "s=$s"
declare t=1
declare t+=2
echo "t=$t"

# integer attribute makes += arithmetic
declare -i n=5
n+=3
echo "n=$n"

# array append via declare/typeset
declare d=(a b)
declare d+=(c d)
echo "d=${d[@]}"
typeset arr=(x)
typeset arr+=(y z)
echo "arr=${arr[@]}"

# a flagless array declare must not list all variables
declare only=(one two)
echo "only=${only[@]}"

# export append keeps the export
export e=x
export e+=y
echo "e=$e"
env | grep '^e=y' >/dev/null && echo "e-exported"

# readonly with += sets and locks a fresh variable
readonly r+=locked
echo "r=$r"

# local += appends to an existing local but a first local starts empty
# (it does not inherit the global s set above)
g() {
  local s+=infunc
  echo "local1=$s"
  local s+=more
  echo "local2=$s"
}
g
