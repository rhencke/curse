# variables.c audit: dynamic/special variable assign+unset semantics, noassign/
# nounset attributes, local copies of special vars, unset-local attribute reset,
# tempenv (+= on -i, array names), export of arrays, nameref depth/array assign,
# BASH_ALIASES/BASH_CMDS element unset, `set` array quoting, PATH hash flush,
# BASH_COMPAT/BASH_XTRACEFD checks, initialization (child shell via $THIS_SH).
e() { "$@" 2>&1 | sed 's/^.*line [0-9]*: //'; }

# --- RANDOM / SECONDS / other dynamic vars (assign_random, assign_seconds, null_assign)
RANDOM=42; echo "rand: $RANDOM $RANDOM"
RANDOM=7; (RANDOM=5; echo "subshell-seeded: $RANDOM"); RANDOM=5; echo "seeded: $RANDOM"
declare -i RANDOM; RANDOM=40+2; echo "int-seed: $RANDOM"
SECONDS=abc; [ "$SECONDS" -le 1 ] && echo "sec-bad=0ish"  # (0; a second boundary may pass under load)
BASH_SUBSHELL=3; (echo "sub:$BASH_SUBSHELL"); BASH_SUBSHELL=x; echo "bs:$BASH_SUBSHELL"; (echo "bs2:$BASH_SUBSHELL")
EPOCHSECONDS=5; [ "$EPOCHSECONDS" -gt 1000 ] && echo epoch-stays-dynamic
BASHPID=5; [ "$BASHPID" != 5 ] && echo bashpid-stays-dynamic
BASH_COMMAND=zz; echo "bc=$BASH_COMMAND"
HISTCMD=3; echo "hc=$HISTCMD"
BASH_SOURCE=5; echo "bsrc=[${BASH_SOURCE##*/}]"
printf 'cwb=%q\n' "$COMP_WORDBREAKS"
echo "BASH=${BASH+set} OSTYPE=${OSTYPE+set} HOSTTYPE=${HOSTTYPE+set} MACHTYPE=${MACHTYPE+set}"
declare -p BASH_ARGV0 | sed 's/=.*//'

# --- unset removes the dynamic behavior; later assignments are plain
( unset EPOCHSECONDS; echo "u-epoch=[$EPOCHSECONDS]" )
( unset SECONDS; echo "u-sec=[$SECONDS]" )
( unset GROUPS; GROUPS=(1 2); echo "u-groups:${GROUPS[*]}" )
( unset FUNCNAME; f() { echo "u-fn:[${FUNCNAME[*]}]"; }; f )
( BASH_ARGV0=foo; unset BASH_ARGV0; BASH_ARGV0=bar; echo "argv0:$0" )
( BASH_ARGV0=foo; f() { echo "in-func:$0"; }; f )
for v in BASH_SOURCE BASH_LINENO BASH_ARGC BASH_ARGV; do (unset $v 2>/dev/null; echo "unset $v st=$?"); done

# --- local copies of special vars: plain (no inherit) unless localvar_inherit
f() { local RANDOM=1; echo "loc-rand:$RANDOM $RANDOM"; }; f
f() { local LINENO=3; echo "loc-lineno:$LINENO"; }; f
f() { local GROUPS=1; echo "st=$?"; }; e f
f() { local FUNCNAME=1; echo "st=$? ${FUNCNAME}"; }; e f
shopt -s localvar_inherit
f() { local RANDOM; echo "inh-rand:${RANDOM:+nonempty}"; local LINENO; echo "inh-ln:$LINENO"; }; f
shopt -u localvar_inherit

# --- unsetting a local drops its attributes (the placeholder is plain)
g() { local -i v=3; unset v; v=1+1; echo "g:$v"; local -u u=a; unset u; u=b; echo "u:$u"; }; g
g2() { local -x ex=1; unset ex; ex=2; env | grep -c '^ex='; }; g2

# --- temporary environment
declare -i n=5; h() { echo "h:$n"; }; n+=3 h; n=2*3 h
arr=(a b); h2() { echo "h2:${arr[*]} ${#arr[@]}"; }; arr=x h2; echo "after:${arr[*]}"

# --- export: arrays are never exported
y=1; declare -a y; export y; env | grep -c '^y='

# --- namerefs: assigning an array through an unset nameref; depth limit (8)
declare -n r1; r1=(a b) 2>/dev/null; declare -p r1
realv=deep; prev=realv
for i in 1 2 3 4 5 6 7 8 9; do declare -n d$i=$prev; prev=d$i; done
echo "depth8:[$d8] depth9:[$d9]"

# --- BASH_ALIASES / BASH_CMDS: unsetting an element changes nothing
alias zz='echo z'; unset 'BASH_ALIASES[zz]'; alias zz; echo "${BASH_ALIASES[zz]-gone}"
hash -p /bin/echo myecho; unset 'BASH_CMDS[myecho]'; hash -t myecho

# --- `set` output quotes array elements like declare -p
declare -A A=([$'k\n']=$'v\t' ['a b']="q'q" [x]='$y'); set | grep '^A='
a=([3]='$x' [5]=$'\e' [7]='a"b'); set | grep '^a='

# --- assigning PATH (even the same value, even in a tempenv) flushes the hash table
hash -p /bin/echo foo; PATH=$PATH; e hash -t foo
hash -p /bin/echo foo4; PATH=$PATH true; e hash -t foo4

# --- BASH_COMPAT / BASH_XTRACEFD validation
e eval 'BASH_COMPAT=99'; e eval 'BASH_COMPAT=abc'; unset BASH_COMPAT
e eval 'BASH_XTRACEFD=abc'; e eval 'BASH_XTRACEFD=99'; unset BASH_XTRACEFD

# --- initialization, seen from a child shell
S=${THIS_SH:-bash}
SHLVL=5 $S -c 'echo "shlvl:$SHLVL"'
env BASHOPTS=nullglob $S -c 'echo nomatch*; shopt nullglob'
env 'BASH_FUNC_foo%%=echo x' $S -c 'foo' 2>/dev/null; echo "st=$?"
env -u OLDPWD -u PATH $S -c 'declare -p OLDPWD; echo "$PATH"' 2>&1 | sed 's/^.*line [0-9]*: //'

# --- compound assignment to a noassign array / too-deep nameref is fatal (status 1)
x=$(GROUPS=(1); echo in); echo "groups=[$x] st=$?"
x=$(BASH_SOURCE=(1); echo in); echo "bsrc=[$x] st=$?"
x=$(d9=zz; echo in); echo "deep=[$x] st=$?"
x=$(f(){ FUNCNAME=(1); echo in; }; f; echo out); echo "fn=[$x] st=$?"
