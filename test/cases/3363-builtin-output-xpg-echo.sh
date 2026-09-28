# Builtins print their listings as they are, never through echo: under `shopt -s xpg_echo`
# a backslash in a value `declare -p` shows must not be taken as an escape (curse printed
# `declare -- v="a\"` for v='a\'), and a value like `-n` is no option. Same for a
# regex capture, a `read`/`printf -v` value, alias, trap, export -p, set (fuzz F123, F124).
shopt -s xpg_echo
v='a\'; declare -p v
a=(x 'y\\' '-n' '\t'); declare -p a
s=$'x\x5c'
re=$'\x5cw\x5b\x5ea\x5d'
[[ $s =~ $re ]]
declare -p BASH_REMATCH
IFS=':,' read -r r1 r2 r3 <<< 'a,b\:xa\:'
declare -p r1 r2 r3
printf -v pv -- '%s %s' '1\\a%.3G\x41%#09(%s)T)T'
declare -p pv
alias al='echo \t x'; alias al
trap 'echo \n' USR2; trap -p USR2
f() { echo 'a\tb'; }; declare -f f
export E='x\ny'; export -p E
set | grep '^v='
g() { local w='a\\b'; local -p; }; g
echo 'plain\tstill'
eval 'declare -p v'
trap 'declare -p v' USR1
kill -USR1 $$
out=
for ((i = 0; i < 150; i++)); do x="$i\\"; out=$(declare -p x); done
echo "$out"
