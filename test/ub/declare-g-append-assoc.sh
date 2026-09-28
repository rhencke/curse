# docs/bash-ub.md: `declare -g NAME+=(…)` in a function over a global associative NAME: bash
# converts the associative array to an indexed one with convert_var_to_array, which reads
# the variable's value cell — the hash table pointer — as a C string for element 0 (bytes
# of the heap, varying by run), then appends the quoted words. curse's pinned choice: the
# converted array starts empty, the words (quoted, as bash stores them) are appended.
declare -A x=([k]=v)
f() { declare -g x+=(a b); }; f; declare -p x
declare -A y=([k]=v)
i=0; g() { declare -g y+=("$i"); }; while [ $i -lt 150 ]; do g; i=$((i + 1)); done; echo "${#y[@]} ${y[0]} ${y[149]}"
eval 'declare -A z=([k]=v); h() { declare -g z+=(c); }; h; declare -p z'
