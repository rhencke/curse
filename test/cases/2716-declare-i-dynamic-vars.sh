# `declare -i` on a live dynamic variable (LINENO, BASH_SUBSHELL, SECONDS, RANDOM, …) with a
# value: bash sets the attribute, then hands the value to the variable's assign function AS
# WRITTEN (only += evaluates: the old value plus the new) — which takes it its own way
# (legal_number, or evalexp for an integer RANDOM/SECONDS). curse escaped a Lua error
# (`attempt to index local 'ib'`) and stopped (fuzz F19). Also a plain assignment to such an
# integer variable goes to the assign function unevaluated.
declare -i LINENO=1
echo "after $?"
declare -i LINENO=x+; echo "bad $?"
declare -i BASH_COMMAND=5; declare -p BASH_COMMAND
declare -il BASH_COMMAND=X; declare -p BASH_COMMAND
declare -i BASHPID=7; declare -p BASHPID | sed 's/"[0-9]*"/N/'
declare -i BASH_SUBSHELL=2+3; echo "bs $BASH_SUBSHELL"
declare -i BASH_SUBSHELL=7; echo "bs $BASH_SUBSHELL"
declare -i BASH_SUBSHELL+=2+3; echo "bs $BASH_SUBSHELL"
BASH_SUBSHELL=2+3; echo "bs plain $BASH_SUBSHELL"
declare -i SECONDS=2+3; echo "sec $((SECONDS >= 5 && SECONDS < 100))"
declare -i RANDOM=5; a=$RANDOM; RANDOM=5; b=$RANDOM; [ "$a" = "$b" ] && echo "random seeded once"
declare -i RANDOM=2+3; a=$RANDOM; RANDOM=5; b=$RANDOM; [ "$a" = "$b" ] && echo "random evaluated"
declare RANDOM=5; a=$RANDOM; RANDOM=5; b=$RANDOM; [ "$a" = "$b" ] && echo "declare RANDOM draws nothing"
declare -i FUNCNAME=1; echo "funcname $?"
unset LINENO; declare -i LINENO=2+2; echo "unset then $LINENO"
f() { local -i BASH_COMMAND=4; echo "local $?"; declare -p BASH_COMMAND; }; f
eval 'declare -i BASH_SUBSHELL=3; echo "eval $BASH_SUBSHELL"'
printf 'declare -i BASH_ARGV0=2+3; echo "source $0"\n' > s2716.sh; (. ./s2716.sh); rm -f s2716.sh
trap 'declare -i BASH_COMMAND=1; echo "trap $?"' USR1; kill -USR1 $$; trap - USR1
n=0; for ((i = 0; i < 150; i++)); do declare -i BASH_COMMAND=$i && n=$((n + 1)); done; echo "hot $n"
