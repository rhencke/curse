# The DEBUG trap fires for an asynchronous command in the shell, before the job starts
# (execute_simple_command runs it before make_child), with $BASH_COMMAND the command itself —
# no `&`; for an async pipeline, before each simple stage; a compound job (subshell, group,
# loop) fires nothing. The interpreter fired nothing; the compiled tier showed `x=1 &` and
# fired for compound jobs (fuzz F84).
f() { :; }
trap 'echo "D $BASH_COMMAND" >&2' DEBUG
x=1 & wait
y=2 & echo z; wait
echo a | cat & wait
( : ) & wait
{ :; } & wait
f & wait
x=1 y=2 : & wait
for i in 1; do z=3 & wait; done
eval 'e=1 & wait'
trap - DEBUG
g() { trap 'echo "G $BASH_COMMAND" >&2' DEBUG; w=1 & wait; trap - DEBUG; }; g
i=0; while [ $i -lt 150 ]; do trap 'n=$((n+1))' DEBUG; : & wait; trap - DEBUG; i=$((i + 1)); done; echo "n=$n"
