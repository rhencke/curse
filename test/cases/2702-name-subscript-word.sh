# Where an assignment may start (bash's assignment_acceptable), a word that is a NAME so
# far then `[` reads the subscript as one piece (read_token_word's P_ARRAYSUB group):
# blanks, quotes, `;` and newlines are part of it, whether or not `=` follows — `a[b c]x` is
# one word, a command name — and one never closed is "unexpected EOF while looking for
# matching `]'". curse split the word at the blank (command `a[b`) and reported an unclosed
# one as "syntax error near unexpected token `a[b'" (fuzz F10).
S=${THIS_SH:-bash}
t() { "$S" -c "$1" 2>&1 | sed 's/^[^:]*: //'; echo "rc=${PIPESTATUS[0]}"; }
declare -A a
a[b c]=1; echo "${!a[@]}"
a[x y]=2 a[p q]=3; echo "${a[x y]} ${a[p q]}"
a[k;l]=4; echo "${a[k;l]}"
a[$(echo "m n")]=5; echo "${a[m n]}"
a[b c]x y 2>&1 | sed 's/^.*line [0-9]*: //'
a[b c] y 2>&1 | sed 's/^.*line [0-9]*: //'
x=1 a[p q] y 2>&1 | sed 's/^.*line [0-9]*: //'
echo a[b c d]
if a[i j]=6; then echo "if ${a[i j]}"; fi
f() { a[f g]=7; echo "fn ${a[f g]}"; }; f
eval 'a[e v]=8'; echo "eval ${a[e v]}"
eval 'a[e v'; echo "eval st=$?"
for ((i = 0; i < 150; i++)); do a[k $i]=$i; done; echo "loop ${a[k 149]} ${#a[@]}"
t 'a[b c'
t 'a[b c
echo after'
t 'a["]"'
t 'a[$(echo x'
t 'x=1 a[q'
t 'echo a[b c'
