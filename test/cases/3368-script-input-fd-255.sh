# bash reads a script through fd 255 (read-only, its offset past what it has read; every
# subshell closes it). A script's `exec 255>FILE` moves bash's input elsewhere but leaves
# fd 255 on the script: FILE is created, and `echo … >&255` fails with `write error: Bad
# file descriptor`. curse wrote through it (stress-attack S19); a plain `>&255` was a
# redirection error, and reading `<&255` got bash's EOF wrong.
echo "plain" >&255; echo "plain: $?"
read -r l <&255; echo "read: $? [$l]"
( echo "subshell" >&255 ); echo "subshell: $?"
x=$(echo "comsub" >&255); echo "comsub: $? [$x]"
echo "pipe" >&255 | cat; echo "pipeline: ${PIPESTATUS[*]}"
f() { echo "function" >&255; }; f; echo "function: $?"
eval 'echo "eval" >&255'; echo "eval: $?"
trap 'echo "trap" >&255; echo "trap: $?"' USR1
kill -USR1 $$
n=0
for ((i = 0; i < 150; i++)); do echo "$i" >&255 2> /dev/null || n=$((n + 1)); done
echo "loop failures $n"
exec 255> f255
echo "via 255" >&255
echo "status $?"
echo "again" >&255; echo "again: $?"
exec 255>&-
echo "[$(cat f255)]"
exec 255> f255b; echo "reopened" >&255; echo "reopened: $?"; exec 255>&-
echo "[$(cat f255b)]"
rm -f f255 f255b
