# exec builtin — bash-5.2.21/builtins/exec.def (exec_builtin, mkdashname, failed_exec).
# Covers: persistent redirections with no command (fd open/close/move/varredir),
# -a/-l/-c and option errors, lookup/exec failures (messages + 126/127), the exec'd
# file's full pathname, exec of a function/builtin name (execs the EXTERNAL), EXIT trap
# on success vs failure, execfail (main shell survives, subshells still exit), posix
# mode special-builtin rules, SHLVL and `_` in the exec'd environment. (Not probed: the
# implicit exec of a subshell's last command lowering SHLVL — curse's subshells never fork.)
norm() { sed -e "s|$PWD|.|g" -e 's/^.*line [0-9]*: //'; }
printf '#!/bin/sh\necho "args=$#"; [ "$0" = "$PWD/s0" ] && echo "0 is full path"\n' > s0
chmod +x s0; echo x > nx; mkdir dd

# -- no command: redirections persist in the current shell
f() { exec 5>f5; }; f; echo infunc >&5; exec 5>&-; cat f5
exec 3>f3; echo hi >&3; exec 3>&-; cat f3
{ echo x >&3; } 2>&1 | norm; echo "closed st=${PIPESTATUS[0]}"
exec 4>&1; exec 5>&4-; echo to5 >&5; { echo to4 >&4; } 2>&1 | norm; exec 5>&-
exec {fd}>ff; echo "fd>=10: $(( fd >= 10 ))"; echo v >&$fd; exec {fd}>&-; cat ff
exec 6<<<"here"; read -r l <&6; echo "l=$l"; exec 6<&-
( exec 3>&1-; echo "stdout closed"; echo via3 >&3 ) 2>/dev/null
( exec 1>&-; echo x ) 2>&1 | norm
{ exec 3<nosuchfile; echo "redir err st=$?"; } 2>&1 | norm
exec; echo "noargs st=$?"; exec --; echo "dashdash st=$?"
X=1 exec; echo "X=${X-unset}"; VAR=0; VAR=1 command exec; echo "VAR=$VAR"

# -- options
( exec -a FOO sh -c 'echo "0=$0"' )
( exec -l sh -c 'echo "0=$0"' )
( exec -la X sh -c 'echo "0=$0"' )
( exec -ab sh -c 'echo "0=$0"' )
( exec -la '' sh -c 'echo "0=[$0]"' )
( exec echo -a x )
( exec -a ZZ ./s0 a b )
( exec -x ) 2>&1 | norm; echo "badopt st=${PIPESTATUS[0]}"
( exec -a ) 2>&1 | norm; echo "noarg st=${PIPESTATUS[0]}"
( A=1 B=2 exec -c env ); echo "st=$?"
( exec -c sh -c 'echo "HOME=${HOME-unset}"' )
( X=5 exec sh -c 'echo X=$X' )

# -- failures: message, status; a subshell always exits
( exec nosuchcmd_q; echo nr ) 2>&1 | norm; echo "st=${PIPESTATUS[0]}"
( exec ./nosuch; echo nr ) 2>&1 | norm; echo "st=${PIPESTATUS[0]}"
( exec ./dd; echo nr ) 2>&1 | norm; echo "st=${PIPESTATUS[0]}"
( exec dd_nothere/; echo nr ) 2>&1 | norm; echo "st=${PIPESTATUS[0]}"
( exec ./nx; echo nr ) 2>&1 | norm; echo "st=${PIPESTATUS[0]}"
( exec ''; echo nr ) 2>&1 | norm; echo "st=${PIPESTATUS[0]}"
( shopt -s execfail; exec nosuchcmd_q; echo "survived" ) 2>/dev/null; echo "execfail sub st=$?"
v=$(exec nosuchcmd_q 2>&1); echo "v=$v st=$?" | norm

# -- exec of a function / builtin name: bash execs the external (or fails)
( echo() { printf 'FUNC\n'; }; exec echo real ); echo "st=$?"
( exec type; echo nr ) 2>&1 | norm; echo "st=${PIPESTATUS[0]}"
( exec cd /; echo nr ) 2>&1 | norm; echo "st=${PIPESTATUS[0]}"
echo a | exec cat; v=$(exec echo inner); echo "v=$v"

# -- EXIT trap: not run when exec succeeds, run when a failed exec exits
( trap 'echo EXITTRAP' EXIT; exec true ); echo "st=$?"
( trap 'echo EXITTRAP' EXIT; exec nosuchcmd_q ) 2>/dev/null; echo "st=$?"
( trap 'echo EXITTRAP' EXIT; shopt -s execfail; exec nosuchcmd_q; echo nr ) 2>/dev/null
v=$(trap 'echo T' EXIT; exec nosuchcmd_q 2>/dev/null); echo "v=$v st=$?"

# -- posix mode: exec is a special builtin
( set -o posix; exec 3<nosuchfile; echo "posix redir survived" ) 2>/dev/null; echo "st=$?"
( set -o posix; command exec 3<nosuchfile; echo "command: survived $?" ) 2>/dev/null
( set -o posix; VAR=0; VAR=1 exec; echo "posix VAR=$VAR" )

# -- environment of the exec'd program: SHLVL (lowered only outside ( )), no `_`
( export SHLVL=5; ( exec env ) | grep ^SHLVL; g() { exec env; }; ( g ) | grep ^SHLVL
  ( exec env | grep ^SHLVL ) )
( exec env ) | grep -c '^_='

# -- main shell: execfail keeps it alive; without it the shell exits (EXIT trap runs)
shopt -s execfail
trap 'echo EXIT-main' EXIT
exec nosuchcmd_q 2>/dev/null; echo "execfail st=$?"
exec ./nx 2>&1 | norm; exec ./nx 2>/dev/null; echo "noexec st=$?"
exec ./dd 2>/dev/null; echo "dir st=$?"
shopt -u execfail
exec -a NAME nosuchcmd_q 2>&1 | norm
exec nosuchcmd_q 2>/dev/null
echo notreached
