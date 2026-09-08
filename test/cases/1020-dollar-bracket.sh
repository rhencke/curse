# $[expr] — deprecated synonym for $((expr))
echo $[1+2]
echo $[ 3 * 4 ]
echo "sum=$[10 + 20]"
x=5
echo $[$x + 1]
echo $[x * x]
echo $[$undef + 10]

# nested and combined with other expansions
echo $[ (1+2) * 3 ]
a=(10 20 30)
echo $[ a[1] + a[2] ]
echo "result: $[2**8]"

# a real glob with [ ] is still a glob, not arithmetic
d=$(mktemp -d); cd "$d"
touch afile bfile
echo a*
echo [ab]file
cd /; rm -rf "$d"
