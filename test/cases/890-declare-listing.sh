# declare / declare -p / readonly -p / export -p listings

alpha=1
beta="two words"
readonly RO=locked
export EX=exported
declare -n nref=alpha
arr=(a b "c d")
declare -A m; m[k]=v

# bare declare lists variables in set (name=value) form
declare | grep -E '^(alpha|beta|RO|EX|nref)='

echo "--p--"
# declare -p (no args) lists variables in declare form
declare -p | grep -E ' (alpha|arr|RO)='

echo "--ro--"
# readonly and readonly -p list readonly variables
readonly -p | grep 'RO='
readonly | grep 'RO='

echo "--ex--"
# export and export -p list exported variables
export -p | grep 'EX='
export | grep 'EX='

echo "--named--"
# declare -p with names still works, and exit status reflects existence
declare -p arr
declare -p RO
declare -p does_not_exist 2>/dev/null; echo "missing=$?"
