# `declare -a` on a live dynamic variable (LINENO, SECONDS, RANDOM) converts it to an
# array whose element 0 is its current value (RANDOM and SECONDS stay integer: -ai);
# `declare -a LINENO=3` / `-ai LINENO=3+1` store an array, not a scalar (leftover L15).
declare -a LINENO=3; declare -p LINENO; echo "$LINENO ${LINENO[0]}"
echo "$LINENO"
LINENO[1]=x; declare -p LINENO
declare -a SECONDS; declare -p SECONDS
declare -a SECONDS=5; declare -p SECONDS
declare -a RANDOM; declare -p RANDOM | sed 's/="[0-9]*"/=N/'
declare -ai BASH_SUBSHELL=2+3; declare -p BASH_SUBSHELL
f() { local -a LINENO=9; declare -p LINENO; declare -ai SRANDOM=1+1; declare -p SRANDOM; }; f
eval 'declare -ai EPOCHSECONDS=4*2; declare -p EPOCHSECONDS'
printf 'declare -a HISTCMD=7; declare -p HISTCMD\n' > s2914.sh; . ./s2914.sh
trap 'declare -a BASHPID=1; declare -p BASHPID' USR1; kill -USR1 $$; trap - USR1
for ((i = 0; i < 150; i++)); do declare -a BASH_COMMAND=$i; done; declare -p BASH_COMMAND
rm -f s2914.sh
