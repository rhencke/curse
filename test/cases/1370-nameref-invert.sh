# ${!ref} "inverts" on a nameref (yields the name it points to), while on a
# plain variable it is classic indirection; a nameref target must be a valid name.

x=foo
ref=x
# Plain variable: $ref is its value, ${!ref} indirects through it.
echo "plain: $ref ${!ref}"

typeset -n ref          # now ref is a nameref to x
# Nameref: $ref derefs to x's value; ${!ref} gives the target name.
echo "nameref: $ref ${!ref}"

# A nameref can target an array element.
a=(one two three)
declare -n e="a[2]"
echo "elem: $e ${!e}"

# An invalid target name is rejected with status 1.
declare -n bad="not a name" 2>/dev/null
echo "invalid=$?"

# The nameref length of ${!ref} is the target name's length.
echo "len=${#ref} !len=${#ref}"
echo done
