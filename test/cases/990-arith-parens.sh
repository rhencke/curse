# arithmetic with parenthesized subexpressions after comparison operators
# (the `<(` / `>(` must be operators here, not process substitutions)
echo "$(( 3 < (2) ))"
echo "$(( 1 < (2+3) ))"
echo "$(( 5 > (2*2) ))"
echo "$(( (1+2) * (3+4) ))"
echo "$(( 3 <= (3) ))"
echo "$(( (10) >> (1) ))"

# nested parens in a C-style for header condition
for (( n=0; n<(3-(1)); n++ )); do echo "n=$n"; done

# variables and command subs still expand inside arithmetic
x=5
echo "$(( $x + (2*3) ))"
echo "$(( $(echo 4) < (10) ))"

# (( )) command form with parenthesized comparison
(( 3 < (2+2) )) && echo "cmp-true"
(( 9 < (2+2) )) || echo "cmp-false"

# process substitution outside arithmetic is unaffected
cat <(echo "procsub works")
