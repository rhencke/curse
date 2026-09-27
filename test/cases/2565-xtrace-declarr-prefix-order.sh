# Pinned bash behaviour: under set -x a declaration builtin's compound-assignment operand
# traces (`+ arr2=('y' 'z')`) as its words expand — before the command's prefix
# assignments expand and trace (`+ v=x`), then the declaration itself.
exec 2>&1
set -x
v=$(echo x) declare -a arr2=($(echo y) z)
f() { v=$(echo p) w=q local -a b=($(echo q)) c=(r); declare -p b c; }
f
set +x
g() { v=$1 local -a b=($1 "$2") >/dev/null; echo "${b[*]}"; }
for ((i = 0; i < 200; i++)); do (set -x; g "$((i % 2))" z) 2>&1; done | sort | uniq -c
