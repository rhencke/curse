# Where a syntax error follows a token, bash first reads that token whole: a word after
# `NAME (` (`+($(x`: its unclosed `$(` is the error; `f ($(x) y)` names `$(x)`), a word
# after `&>` at the start of a command (`&>$(x`), and a `$((` text, read as arithmetic
# (P_ARITH: a `${` nests nothing there, so `$(( ${#a` wants `)`). After `for`, a comment
# runs to the newline token and an operator is named whole (fuzz F117).
e() { eval "$1"; echo "st $?"; }
e '+($(x'
e 'x+($(x'
e '@($(x'
e '&>$(x'
e '&>>$(x'
e '&>`x'
e '+(a)'
e 'f ($(x) y)'
e 'f ( "a b" )'
e 'f ( #c'
e 'f ( ;'
e 'f ( ${x'
e 'f ( <<<'
e ': $(( ${#a'
e ': $(( ${a'
e 'a=$(( ${a'
e ': $(( a[${a'
e ': $(( (${a'
e ': $(( "a'
e ': $(( $(a'
e 'echo $( (echo a) )'
e 'echo $(( (1) ))'
e 'for  #3'
e 'for #'
e 'for ;'
e 'for &&'
e 'for |&'
e 'for <<<'
e 'for a&b'
e 'for a>b in x; do :; done'
e 'select #x'
f() { eval '+($(x'; echo "f $?"; }
f
i=0; while [ $i -lt 150 ]; do e ': $(( ${#a'; e 'for &&'; i=$((i + 1)); done 2>&1 | sort | uniq -c
