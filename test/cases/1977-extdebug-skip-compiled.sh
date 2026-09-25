# shopt -s extdebug compiles: a DEBUG trap returning non-zero skips the command (at the
# top level and inside a function), 2 in a function returns from it; BASH_ARGV/BASH_ARGC
# carry every call's frame
shopt -s extdebug
skip() { [[ $BASH_COMMAND == *SKIP* ]] && return 1; return 0; }
trap skip DEBUG
for i in 1 2; do echo "run $i"; echo "SKIP $i"; x=$i; done
echo "x=$x"
f() { echo "in f"; echo "SKIP in f"; echo "f end"; }
f; f
trap - DEBUG
g() { echo "args: ${BASH_ARGV[*]} counts: ${BASH_ARGC[*]}"; }
h() { g c d; }
h a b
ret2() { [[ $BASH_COMMAND == *LEAVE* ]] && return 2; return 0; }
k() { echo before; echo LEAVE; echo after; }
trap ret2 DEBUG
k; echo "k=$?"
trap - DEBUG
