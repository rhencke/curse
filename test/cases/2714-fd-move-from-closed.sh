# `N>&M-` (a fd move) run in the shell onto an OPEN fd N from a CLOSED fd M: bash saves M for
# the undo of the move's close first, and that fails too — `redirection error: cannot
# duplicate fd: Bad file descriptor` before `M: Bad file descriptor`. Not for an external
# (forked: nothing to undo), a pipeline stage's or async command's own redirection, nor onto
# a closed N (nothing saved). curse said only the second line (fuzz F17).
exec 7>&- 8>&-
: >&7-; echo "builtin $?"
: <&7-; echo "input $?"
: 2>&7-; echo "stderr $?"
exec 5>/dev/null; : 5>&7-; echo "open five $?"; exec 5>&-
: 5>&7-; echo "closed five $?"
: >&1-; echo "self $?"
/bin/true >&7-; echo "external $?"
{ :; } >&7-; echo "group $?"
f() { :; }; f >&7-; echo "function $?"
g() { : >&7-; echo "in function $?"; }; g
eval ': >&7-'; echo "eval $?"
printf ': >&7-\necho "sourced $?"\n' > s2714.sh; . ./s2714.sh; rm -f s2714.sh
trap ': >&7-; echo "trap $?"' USR1; kill -USR1 $$; trap - USR1
( : >&7- ); echo "subshell $?"
x=$(: >&7-); echo "cmdsub $?"
: >&7- | cat; echo "stage $?"
{ :; } >&7- | cat; echo "group stage $?"
(: >&7-) | cat; echo "subshell stage $?"
: >&7- & wait $!; echo "async $?"
{ : >&7-; } | cat; echo "nested in stage"
n=0; for ((i = 0; i < 150; i++)); do : >&7- 2>/dev/null || n=$((n + 1)); done; echo "hot $n"
for ((i = 0; i < 150; i++)); do : >&7-; done 2>&1 | sort | uniq -c
