# `declare x` on a fresh name declares it but leaves it unset: ${x+set} is empty
# and `declare -p x` prints no =value. Declaring an existing var keeps its value.
declare u
echo "plus=[${u+SET}]"
declare -p u

declare -i n
declare -p n

x=5
declare x                # keeps the existing value
declare -p x
echo "xplus=[${x+SET}]"

# Assigning after a bare declare gives it a value.
declare y
y=hi
echo "y=[${y+SET}] $y"
declare -p y
