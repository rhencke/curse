#@ guards: `kill -SIG $$` from inside pipeline stages, subshells, $(…), background jobs and nested combinations: bash runs the PARENT's trap exactly once, in the parent's context (its variable changes stick); in curse those contexts run in-process (inproc-subshells: checkpoint/restore, pipelines as coroutines), so the trap must escape the stage's state rollback. Also: no zombie is left behind (a trap interrupting a wait for a $(…) child)
#@ timeout: 20
n=0
trap 'n=$((n+1))' USR1
t() { # LABEL: run the command string; the trap must have run exactly once, in our context
	local before=$n
	eval "$2" >/dev/null
	echo "$1: traps=$((n - before))"
}
t "first stage"        '{ kill -USR1 $$; echo a; } | cat'
t "middle stage"       'echo a | { kill -USR1 $$; cat; } | cat'
t "last stage"         'echo a | { kill -USR1 $$; cat; }'
t "every stage"        '{ kill -USR1 $$; echo a; } | { cat; } ; { kill -USR1 $$; echo b; } | cat'
t "subshell"           '( kill -USR1 $$ )'
t "nested subshell"    '( ( kill -USR1 $$ ) )'
t "comsub"             'x=$(kill -USR1 $$; echo v)'
t "comsub in subshell" '( x=$(kill -USR1 $$) )'
t "stage in comsub"    'x=$(echo a | { kill -USR1 $$; cat; })'
t "background"         '{ kill -USR1 $$; } & wait $!'
t "bg subshell"        '( kill -USR1 $$ ) & wait $!'
t "function in stage"  'k() { kill -USR1 $$; }; k | cat'
t "eval in subshell"   '( eval "kill -USR1 \$\$" )'
# the trap itself inside a stage: its variable change belongs to the stage
m=0; trap 'm=$((m+1))' USR2
{ kill -USR2 $BASHPID; echo "stage m=$m"; } | cat
( kill -USR2 $BASHPID; echo "subshell m=$m" )
echo "parent m=$m"
# an EXTERNAL signalling a subshell by its $BASHPID reaches it (bash: a real process)
( trap 'echo "  subshell trap"' USR2; /bin/kill -USR2 $BASHPID 2>/dev/null || echo "  kill failed"; echo "subshell goes on" )
trap - USR1 USR2
# a trap's `exit N` ends the SHELL with N — from a stage, a subshell, a $(…), a job (its
# hook fired while that in-process context ran: the trap is still the shell's)
for c in '{ kill -TERM $$; echo a; } | cat' '( kill -TERM $$ )' 'x=$(kill -TERM $$; echo v)' \
	'{ kill -TERM $$; } & wait' '{ kill -TERM $$; } & while (( SECONDS < 5 )); do :; done'; do
	"$THIS_SH" -c 'trap "exit 9" TERM; eval "$1"; echo "ran on"; exit 3' _ "$c" >/dev/null
	echo "exit in trap, $c: status $?"
done
# a trap interrupting the wait for a $(…) child must not leak a zombie
trap 'n=$((n+1))' USR1
for k in 1 2 3 4 5; do x=$("$STH" sendwhen $$ 10 3000 any; echo in); done
echo "comsub x=$x n=$n"
z=$(ps -o stat= --ppid $$ | grep -c '^Z'); echo "zombies: $([ $z = 0 ] && echo none || { echo "zombies: $z" >&2; echo SOME; })"
"$STH" probe
