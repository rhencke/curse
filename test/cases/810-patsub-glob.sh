# Quote/escape-aware patterns in ${v/pat/repl}, ${v#pat}, ${v%pat}

# backslash-escaped metacharacters are literal
s='a*b*c'
echo "${s//\*/X}"
s='a?b?c'
echo "${s//\?/Q}"

# quoted metacharacter in the pattern is literal
v='a*b'
g='*'
echo "${v//"$g"/-}"
echo "${v//$g/-}"

# a hard glob mixing literal and active metacharacters
s='aa*bb+cc'
echo "${s//\**+/__}"

# empty pattern is a no-op (unset vars -> empty)
x=-foo-
echo "${x//$foo$bar/bar}"
echo "${x//X/Z}"

# anchored empty pattern inserts at the ends
x=abc
echo "${x/#/[}"
echo "${x/%/]}"

# trim with escaped/quoted metacharacters
f='file.*.txt'
echo "${f%.txt}"
echo "${f%'.*.txt'}"
p='*.log'
echo "${p#\*}"

# per-element on arrays keeps quoting
a=('x.txt' 'y*.txt' 'z.txt')
echo "${a[@]/'*'/STAR}"
echo "${a[@]%.txt}"

# character classes still work after the change
w='Hello World 123'
echo "${w//[[:space:]]/_}"
echo "${w//[[:digit:]]/#}"

# global replace with a pattern that can match empty: no trailing empty match
x=abc
echo "${x//*/-}"
echo "${x//?/.}"
g='*'
v='a*b'
echo "${v//$g/-}"
