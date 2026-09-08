# [[ =~ ]] regex matching and BASH_REMATCH

s="hello123world"
if [[ $s =~ [0-9]+ ]]; then echo "has digits"; fi
if [[ $s =~ ^[0-9]+$ ]]; then echo "all digits"; else echo "not all digits"; fi

# capture groups populate BASH_REMATCH
if [[ $s =~ ([a-z]+)([0-9]+) ]]; then
  echo "whole: ${BASH_REMATCH[0]}"
  echo "g1: ${BASH_REMATCH[1]}"
  echo "g2: ${BASH_REMATCH[2]}"
  echo "count: ${#BASH_REMATCH[@]}"
fi

# quoted RHS is a literal: . matches only a literal dot
dotted="a.b"
if [[ $dotted =~ "a.b" ]]; then echo "literal dot match"; fi
plain="axb"
if [[ $plain =~ "a.b" ]]; then echo "unexpected"; else echo "literal no match"; fi
# unquoted . is a regex metachar
if [[ $plain =~ a.b ]]; then echo "regex dot match"; fi

# regex sourced from a variable
re="^h.*d$"
if [[ $s =~ $re ]]; then echo "var regex match"; fi

# anchoring + alternation in a loop
for w in cat dog bird; do
  if [[ $w =~ ^(cat|dog)$ ]]; then echo "$w: pet"; else echo "$w: other"; fi
done

# a failed match resets BASH_REMATCH
[[ zzz =~ ([0-9]+) ]]
echo "after nomatch: [${BASH_REMATCH[0]}] len=${#BASH_REMATCH[@]}"
