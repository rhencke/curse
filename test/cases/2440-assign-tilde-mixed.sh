# Tilde expansion in an assignment value that mixes literals with expansions: every
# unquoted `:~` (and a leading `~`) expands, in every assignment context — a prefix
# binding, `local`/`declare` operands, keyed array elements (bash: W_ASSIGNRHS)
HOME=/hh; x=q
a="$x":~ printenv a
a="$x":~/d:~ printenv a
a=~:"$x" printenv a
a="$x":~"$x" printenv a
f() {
	local l="$x":~; echo "local $l"
	local m=a:~:"$x"~; echo "local $m"
	local n="$x":~/z:~ o=~:"$x"; echo "local $n $o"
	declare -A e=([k]="$x":~); echo "decl ${e[k]}"
	declare p="$x":~; echo "declare $p"
}
f
declare -A d=([k]="$x":~)
echo "assoc ${d[k]}"
d=([k]="$x":~ [j]=~:"$x")
echo "assoc2 ${d[k]} ${d[j]}"
b=([0]="$x":~ [1]="$x":~/s)
echo "idx ${b[0]} ${b[1]}"
y="$x":~
echo "scalar $y"
export z="$x":~; echo "export $z"
for i in 1 2; do w="$i":~; v=([i]="$i":~); echo "loop $w ${v[i]}"; done
