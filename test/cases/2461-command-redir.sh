# A fatal expansion error (set -u, ${v?}) in a redirection: bash expands an EXTERNAL
# command's redirections in its forked child, so only that command fails (status 1) —
# looking through `command [-p] [--] NAME` — while a builtin's or function's is fatal.
# One policy (rt.redir_forks) for every tier: cold, OSR'd loops, functions, fragments.
# Also: a restricted shell's {v}> (readonly or not) opens nothing, and a here-document
# whose temp fd can't be made fails its command with bash's message.
set -u
command ls > $nope; echo "a $?"
command -p -- cat </dev/null > ${nosuch?boom}; echo "b $?"
command -- ls > $nope; echo "c $?"
command command ls > $nope; echo "d $?"
x=1 command ls > $nope; echo "e $?"
ls > $nope; echo "f $?"
x=1 ls > $nope; echo "g $?"
cmd=ls; $cmd > $nope; echo "h $?"
cmd=command; $cmd ls > $nope; echo "h2 $?"
ls() { echo fn; }
command ls -d . > $nope; echo "i $?"
unset -f ls
n=0; for i in $(seq 300); do command ls -d . > $nope; n=$((n+1)); done 2>/dev/null; echo "n=$n"
f() { command ls -d . > $nope; x=1 command -p -- ls > $nope; }
n=0; for i in $(seq 200); do f; n=$((n+1)); done 2>/dev/null; echo "fn n=$n"
eval 'command ls > $nope; echo "k $?"'
n=0; for i in $(seq 200); do eval 'command ls -d . > $nope'; n=$((n+1)); done 2>/dev/null; echo "ev n=$n"
trap 'command ls > $nope; echo "tr $?"' USR1; kill -USR1 $$; trap - USR1
echo 'command ls > $nope; echo "src $?"' > src.sh; . ./src.sh
( command echo > $nope; echo "not reached" ); echo "q $?"
( builtin echo > $nope; echo "not reached" ); echo "r $?"
$THIS_SH -r -c 'readonly w; echo a {w}> f1; echo "ro $?"; echo b {v}> f1; echo "rw $? v=${v-}"' 2>&1 | sed 's/^.*line 1: //'
ls f1 2>/dev/null || echo "no f1"
$THIS_SH -c 'exec 3</dev/null 4</dev/null 5</dev/null 6</dev/null; ulimit -n 7; cat <<E
hi
E
echo "hd $?"' 2>&1 | sed 's/^.*line 1: //'
echo > $nope3; echo "not reached"
