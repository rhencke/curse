# An async command without job control ignores SIGINT (setup_async_signals), and `trap`
# lists it as '' only once initialize_terminating_signals has seen it ignored — the first
# `trap` that process runs. A simple command's builtin or function forked from there (an
# async `trap -p &`, a pipeline stage) first runs set_sigint_handler, so unless a `trap`
# already latched it, SIGINT is not ignored there and `trap -p` lists nothing. curse listed
# `trap -- '' SIGINT` in those nested children (fuzz F9).
t() { eval "$1" | grep -c SIGINT; }
t '{ trap -p; } & wait'
t '{ trap -p & } & wait'
t '{ { trap -p; } & } & wait'
t '{ (trap -p) & } & wait'
t '{ trap -p | cat & } & wait'
t '( trap -p & ) & wait'
t '{ trap -p & wait; trap -p; } & wait'
t '{ trap "" INT; trap -p & wait; } & wait'
t '{ f() { trap -p; }; f & wait; } & wait'
t '{ trap -p INT & } & wait'
t '{ trap -p >/dev/null; trap -p & wait; } & wait'
t '{ trap -l >/dev/null; trap -p & wait; } & wait'
t '{ f() { trap -p; }; f | cat & wait; } & wait'
t '{ trap -p | cat; } & wait'
{ trap -p & } & wait
n=0; for ((i = 0; i < 150; i++)); do x=$({ trap -p & wait; } & wait); case $x in *SIGINT*) n=$((n + 1)) ;; esac; done
echo "loop $n"
