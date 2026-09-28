# ${#NAME[SUB]}: bash's array_length_reference looks at the variable before its subscript —
# one that doesn't exist or is invisible (`declare -a e`) is 0 and SUB is never evaluated;
# under set -u such a NAME, or one that is no array, is unbound. curse evaluated SUB first
# (`x y: syntax error in expression`, fuzz F66).
echo ${#v[x y]}
v=(1); echo ${#v[x y]}
echo next
unset v; echo ${#v[1/0]} ${#v[@]} ${#v[$(echo hi >&2)]}
declare -A A; echo ${#A[x y]} ${#A[$(echo k >&2)]}
s=abc; echo ${#s[x y]}
declare -a e; echo ${#e[x y]}
f() { local l; echo "f ${#l[q r]} ${#nope[1/0]}"; }; f
( set -u; s=abc; echo ${#s[x y]}; echo no ); echo "u1 $?"
( set -u; echo ${#w[x y]}; echo no ); echo "u2 $?"
( set -u; e=(1); echo "u3 ${#e[5]}" )
i=0; while [ $i -lt 150 ]; do echo "${#q[a b c]}${#q[$((i/0))]}"; i=$((i + 1)); done | sort | uniq -c
