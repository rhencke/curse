# ${v^} / ${v^^} / ${v,} / ${v,,} — case modification
s="hello World"
echo "up1: ${s^}"
echo "upall: ${s^^}"
lo="HELLO world"
echo "down1: ${lo,}"
echo "downall: ${lo,,}"

# with a match pattern: only matching characters are converted
word="banana"
echo "vowels up: ${word^^[aeiou]}"
echo "a up: ${word^^a}"

# first-char op only touches the first character
mixed="xyz"
echo "first: ${mixed^}"

# case mod over array elements
names=(alice bob CAROL)
echo "up: ${names[@]^^}"
echo "cap: ${names[@]^}"
for n in "${names[@],,}"; do echo "n=$n"; done

# positional params
set -- foo BAR
echo "pos: ${@^^}"

# empty stays empty
empty=""
echo "empty: [${empty^^}]"
