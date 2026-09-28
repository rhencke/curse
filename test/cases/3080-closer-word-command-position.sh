# A `]]` or `}` in command position is a reserved word — bash's "syntax error near
# unexpected token" (status 2) — when it is a whole token, ended by any metacharacter:
# `]] &`, `}(x`, `]]>f`. After an assignment or redirection prefix it is a command name
# again. curse ran `]]` as a command and named `x` for `}(x` (fuzz F116, F117).
e() { eval "$1"; echo "st $?"; }
e ']] &'
e ']]'
e ']];'
e ']] x'
e ']]>f'
e ']](x'
e '! ]]'
e '{ ]]; }'
e 'if ]]; then :; fi'
e 'while ]]; do :; done'
e '}(x'
e '}>f'
e '}|x'
e '}&'
e 'x=1 ]]'
e '}}'
e ']]]'
e 'echo ]] }'
e '[[ a ]] && echo dbracket'
f() { eval ']] &'; echo "f $?"; }
f
printf '%s\n' ']] &' 'echo notreached' > "${TMPDIR:-/tmp}/c3080"
. "${TMPDIR:-/tmp}/c3080"; echo "source $?"
rm -f "${TMPDIR:-/tmp}/c3080"
i=0; while [ $i -lt 150 ]; do e '}(x'; e ']]'; i=$((i + 1)); done 2>&1 | sort | uniq -c
