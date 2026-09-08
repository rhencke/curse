# subshells inherit shopt and variable attributes, but changes don't leak out

# nullglob set in the parent applies inside a command substitution
shopt -s nullglob
out=$(echo *.nomatchxyz)
echo "sub nullglob len: ${#out}"

# extglob visible in a subshell; unsetting there doesn't affect the parent
shopt -s extglob
( shopt -u extglob; shopt -q extglob && echo "inner: on" || echo "inner: off" )
shopt -q extglob && echo "outer: on" || echo "outer: off"

# nocasematch inherited into a command sub
shopt -s nocasematch
r=$( [[ HELLO == hello ]] && echo yes || echo no )
echo "sub nocasematch: $r"

# integer attribute survives into a subshell
declare -i n=5
echo "sub int: $(n=2+3; echo $n)"

# a subshell's variable changes don't escape
x=parent
( x=child; echo "inner x: $x" )
echo "outer x: $x"

# uppercase attribute inherited
declare -u U=start
echo "sub upper: $(U=more; echo $U)"
