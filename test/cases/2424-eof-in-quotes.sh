# Input that ends inside a quote or expansion: bash names the innermost construct left
# open — also inside a $( … ) body, whose quotes the comsub reader tracks (parse_comsub) —
# and reports it at the line bash does. The quote and expansion scanners are shared.
S=${THIS_SH:-bash}
t=${TMPDIR:-/tmp}/c2424.$$; mkdir -p "$t"; cd "$t" || exit 1
e() { sed 's/^[^:]*: line \([0-9]*\): /L\1: /'; }
r() { printf '%b' "$1" > s.sh; $S s.sh 2>&1 | e; echo "st=${PIPESTATUS[0]}"; }
r 'echo a\necho `echo b'
r 'echo a\necho "b'
r "echo a\necho 'b"
r "echo a\necho \$'b"
r 'echo a\necho ${x'
r 'echo a\necho "${x'
r 'echo a\necho "$(echo x'
r 'echo a\necho $(echo "x'
r 'echo a\necho "`echo x"'
r 'echo a\necho ${x:-`echo}'
r 'echo a\necho ${x:-"}'
r 'echo a\necho $((1+2'
r 'echo a\necho "$((1+2"'
r 'echo a\na=([x'
r 'echo a\ncase x in "a'
r 'echo a\ncase x in @(a'
r 'echo x{a,"b\n}"'
r 'echo "$[1+2"'
r "echo a\necho \$(echo 'x"
r "echo a\necho \$(echo \$'x"
r 'echo a\necho $(echo `x'
r 'echo a\necho $(echo "x\nmore\nlines'
r 'echo a\nx=$(echo "x\nmore)\necho b'
r 'echo $(echo "a\n)" b)'
r 'echo $(case x in "a)") ;; esac; echo ok)'
