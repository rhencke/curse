# a ${x-default} default inside "..." uses double-quote backslash rules
undef=

# quoted context: backslash escapes only $ ` \ (and drops before them)
echo "a=${undef-\$}"
echo "b=${undef-\(}"
echo "c=${undef-\z}"
echo "d=${undef-\\}"
echo "e=${undef-\e}"
echo "f=${undef-\"}"
echo "g=${undef-\`}"

# expansions still work inside a quoted default
x=hi
echo "h=${undef-[$x]}"

# unquoted default keeps unquoted backslash rules (backslash removed)
echo j=${undef-\z}
echo k=${undef-\$}

# :- variant in a quoted context too
empty=''
echo "l=${empty:-\ttab}"
