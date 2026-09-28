# The word after `=~` (read_token_word under PST_REGEXP) ends at a metacharacter — a
# blank, newline, `;` `&` `<` `>` `)` — except inside a ( … ) group, read whole; a [ … ]
# bracket shields nothing, and `]]` ends [[ only as a word of its own. `[[ x =~ ^[^;]+ ]]`
# is a syntax error; an unclosed `(` is parse_matched_pair's EOF error. curse took the
# bracket's `;` and ended the word at an inner `]]` (fuzz F115).
e() { eval "$1"; echo "st $?"; }
e '[[ x =~ ^[^;]+ ]]'
e '[[ x =~ [;] ]]'
e '[[ x =~ a; ]]'
e '[[ x =~ ^(a|b^ ]]'
e '[[ "a " =~ a\ ]] && echo y'
e '[[ x =~ ab\  ]]'
e '[[ x =~ (;) ]]'
e '[[ " " =~ [[:space:]] ]]'
e '[[ a =~ [a b] ]]'
e '[[ ab =~ (a|b)+ ]] && echo "${BASH_REMATCH[@]}"'
e '[[ "a b" =~ (a b) ]]'
e '[[ a =~ a]] ]]'
e '[[ a]] =~ a]] ]]'
e '[[ a =~ a&&b ]]'
e '[[ a =~ a||b ]]'
e '[[ a =~ (a) && b ]]'
e '[[ a =~ ((a)) ]]'
e '[[ a =~ a
]]'
f() { [[ "x;" =~ x\; ]]; echo "f $?"; }
f
[[ x =~ ^[^\;]+ ]]; echo "escaped $?"
i=0; while [ $i -lt 150 ]; do e '[[ x =~ [;] ]]'; [[ "x]]" =~ ^x]]$ ]] && echo m; i=$((i + 1)); done 2>&1 | sort | uniq -c
