# In a compound assignment a word that starts with `[` is read through its matching `]`
# (bash's parse_matched_pair): blanks, newlines and `)` included, quotes and $(…) respected.
# No `]` before EOF is a syntax error, status 1 (eval returns 1 and the script goes on).
exec 2>&1
b=(1 [2 3] 4); declare -p b
c=([a b]x y); declare -p c
d=([a[1]]=q); declare -p d
e=([2 3]x"y z" 4); declare -p e
declare -A h=([a b]=1 [c]=2); declare -p h
a=(1 [x 3
]) ; declare -p a
a=(1 [x 3)
]); echo ${#a[@]} "${a[1]}"
for s in 'a=(1 [x 3)' 'a=([x]=1 [y)' 'a=([)' 'a=(1 [x"]"y 3)' 'declare a=(1 [x 3)' 'f() { a=(1 [x; }'; do
	eval "$s" 2>&1 | sed 's/^.*line [0-9]*: //'; eval "$s" 2>/dev/null; echo "st=$?"
done
