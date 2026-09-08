echo "sub: $(echo inner)"
x=$(echo abc)
echo "x=$x"
echo result=$(printf '%s-%s' a b)
echo "nested: $(echo "level $(echo two)")"
