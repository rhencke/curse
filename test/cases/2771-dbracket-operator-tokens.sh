# Inside [[ ]] the shell's other operator tokens (`>|`, `>>`, `<&`, `<>`, `|`, `;`, `&`) are
# read whole: "unexpected token `>|', conditional binary operator expected", then the
# syntax error near the text the lexer stopped after. And an extglob pattern is read only
# after ==/=/!= (or with extglob on as the line is read): `[[ x -le @(a|b) ]]` is a syntax
# error. curse split the operators and read @( … ) anywhere (fuzz F77, F78).
e() { eval "$1"; echo "st $?"; }
e '[[ !(a >| b) ]]'
e '[[ (a >| b) ]]'
e '[[ a >| b ]]'
e '[[ a >> b ]]'
e '[[ a <& b ]]'
e '[[ a <> b ]]'
e '[[ a && >| b ]]'
e '[[ a | b ]]'
e '[[ a ; b ]]'
e '[[ a & b ]]'
e '[[ x -le @(a|b) ]]'
e '[[ @(a|b) == x ]]'
e '[[ -n @(a) ]]'
e '[[ x < @(y) ]]'
e '[[ x == @(a|x) ]] && [[ x != @(y) ]] && [[ (a > b) ]] || echo ok'
i=0; while [ $i -lt 150 ]; do e '[[ a >> b ]]'; i=$((i + 1)); done 2>&1 | sort | uniq -c
