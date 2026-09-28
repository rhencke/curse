# `{v}<&N` / `{v}>&N` with N closed: bash's fcntl(N, F_DUPFD, 10) fails — "redirection
# error: cannot duplicate fd", then "N: Bad file descriptor", status 1. And a null command
# with a {v} redirection (or an input one onto fd 0) runs it in a forked child: v is never
# set in the shell. curse took the free fd 10 as the source itself and succeeded (fuzz F82).
{v}<&10; echo "st $? v=$v"
{v}>&10; echo "out $?"
: {v}<&10; echo "colon $? v=$v"
cat {v}<&10; echo "cat $?"
{ :; } {v}<&10; echo "group $?"
exec {v}<&10; echo "exec $?"
{v}<&1; echo "null $? v=$v"
: {w}<&1; echo "cmd v=${w:+set}"
v=5; {v}>/dev/null; echo "kept v=$v"
</dev/null; echo "stdin $?"
f() { {u}<&12; echo "f $? u=$u"; }; f
i=0; while [ $i -lt 150 ]; do {q}<&13; echo "l $? q=$q"; i=$((i + 1)); done 2>&1 | sort | uniq -c
