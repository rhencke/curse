# `+X` option words: declare/typeset/local take them (internal_getopt with a leading `+`)
# and reject an unknown letter as `+Z: invalid option` with the usage, status 2; export
# and readonly have no `+` form (internal_getopt (list, "aAfnp")), so a +word is their
# first operand: `+Z': not a valid identifier, status 1 — and the names after it still bind.
exec 2>&1
declare +Z x; echo "declare $?"
typeset +Z; echo "typeset $?"
declare +iZ y; echo "declare2 $?"
export +Z; echo "export $?"
readonly +Z; echo "readonly $?"
readonly +x ro1; echo "readonly2 $? $(declare -p ro1 2>&1)"
export +n ex1=5; echo "export2 $? $(declare -p ex1 2>&1)"
declare -Z; echo "declare3 $?"
f() { local +Z v; echo "local $?"; }
f
declare -i n=5; declare +i n; n=1+1; echo "n=$n"
g() { declare +Q q 2>/dev/null; a=$?; export +Q 2>/dev/null; echo "$a $?"; }
for ((i = 0; i < 160; i++)); do g; done | uniq -c
