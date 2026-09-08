# read: backslash handling and line continuation
# a trailing backslash continues onto the next physical line
read x <<'IN'
one \
two
IN
echo "cont: [$x]"

# -r keeps the backslash-newline literally (well, backslash then next line)
read -r y <<'IN'
raw\
line
IN
echo "raw: [$y]"

# backslash before a normal char is removed (no C escapes)
read z <<'IN'
a\tb\nc
IN
echo "esc: [$z]"

# -r keeps backslashes verbatim
read -r w <<'IN'
a\tb\nc
IN
echo "rawesc: [$w]"

# read from empty input fails
read v < /dev/null
echo "empty rc: $?  v=[$v]"

# multiple vars split on IFS; extra vars empty
read a b c <<< "p q"
echo "a=$a b=$b c=[$c]"

# custom delimiter with backslash escape
read -d ';' item <<< 'foo\;bar;rest'
echo "item: [$item]"
