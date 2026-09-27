# An assignment inside $(( )) whose value holds a `${#name}` (`$((P=${#x}))`): the compiled
# tier took the `${#x}`-bearing text for a plain value and failed to compile — `emit: value
# position not supported for node asgn` (fuzz F28).
f=$((P=${#x})); echo "$f $P"
x=abc; f=$((P=${#x}+1)); echo "$f $P"
echo $((Q=${#x})) $Q
: $((R=${#x}*2)); echo $R
(( S=${#x} )); echo $S
y=$((z=${#x}, z+1)); echo $y $z
g() { w=$((T=${#x})); echo "function $w $T"; }; g
eval 'e=$((U=${#x})); echo "eval $e $U"'
printf 'e=$((V=${#x}+${#x})); echo "source $e $V"\n' > s2724.sh; . ./s2724.sh; rm -f s2724.sh
trap 'e=$((W=${#x}*3)); echo "trap $e $W"' USR1; kill -USR1 $$; trap - USR1
n=0; for ((i = 0; i < 150; i++)); do n=$((P=${#x}+n)); done; echo "hot $n $P"
