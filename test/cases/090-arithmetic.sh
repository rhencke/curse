echo $((1 + 2 * 3))
echo $((10 % 3))
echo $((2 ** 8))
x=5
echo $((x * x))
echo $((x++ + 1))
echo "x is now $x"
n=3
(( n > 2 )) && echo "n big"
(( n > 5 )) || echo "n small"
echo $(( (1 + 2) * (3 + 4) ))
a=2 b=3
echo $((a < b ? a : b))
echo $((0x10 + 010))
