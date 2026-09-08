# declare -p reconstructs a variable's definition
x=hello
declare -p x
y="a b\"c'd"
declare -p y
declare -i n=42
declare -p n
declare -rx RO=locked
declare -p RO
declare -a arr=(one "two three" four)
arr[9]=sparse
declare -p arr
declare -u U=hi
declare -p U
e=
declare -p e
declare -ai both=(1 2)
declare -p both

# single-key assoc (deterministic order)
declare -A m=([only]="v 2")
declare -p m

# nameref
declare -n ref=x
declare -p ref

# multiple names at once, and a missing one
a1=1; a2=2
declare -p a1 a2
declare -p nosuchvar || echo "rc=$?"
