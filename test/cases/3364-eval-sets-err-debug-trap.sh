# An ERR or DEBUG trap the program sets through eval / source / a non-literal signal name
# fires as a literal `trap` does. The compiled tier only hooked the traps it saw in the
# program's text: `eval "trap … ERR"; false` ran no trap, so a variable the trap sets
# stayed unset (fuzz F121: `$v echo hi` then ran `echo hi` instead of a command `!`).
eval "trap \"v='!'\" ERR"
false
$v echo hi
echo "status $?"
trap - ERR
eval "trap 'echo ERR at \$LINENO' ERR"
false
f() { false; }; f
source /dev/stdin <<< "trap 'echo U' ERR"
false
x=$(false)
S=ERR; trap 'echo T' $S; false
t=trap; $t 'echo V' ERR; false
trap - ERR
eval "trap 'echo D' DEBUG"
echo x
trap - DEBUG
n=0
eval 'trap "n=\$((n + 1))" ERR'
for ((i = 0; i < 160; i++)); do false; done
echo "err trap ran $n"
