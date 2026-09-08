# set -u errors for value-using parameter operators on an unset variable,
# but the alternation operators (-, :-, +, :+, =, :=, ?, :?) are exempt.
set -u

# these do NOT error
echo "d1=${undef-default}"
echo "d2=${undef:-default}"
echo "d3=[${undef+set}]"
echo "d4=[${undef:+set}]"

# a set (even empty) variable is fine with value operators
x=hello
echo "slice=${x:1:3}"
echo "len=${#x}"
echo "trim=${x#he}"
echo "case=${x^^}"
empty=
echo "empty-slice=[${empty:0:2}] len=${#empty}"

# and finally, a value operator on an unset var aborts with status 1
echo "before-error"
echo "boom=${missing:1:2}"
echo "unreachable"
