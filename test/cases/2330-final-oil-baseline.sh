# The last oil-baseline differences, and the invocation-time leftovers:
#  - a heredoc opened by an ALIAS whose value holds the newline: bash reads the body from
#    the INPUT (read_secondary_line -> yy_getc), not the alias text, whose remainder then
#    runs as commands (oil alias#40)
#  - $PPID is the shell's parent, $RANDOM a seeded stream (oil vars-special#16/#18 differ
#    run to run in bash itself: the harness now masks an oracle that varies)
#  - the live arrays read as scalars ($GROUPS, $BASH_ARGV, $BASH_ARGC, $DIRSTACK)
#  - --debugger / -O extdebug (start_debugger: no bashdb -> warn, extdebug and -E/-T off)
#  - run_startup_files' sshd rule: `-c` with $SSH_CLIENT set, top level -> ~/.bashrc
shopt -s expand_aliases

# --- alias-borne heredocs read their bodies from the input
alias c='cat <<EOF
$(echo hi)
EOF
'
eval 'c' 2>/dev/null
echo "a $?"
{ eval 'c
body0
EOF'; } 2>/dev/null
echo "a2 $?"
alias d='cat <<EOF; echo mid
echo aftr
'
d
body2
more
EOF
echo "b $?"
alias f='cat <<A <<B
echo tail'
f
a1
A
b1
B
alias e='cat <<EOF'
e
body3
EOF
eval 'd
evbody
EOF'
echo "$(d
csbody
EOF
)"
unalias c d e f

# --- $PPID / $RANDOM
S=${THIS_SH:-bash}
[ "$($S -c 'echo $PPID')" = "$$" ] && echo "ppid ok"
pp=$PPID
(echo "sub $(( PPID == pp ))")
echo $PPID | { read -r x; echo "pipe $(( x == pp ))"; }
RANDOM=42; echo "rand $RANDOM $RANDOM $RANDOM"
case $RANDOM in [0-9]*) echo "rand ok" ;; esac

# --- live arrays as scalars
g() { echo "g [$BASH_ARGV][$BASH_ARGC][${GROUPS:+set}][$FUNCNAME]"; }
g 1 2
[ "$GROUPS" = "$(id -g)" ] && echo "groups ok"
[ "$DIRSTACK" = "$PWD" ] && echo "dirstack ok"
set -- p q
shopt -s extdebug
g 3 4
echo "t [$BASH_ARGV][$BASH_ARGC]"
shopt -u extdebug

# --- --debugger and -O extdebug (no debugger start file here)
$S --debugger -E -c 'echo "$-"; shopt extdebug; echo "${BASH_ARGC[@]}|${BASH_ARGV[@]}"' zero x y 2>&1
$S -O extdebug -c 'f() { echo "${BASH_ARGC[@]}"; }; f 1 2' zero 2>&1

# --- sshd rule: a top-level non-interactive -c shell with $SSH_CLIENT reads ~/.bashrc
H=$(mktemp -d)
echo 'echo rc-read' > "$H/.bashrc"
env -u SHLVL HOME="$H" SSH_CLIENT='1 2 3' $S -c 'echo ssh1' </dev/null
env -u SHLVL HOME="$H" SSH2_CLIENT= $S -c 'echo ssh2' </dev/null
env SHLVL=1 HOME="$H" SSH_CLIENT=x $S -c 'echo ssh-nested' </dev/null
env -u SHLVL HOME="$H" SSH_CLIENT=x $S --norc -c 'echo ssh-norc' </dev/null
env -u SHLVL -u SSH_CLIENT -u SSH2_CLIENT HOME="$H" $S -c 'echo no-ssh' </dev/null
env -u SHLVL HOME="$H" SSH_CLIENT=x $S --rcfile /dev/null -c 'echo ssh-rcfile' </dev/null
rm -rf "$H"
