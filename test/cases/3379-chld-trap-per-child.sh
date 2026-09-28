# bash runs a SIGCHLD trap once for every child it reaps — a subshell, a $(…), each
# pipeline stage, a background job, an external. curse runs subshells, $(…), builtin stages
# and `( … ) &` jobs in-process: no child, no trap (stress-attack S22; bash counts 1 2 3 5 6 7
# on the first six lines, curse counted 0 0 1 1 2 3). A context bash's child would have
# exec'd its last external in place counts once (that external's own SIGCHLD); a subshell
# that set no CHLD trap of its own counts none inside it.
c=0; trap 'c=$((c + 1))' CHLD
( : ); echo "subshell: $c"
x=$(:); echo "comsub: $c"
( : ) & wait; echo "job: $c"
: | :; echo "pipeline: $c"
/bin/true; echo "external: $c"
{ :; } & wait; echo "group job: $c"
( /bin/true ); echo "subshell exec: $c"
x=$(/bin/echo a); echo "comsub exec: $c"
: | /bin/true; echo "mixed pipeline: $c"
: | : | :; echo "3 stages: $c"
f() { ( : ); x=$(:); }; f; echo "function: $c"
eval '( : ); x=$(:)'; echo "eval: $c"
x=$( ( : ); echo $c ); echo "nested: $c [$x]"
( trap 'echo inner' CHLD; ( : ); x=$(:) ); echo "subshell with its own: $c"
( : ; : ); echo "two builtins: $c"
if ( false ); then :; fi; echo "if: $c"
( exit 3 ); echo "status $?: $c"
x=$(exit 4); echo "status $?: $c"
for ((i = 0; i < 150; i++)); do ( : ); done; echo "loop: $c"
trap - CHLD
