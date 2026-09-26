# Input that ends inside a quote or expansion: bash names the innermost construct left
# open — also inside a $( … ) body, whose quotes the comsub reader tracks (parse_comsub) —
# and reports it at the line bash does: where the construct left open BEGAN (parse.y
# parse_matched_pair's start_lineno), not where its command did — in a $( … ) body, a
# function, an eval'd text, a continued line. The quote and expansion scanners are shared.
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
# multi-line commands: the line the open quote / expansion began on
r 'echo start\nx=$(echo a\necho b\necho "c\nd'
r 'echo start\nx=$(\n\n\necho `c'
r 'f() {\n  x=$(echo a\n  echo "c'
r 'echo start\neval "x=\\$(echo a\necho \\"c"'
r 'echo a \\\n  b "c'
r 'if true; then\n  echo "c'
r 'echo ${x:-\n"abc'
r "echo a \\\\\n  'x\n"
r "echo a \\\\\n  \$'x\n"
r 'echo a \\\n ${x\n\n'
r 'echo a \\\n $((1+2\n\n'
r 'echo "a\n$(echo "b\nc'
r 'echo `a\n"b\nc'
r 'case x in\n"a\n'
r 'for ((i=0;\n\ni<3'
r '((1+\n2'
# …also in a sourced file and a hot function's eval'd text
printf 'echo a\nx=$(echo b\necho "c\n' > t.sh
$S -c '. ./t.sh; echo st=$?' 2>&1 | e
$S -c 'f() { eval "$(cat t.sh)"; }; for i in $(seq 160); do f >/dev/null 2>&1; done; f; echo st=$?' 2>&1 | e
