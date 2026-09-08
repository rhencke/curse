# test / [ : unary operators, 3-arg -a/-o, argc rules
d=$(mktemp -d)
cd "$d"
touch file
mkdir sub
ln -s file link 2>/dev/null

# -a is an alias for -e
[ -a file ] && echo "a-file"
[ -a nope ] || echo "a-nope"

# file-type unary ops
[ -f file ] && echo "is-file"
[ -d sub ] && echo "is-dir"
[ -L link ] && echo "is-link"
[ -e file ] && echo "exists"

# -s (nonempty file)
[ -s file ] || echo "empty"
printf 'data\n' > big
[ -s big ] && echo "nonempty"

# -v variable is set
v=1
[ -v v ] && echo "v-set"
[ -v missing ] || echo "v-unset"

# 3-arg logical -a / -o
[ foo -a bar ] && echo "and-true"
[ foo -a '' ] || echo "and-false"
[ '' -o bar ] && echo "or-true"
[ '' -o '' ] || echo "or-false"

# ! and ( )
[ ! foo = foo ] || echo "not-eq-foo"
[ ! foo = bar ] && echo "not-eq-bar"
[ '(' -n foo ')' ] && echo "paren"

# comparisons still work
[ 5 -gt 3 ] && echo "gt"
[ a '<' b ] && echo "lt-str"

# missing ] and too many args are status 2
[ -n x 2>/dev/null
echo "missing-bracket: $?"
[ a b c d e ] 2>/dev/null
echo "too-many: $?"

cd /
rm -rf "$d"
