# The "line N: PID <signal>  <command>" report of a foreground command killed by a signal
# names the command's text. In a loop or a function the compiled tier printed the report
# with an empty command text (stress-attack S4): the command ran under the loop's
# break/continue catcher, `pcall(rt.exec_dynamic, …)`, which its text registry missed.
{
for s in ALRM; do $THIS_SH -c "kill -$s \$\$"; done
for s in TERM; do sh -c 'kill -USR2 $$'; done
for s in a; do for t in b; do $THIS_SH -c 'kill -HUP $$'; done; done
i=0; while ((i++ < 1)); do $THIS_SH -c "kill -ALRM \$\$"; done
f() { for s in 1; do $THIS_SH -c "kill -ALRM \$\$ # $s"; done; }; f
g() { $THIS_SH -c 'kill -USR1 $$'; }; g
eval 'for s in 1; do $THIS_SH -c "kill -TERM \$\$"; done'
( for s in 1; do $THIS_SH -c "kill -HUP \$\$"; done )
n=0
for ((i = 0; i < 150; i++)); do $THIS_SH -c "kill -ALRM \$\$ # $i" 2> /dev/null; ((n += $? == 142)); done
echo "loop: $n"
for ((i = 0; i < 2; i++)); do $THIS_SH -c "kill -USR2 \$\$ # at $i"; done
} 2>&1 | sed -E 's/(line [0-9]+:) +[0-9]+ /\1 PID /'
