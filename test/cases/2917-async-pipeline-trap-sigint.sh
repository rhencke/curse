# Without job control an async pipeline's COMPOUND stages start with SIGINT ignored, as an
# async compound command does, and `trap -p` lists it: `{ trap -p; } | cat &` shows
# `trap -- '' SIGINT`; a simple-command stage (a builtin, a function) doesn't (leftover L18).
{ trap -p; } | cat &
wait
echo --
( trap -p ) | cat &
wait
echo --
echo | { trap -p; } &
wait
echo --
if :; then trap -p; fi | cat &
wait
echo --
trap -p | cat &
wait
echo --
f() { trap -p; }; f | cat &
wait
echo --
trap 'echo t' USR1
{ trap -p; } | cat &
wait
trap - USR1
echo --
{ trap -p; } | cat
echo --
eval '{ trap -p; } | cat &'; wait
printf '{ trap -p; } | cat &\nwait\n' > s2917.sh; . ./s2917.sh; rm -f s2917.sh
i=0; while [ $i -lt 150 ]; do { trap -p; } | { read -r l; echo "$l"; } & wait; i=$((i + 1)); done | sort | uniq -c
