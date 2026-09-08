# readonly variables: assignment and unset are refused
readonly PI=3.14
echo "PI=$PI"
PI=3 2>/dev/null
echo "after assign: PI=$PI rc=$?"

# declare -r
declare -r RO=locked
RO=changed 2>/dev/null
echo "RO=$RO rc=$?"

# readonly on an existing var
x=hello
readonly x
x=bye 2>/dev/null
echo "x=$x rc=$?"

# unset a readonly variable fails, variable remains
unset PI 2>/dev/null
echo "unset rc=$? PI=$PI"

# declare -ri integer readonly: value set and coerced, then locked
declare -ri N=2+3
echo "N=$N"
N=99 2>/dev/null
echo "N still=$N rc=$?"

# a normal variable is still assignable / unsettable
y=1
y=2
echo "y=$y rc=$?"
unset y
echo "y unset: [${y-gone}] rc=$?"

# readonly with value form
readonly Z=zed
echo "Z=$Z"
