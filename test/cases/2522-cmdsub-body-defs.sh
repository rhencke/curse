# What a $(…) body declares for itself holds inside it: a function named like a builtin
# (`echo() {…}`) is called in place of the builtin by the commands after it, a nameref
# (`declare -n ref='A["K"]'`) reads and writes through, an integer attribute evaluates.
# The body's text is read only when it is compiled, so the program's own checks never
# saw these declarations.
x=$(
echo() { command echo "shadowed:" "$@"; }
echo hello
command -v nosuch_xyz || echo "cv fail: $?"
)
echo "[$x]"
echo plain
y=$(
show() { echo values: ${A[@]}; }
declare -A A=(['K']=val)
declare -n ref='A["K"]'
echo before $ref
ref=val2
echo after $ref
show
declare -i n
n='2 + 3'
echo "n=$n"
)
echo "$y"
f() {
  local r
  r=$(
    echo() { command echo "in:$*"; }
    declare -A B=([k]=0)
    declare -n p='B[k]'
    declare -i m
    for ((i = 0; i < 3; i++)); do m+=i; p=$m; done
    echo "$p"; echo tail
  )
  echo "$r"
}
for ((k = 0; k < 150; k++)); do f; done | sort | uniq -c
echo last
