# a command-prefix assignment applies to the command's environment only,
# and does NOT affect expansion of the command's own arguments (bash order)
x=global
x=local echo "arg sees: $x"        # $x expands before x=local is applied -> global
echo "still: $x"                   # unchanged in the shell

# the prefix assignment IS visible to the command's environment
A=1 B=2 env | grep -E '^[AB]=' | sort

# multiple prefixes and a builtin
FOO=bar printf '%s\n' "prefix-ok"

# prefix with a command substitution RHS, arg unaffected
v=$(echo fromsub) printf '[%s]\n' "$v"

# the prefix does not leak out
echo "leak: ${FOO-unset}/${A-unset}"

# prefix on an external command reaches its environment
MSG=hello sh -c 'echo "$MSG"'
