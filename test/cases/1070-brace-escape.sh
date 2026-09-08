# ${...} parsing: escaped/quoted/nested braces in operands
x="a}b}c"
echo "strip=${x%%\}*}"           # \} is a literal } in the pattern
echo "strip1=${x%\}*}"

# a backslash-} in a default value is a literal }
echo "def=${undef-x\}y}"
echo "def2=${undef:-{brace}}"     # literal braces in a default

# nested ${...} inside a default
y=inner
echo "nested=${undef:-[${y}]}"

# command substitution (with parens/quotes) inside a default
echo "cmdsub=${undef:-$(echo "p)q")}"

# ordinary operations unaffected
p=path/to/file.tar.gz
echo "base=${p##*/}"
echo "noext=${p%.*}"
echo "dir=${p%/*}"
echo "len=${#p}"
