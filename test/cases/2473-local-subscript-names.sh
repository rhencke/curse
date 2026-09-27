# local/declare with a subscripted NAME follow bash's declare_internal: `a[` (no closing
# bracket) and `y[]` with no value are not valid identifiers; `b[]=3` and `h[@]=1` report a
# bad subscript but have made the (local) array already; a local's scalar value is dropped
# when it becomes an array (make_local_array_variable), a global's is kept as [0].
exec 2>&1
f() {
	local 'a['; echo "st=$?"; declare -p 'a['
	local 'b[]'=3; echo "st=$?"; declare -p b
	local 'c[1]'=4; echo "st=$?"; declare -p c
	local 'd[x'=5; echo "st=$?"
	local 'g[1]'; echo "st=$?"; declare -p g
	local 'h[@]'=1; echo "st=$?"; declare -p h
	declare 'k['; echo "st=$?"
	declare 'm[]'=3; echo "st=$?"; declare -p m
	local x=1; local 'x[]'=2; declare -p x
	local y=1; local 'y[1]'=2; declare -p y
}
f
x=5; declare 'x[]'=3; declare -p x
declare 'y[]'; echo "st=$?"
z=7; declare 'z[@]'=1; declare -p z
s=gs
g() { local -I s; local 's[1]'=z; declare -p s; local u=(1 2); local 'u[5]'=5; declare -p u; }
g
h() { local 'p[]'=1; local q=1; local 'q[2]'=2; local 'r[' 2>/dev/null; echo "$? ${#p[@]} ${q[*]} ${!q[*]}"; }
for ((i = 0; i < 160; i++)); do h 2>/dev/null; done | uniq -c
