# read: combined and smooshed short flags

# -rd '' reads until NUL (the whole here-doc), -r keeps backslashes
read -rd '' var <<'EOF'
foo
bar
EOF
echo "1:[$var]"

# -n3 smooshed, and -rn3
read -n3 a <<< abcdef; echo "2:[$a]"
read -rn3 b <<< 'x\yz'; echo "3:[$b]"

# -d with a smooshed delimiter
read -d: p q <<< 'one:two:three'; echo "4:[$p][$q]"

# -N reads exactly N chars including delimiters
read -N5 c <<< 'ab cd ef'; echo "5:[$c]"

# separate-word forms still work
read -n 2 d <<< hello; echo "6:[$d]"

# no name → REPLY, whole line, no field splitting
read <<< '  spaced  out  '; echo "7:[$REPLY]"

# -r keeps a backslash literally; plain read consumes it
read -r e <<< 'a\tb'; echo "8:[$e]"
read f <<< 'a\tb'; echo "9:[$f]"
