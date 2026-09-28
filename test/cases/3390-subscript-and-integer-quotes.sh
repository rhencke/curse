# Pinned bash behaviour: an indexed subscript's backslashes quote as in double quotes before
# it is evaluated (`${a[\"1\"]}` evaluates `"1"`), and a value assigned to an integer
# variable is expansion output: a `"` in it is just a character — `y='"2"'` is an
# operand-expected error that abandons the line, not the number 2.
exec 2>&1
a=(1 2)
echo "${a["1"]}"; echo "st=$?"
echo "${a["1+"]}"; echo "st=$?"
echo "${a[\"1\"]}"; echo "st=$?"
echo "${a['"1"']}"; echo "st=$?"
echo "${a["1"x]}"; echo "st=$?"
declare -i y; y='"2"'; echo "st=$? y=$y"
echo "y=$y"
declare -i z; z="'3'"; echo "st=$? z=$z"
declare -i w; w='1+"2"'; echo "st=$? w=$w"
declare -i v='"2"'; echo "st=$? v=$v"
f() { local -i l='"4"'; echo "st=$? l=$l"; }; f
declare -i p=1; p+='"1"'; echo "st=$? p=$p"
declare -ai b; b[0]='"3"'; echo "st=$? ${b[0]}"
for ((i = 0; i < 150; i++)); do
	( declare -i r; r='"7"' )
	( echo "${a[\"0\"]}" )
done 2>&1 | sort | uniq -c
