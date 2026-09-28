# A redirection with no word names the token bash's lexer read in its place: the whole
# operator (`<<<`, `>>`, `;;`, `|&` …), `newline` at the end — and at a `#`, which starts a
# comment there. curse accepted a bare `<<<` (fuzz F116), named `newline` for `ech<<<<<<<<`
# (F117), read `# x` as a target, and rejected `&>f` at the start of a command.
e() { eval "$1"; echo "st $?"; }
e '<<<'
e 'cat <<<'
e 'echo <<< ;'
e ': <<<<<<'
e 'ech<<<<<<<<'
e ': <<<&'
e ': <<< |'
e ': > >>'
e ': <<<<'
e ': << <<<'
e ': > &>x'
e ': >;;'
e ': << ;&'
e ': > |&'
e ': <#x'
e ': > #x'
e 'echo <<<#x'
e ': << #x'
e 'echo a >&#x'
cd "${TMPDIR:-/tmp}" || exit 1
e '&>c3081.$$ echo hi; cat c3081.$$'
e '&>>c3081.$$ echo more; cat c3081.$$; rm -f c3081.$$'
e 'echo a>b3081#c; cat b3081#c; rm -f b3081#c'
e 'cat <<< x'
f() { eval ': <<<'; echo "f $?"; }
f
i=0; while [ $i -lt 150 ]; do e ': <<<&'; e ': >#'; i=$((i + 1)); done 2>&1 | sort | uniq -c
