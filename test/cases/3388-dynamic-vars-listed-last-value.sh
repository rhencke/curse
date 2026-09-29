# Pinned bash behaviour: a dynamic variable's getter stores the value it computes, so a
# listing — `set`, `declare -p` with no names, bare `declare` — shows the value LAST READ
# (never read: `declare -p` lists it bare, `set` not at all). A read in a subshell or a
# $( … ) stays there. The dynamic arrays are listed by `set` too.
lst() { set | grep -E '^(LINENO|SECONDS|RANDOM|SRANDOM|BASHPID|EPOCHSECONDS|BASH_SUBSHELL|HISTCMD|BASH_ARGV0|BASH_COMMAND|OSTYPE|HOSTTYPE|MACHTYPE)=' | sed -E 's/=[0-9]+$/=N/'; echo "--"; }
dp() { declare -p | grep -E '^declare -[-a-zA-Z]+ (LINENO|SECONDS|RANDOM|BASHPID|EPOCHSECONDS)\b' | sed -E 's/="[0-9]+"/=N/'; echo "--"; }
lst; dp
x=$(echo $RANDOM $LINENO $SECONDS); ( y=$BASHPID$EPOCHSECONDS )
echo "$x" | cat >/dev/null
lst; dp
a=$LINENO; b=$SECONDS; c=$RANDOM
lst; dp
set | grep -E '^LINENO='
f() { local l=$LINENO; set | grep -E '^LINENO='; }
f
RANDOM=7
set | grep -E '^RANDOM='
unset RANDOM
set | grep -E '^RANDOM='
for ((i = 0; i < 150; i++)); do z=$LINENO; done
set | grep -E '^LINENO='
declare -i | grep -E '^declare -i (SECONDS|LINENO)' | sed -E 's/="[0-9]+"/=N/'
set | grep -E '^(BASH_ARGC|BASH_ARGV|BASH_LINENO|DIRSTACK|GROUPS|FUNCNAME)='
g=${GROUPS[0]}; set | grep -E '^GROUPS=' | sed -E 's/^GROUPS=\(\[0\]="[0-9]+".*/GROUPS=(read)/'
h() { set | grep -E '^(FUNCNAME|BASH_LINENO)='; }; h
