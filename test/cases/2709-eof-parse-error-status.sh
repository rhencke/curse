# An input that ends inside a quote or other construct (parse_matched_pair's EOF error:
# parser_error, then the grammar's `error yacc_EOF`) exits with the last command's status
# when that failed, else 2; an open `$(` is reported as a syntax error, which always sets
# 2; a sourced or eval'd text's returns 2. curse always exited 2 (fuzz F11).
S=${THIS_SH:-bash}
t() { printf "$1" > t2709.sh; "$S" t2709.sh 2>&1 | sed 's/^[^:]*: //'; echo "rc=${PIPESTATUS[0]}"; }
t "nosuch\necho 'x"
t "false\necho 'x"
t "true\necho 'x"
t '(exit 5)\necho "x'
t '(exit 5)\necho $('
t '(exit 5)\necho $(('
t '(exit 5)\necho ${'
t '(exit 5)\necho `'
t '(exit 5)\nif true'
t '(exit 5)\necho $['
t '(exit 5)\na['
t "(exit 5); echo 'x"
t "f() { return 7; }; f\necho 'x"
t '(exit 5)\necho $(echo "x'
t '(exit 5)\necho "$(echo x'
t "(exit 5)\necho \$'x"
t '(exit 5)\ncase x in "x'
t '(exit 5)\nx=(a "b'
t '(exit 5)\n((a"'
t 'for ((i = 0; i < 150; i++)); do false; done\necho "x'
"$S" -c "(exit 6)
echo 'x" 2>&1 | sed 's/^[^:]*: //'; echo "-c rc=${PIPESTATUS[0]}"
printf "(exit 4)\necho 'x" | "$S" 2>&1 | sed 's/^[^:]*: //'; echo "stdin rc=${PIPESTATUS[1]}"
printf "false\necho 'x" > t2709.sh; false; . ./t2709.sh; echo "source st=$?"
false; eval "echo 'x"; echo "eval st=$?"
rm -f t2709.sh
