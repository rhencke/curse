# A command's prefix binding of a readonly or noassign variable (BASH_SOURCE, FUNCNAME,
# GROUPS, BASH_ARGV, …) is refused before its value is expanded (assign_in_env): no command
# substitution in it runs — the readonly one reported. curse expanded the value first
# (`disown: current: no such job` from `BASH_SOURCE=$(disown | …) p`, fuzz F85).
BASH_SOURCE=$(disown|while(())do c;done) p
BASH_SOURCE=$(echo hi >&2) :
FUNCNAME=$(echo hi >&2) true
f(){ :; }; FUNCNAME=$(echo hi >&2) f
GROUPS=$(echo hi >&2) :
BASH_ARGC=$(echo hi >&2) /bin/true
DIRSTACK=$(echo dir >&2) :
x=$(echo a >&2) BASH_ARGV=$(echo hi >&2) y=$(echo b >&2) :
readonly r=1
r=$(echo hi >&2) :; echo "ro $?"
r=$(echo hi >&2) /bin/true; echo "ro-ext $?"
r=$(echo hi >&2) /bin/true >/nonexist/x; echo "ro-redir $?"
( set -x; r=$(echo hi >&2) z=1 /bin/true; BASH_LINENO=$(echo hi >&2) : ) 2>&1
i=0; while [ $i -lt 150 ]; do BASH_SOURCE=$(echo no >&2) :; r=$(echo no >&2) :; i=$((i + 1)); done 2>&1 | sort | uniq -c
