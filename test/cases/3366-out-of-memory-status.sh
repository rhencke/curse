# Running out of memory under `ulimit -v`: bash reports `NAME: xmalloc: cannot allocate N
# bytes` (fatal_error: no line) and that shell exits with status 2 — a subshell only
# itself, its parent goes on. curse let LuaJIT's "not enough memory" escape as a Lua error
# with a traceback, status 1 (stress-attack S18). N is bash's request size, which curse
# can't know (docs/bash-ub.md), nor whether it grew a buffer (xrealloc): masked.
m() { sed -E 's/^[^ ]*: x(m|re)alloc: cannot allocate [0-9]+ bytes$/SH: xmalloc: cannot allocate N bytes/'; }
$THIS_SH -c 'ulimit -v 400000; s=x; while :; do s=$s$s; done; echo never' 2>&1 | m; echo "string doubling: ${PIPESTATUS[0]}"
$THIS_SH -c 'ulimit -v 400000; a=(); i=0; while :; do a[i++]=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx$i; done' 2>&1 | m; echo "array growth: ${PIPESTATUS[0]}"
$THIS_SH -c 'ulimit -v 400000; x=$(head -c 300000000 /dev/zero | tr "\0" a); echo ${#x}' 2>&1 | m; echo "huge comsub: ${PIPESTATUS[0]}"
$THIS_SH -c 'ulimit -v 400000; trap "echo exit trap" EXIT; s=x; while :; do s=$s$s; done' 2>&1 | m; echo "EXIT trap: ${PIPESTATUS[0]}"
$THIS_SH -c 'ulimit -v 400000; ( s=x; while :; do s=$s$s; done ); echo "subshell: $?"; t=$(s=x; while :; do s=$s$s; done); echo "comsub: $?"' 2>&1 | m
$THIS_SH -c 'ulimit -v 400000; f() { local s=x; while :; do s=$s$s; done; }; (f); echo "function: $?"; (eval "s=x; while :; do s=\$s\$s; done"); echo "eval: $?"' 2>&1 | m
$THIS_SH -c 'ulimit -v 400000; trap "( s=x; while :; do s=\$s\$s; done ); echo \"trap: \$?\"" USR1; kill -USR1 $$; echo after' 2>&1 | m
$THIS_SH -c 'ulimit -v 400000; for ((i = 0; i < 150; i++)); do if ((i == 149)); then ( s=x; while :; do s=$s$s; done ); echo "loop $i: $?"; fi; done' 2>&1 | m
