# bash 5.2.21 expands an ASSOCIATIVE array's subscripts and its compound-assignment values
# with expand_subscript_string, whose W_NOTILDE means no tilde expansion at all: `a[~]=v`
# keys "~", `${a[~]}` looks "~" up, `([k]=~)` / `(k ~)` store "~" (and `:~` too). An
# ordinary element assignment `a[k]=~` is a scalar assignment and does expand; indexed
# arrays are unaffected. (Patch 5.2-024 turned tildes back on; curse is 5.2.21.)
HOME=/hh; x=q
declare -A a; a[~]=1; a[~/k]=2; a[k]=~; a[j]=~/x:~; echo "keys: ${!a[@]} | ${a[k]} ${a[j]}"
echo "get: ${a[~]} ${a[~/k]} ${a["~"]}"
unset 'a[~]'; echo "after unset: ${!a[@]}"
declare -A b=([~]=v [k]=~ [j]=~/x:~ [m]="$x":~); echo "b: ${!b[@]} | ${b[k]} ${b[j]} ${b[~]} ${b[m]}"
declare -A c=(k1 ~ ~ v2 k3 "$x":~); echo "c: ${!c[@]} | ${c[k1]} ${c[~]} ${c[k3]}"
declare -A d; d=([k]=~ [~]=w); echo "d: ${d[k]} ${d[~]}"
d+=([m]=~); echo "d+: ${d[m]}"
# a declaration builtin WITHOUT -A expands its compound argument as an ordinary assignment
# word first (tildes after = and word-initial), even into an existing associative array
declare d=([n]=~/n); echo "redeclared: ${d[n]}"
declare d=(k ~); echo "redeclared kv: ${d[k]}"
declare -A d=([n]=~/n); echo "declare -A: ${d[n]}"
h() { local -A e; local e=([n]=~); echo "local, no -A: ${e[n]}"; }; h
declare -A w; declare -g w=([~]=~); echo "declare -g: ${!w[@]} ${w[~]}"
declare -gA z=([n]=~); echo "declare -gA: ${z[n]}"
declare -Ar y=([n]=~); echo "declare -Ar: ${y[n]}"
f() { local -A e=([k]=~ [m]="$x":~); echo "e: ${e[k]} ${e[m]}"; local -A g; g=([k]=~); echo "g: ${g[k]}"; }; f
typeset -A t=([k]=~); echo "t: ${t[k]}"
readonly -A r=([k]=~); echo "r: ${r[k]}"
declare -A u="([k]=~)"; echo "u: ${u[k]}"
for i in 1 2; do declare -A L; L=([k$i]=~ [~$i]=$i); L[~]=$i; echo "loop: ${L[k$i]} ${L[~$i]} ${L[~]}"; done
# indexed arrays: values tilde-expand as assignments; subscripts are arithmetic
i=([0]=~ [1]=$x:~ ~/z); echo "i: ${i[*]}"
i[3]=~; echo "i3: ${i[3]}"
