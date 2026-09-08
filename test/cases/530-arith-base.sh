# arithmetic bases: base#digits, hex, octal
echo $((16#ff))
echo $((16#FF))
echo $((2#1010))
echo $((8#17))
echo $((0xff))
echo $((0XA0))
echo $((010))
echo $((36#z))
echo $((36#Z))

# bases above 36 distinguish case, and use @ (62) and _ (63)
echo $((62#Z))
echo $((64#@))
echo $((64#_))
echo $((64#Az))

# used in expressions and assignments
x=$((16#10 + 2#11))
echo "x=$x"
echo $(( 0x10 * 8#10 ))

# C-style for over a hex bound
sum=0
for ((i = 0; i < 0x5; i++)); do sum=$((sum + i)); done
echo "sum=$sum"
