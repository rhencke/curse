# field splitting honors a custom IFS (whitespace vs non-whitespace rules)

# non-whitespace IFS: each delimiter separates; empties between adjacent ones
IFS=,
set -- $(echo "a,b,c")
echo "n1=$#:[$1][$2][$3]"
x="a,,b"; set -- $x
echo "n2=$#:[$1][$2][$3]"
x="a,"; set -- $x
echo "n3=$#:[$1]"
x=",a"; set -- $x
echo "n4=$#:[$1][$2]"

# a lone non-ws delimiter yields one empty field
IFS=:
x=":"; set -- $x
echo "n5=$#:[$1]"

# mixed IFS: whitespace around a non-ws delimiter is absorbed
IFS=" ,"
x="a, b ,c"; set -- $x
echo "m1=$#:[$1][$2][$3]"
x="a,,b"; set -- $x
echo "m2=$#:[$1][$2][$3]"

# default IFS collapses whitespace runs and trims ends
unset IFS
x="  a   b  c  "; set -- $x
echo "w1=$#:[$1][$2][$3]"

# for-loop and read both use the current IFS
IFS=:
for w in one:two:three; do printf '<%s>' "$w"; done; echo
echo "k1:k2:k3" | { IFS=: read a b c; echo "read=[$a][$b][$c]"; }

# quoted delimiters are literal, not split
IFS=,
x="a,b"; set -- "$x"
echo "q1=$#:[$1]"
