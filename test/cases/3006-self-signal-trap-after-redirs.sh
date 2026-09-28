# A signal `kill` sends the shell itself is taken once the command is done: its trap runs
# after kill's own redirections are undone (bash runs pending traps at the end of the
# command), but inside an enclosing group's (fuzz leftover M1).
trap 'echo T' USR1
kill -USR1 $$ >/dev/null
echo a
kill -USR1 $$ 2>/dev/null >/dev/null; echo b
{ kill -USR1 $$; echo g; } >/dev/null; echo c
f() { kill -USR1 $$ >/dev/null; echo inf; }; f
eval 'kill -USR1 $$ >/dev/null'; echo d
i=0; while [ $i -lt 150 ]; do kill -USR1 $$ >/dev/null; i=$((i + 1)); done | wc -l
trap - USR1
