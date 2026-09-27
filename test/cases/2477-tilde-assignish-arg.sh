# A command ARGUMENT shaped like an assignment (`NAME=…`, non-posix) tilde-expands after
# every unquoted `:` in the whole word, not just in its first literal: bash's
# expand_word_internal keeps the assignment rule going past `$x` (`echo z=$x:~`).
HOME=/hh x=q
echo z=$x:~
env z=$x:~ printenv z
echo z=$x:~/d z=${x}:~:$x:~ z=$x:~root 9z=$x:~ z=$x"":~ z="$x":~ "z"=$x:~
echo a[1]=$x:~ z+=$x:~
echo z=$x:\~ z=$x:"~" z=$x~
export e=$x:~; echo "$e"
f() { echo "$@"; }
for ((i = 0; i < 160; i++)); do f w=$x:~ v=$i:~; done | sed 's/v=[0-9]*/v=N/' | uniq -c
set -o posix
echo z=$x:~ z=q:~
