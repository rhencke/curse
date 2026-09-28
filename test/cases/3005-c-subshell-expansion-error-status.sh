# bash -c: a fatal expansion error jumps to the -c string's top level — status 127
# (run_one_command) — but a subshell, a command substitution or a compound pipeline stage
# has a top level of its own and exits 1; a simple command forked straight from
# execute_simple_command (a pipeline stage, `cmd &`) shares the -c string's (fuzz F93).
S=${THIS_SH:-bash}
t() { "$S" -c "$1" 2>/dev/null; echo "top=$?"; }
t '( : ${x?} ); echo "sub=$?"'
t 'y=$( : ${x?} ); echo "cs=$?"'
t '( ( : ${x?} ); echo "in=$?" ); echo "out=$?"'
t '( f() { : ${x?}; }; f ); echo "f=$?"'
t '( set -u; : $zz ); echo "u=$?"'
t 'cat </dev/null | : ${x?}; echo "p=$?"'
t 'cat </dev/null | { : ${x?}; }; echo "pg=$?"'
t ': ${x?} & wait $!; echo "bg=$?"'
t '{ : ${x?}; } & wait $!; echo "bgg=$?"'
t ': ${x?}; echo no'
t 'f() { : ${x?}; }; f; echo no'
t 'y=`: ${x?}`; echo "bq=$?"'
t 'i=0; while [ $i -lt 150 ]; do ( : ${x?} ); s=$s$?; i=$((i + 1)); done; echo "${#s} ${s%%[!1]*}" | cut -c1-12'
