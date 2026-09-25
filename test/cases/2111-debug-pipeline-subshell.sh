# DEBUG around pipelines (bash fires it in the parent before each simple/[[/((/case stage
# — not for a { }/( ) stage; a lastpipe last stage fires its own) and inside subshells
# under functrace, where an extdebug DEBUG status skips the command; a `( … )` body and a
# redirected { } body compile with their DEBUG hooks.
trap 'echo "D: $BASH_COMMAND"' DEBUG
echo a | cat
echo b | { read x; echo "$x"; } | cat
f() { echo f; }
f | cat
true | false; echo "${PIPESTATUS[@]}"
! echo neg | cat
shopt -s lastpipe
echo lp | read v; echo "$v"
shopt -u lastpipe
{ echo g1; echo g2; } 2>&1
( echo s1 )
trap - DEBUG
shopt -s extdebug
set -T
trap 'if [[ $BASH_COMMAND == *skip* ]]; then false; else echo "D $BASH_COMMAND"; fi' DEBUG
( echo a; echo skip; echo c )
h() { echo h1; echo skip; echo h2; }
h
{ echo r1; echo skip; echo r2; } 2>&1
echo done
