# A `{v}>…` redirection's own errors (bash's redirection_error: error < 0 with
# REDIR_VARASSIGN) name the variable, not the target: ambiguous redirect, noclobber.
exec 2>&1
u="a b"
exec {v}>$u; echo "st=$?"
exec {w}>$nope; echo "st=$?"
exec {x}<$u; echo "st=$?"
exec {y}>>$u; echo "st=$?"
: {z}>$u; echo "st=$?"
exec {q}>&$u; echo "st=$?"
f() { :; } {r}>$u; f; echo "st=$?"
touch ex; set -C
exec {c}>ex; echo "st=$?"
: >ex; echo "st=$?"
set +C; rm -f ex
: >$u; echo "st=$?"
h() { : {k}>$u; }
for ((i = 0; i < 160; i++)); do h; done 2>&1 | uniq -c
