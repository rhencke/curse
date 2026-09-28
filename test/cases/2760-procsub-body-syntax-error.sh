# bash 5.2 reads a <( … ) / >( … ) body with parse_comsub as the word is read, as it reads a
# $( … )'s: a syntax error in it is the script's syntax error on that line, and nothing of
# the line runs (in eval'd text it ends the shell: each case runs in a subshell). curse
# parsed the body only when it ran (fuzz F60).
e() { ( eval "$1"; echo "no" ); echo "st $?"; }
e 'echo <(if) x'
e 'cat < <(echo a; if)'
e 'echo >(fi) ok'
e 'cat <(:
function f)'
e 'echo <(echo ok) >/dev/null; echo fine'
printf 'echo before\ncat <(:\nfunction f)\necho no\n' > s2760.sh; ( . ./s2760.sh ); echo "source $?"
f() { e 'echo <(case) f'; }; f
i=0; while [ $i -lt 150 ]; do e 'cat <(done)'; i=$((i + 1)); done 2>&1 | sort | uniq -c
rm -f s2760.sh
cat <(:
function f)
echo not reached
