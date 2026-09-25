# execute_cmd.c audit: execute_disk_command errors (directory, binary file, ENOEXEC
# scripts' BASH_SUBSHELL/SHLVL), command_not_found_handle's environment, hash -r
# forgetting a deleted command, PIPESTATUS after a null command, BASH_COMMAND in an
# ERR trap after a subshell/cmdsub, $_ after eval/source, BASH_ARGV/ARGC frames being
# snapshots (set --/shift don't touch them), TIMEFORMAT errors, `time --`.
norm() { sed 's/^.*line [0-9]*: //'; }

# --- execute_disk_command diagnostics / statuses
mkdir d; ./d 2>&1 | norm; echo "dir st=${PIPESTATUS[0]}"
printf 'ab\0cd\n' > bin; chmod +x bin; ./bin 2>&1 | norm; echo "bin st=${PIPESTATUS[0]}"
: > empty; chmod +x empty; ./empty; echo "empty st=$?"
echo 'echo hi' > nx; ./nx 2>&1 | norm; echo "noexec-perm st=${PIPESTATUS[0]}"
printf '#!/nonexist/interp\necho x\n' > bi; chmod +x bi; ./bi 2>&1 | norm; echo "badinterp st=${PIPESTATUS[0]}"
printf 'echo "noshebang $# [$1] v=[$v] e=[$e]"; exit 3\n' > ns; chmod +x ns
v=plain; export e=exported; ./ns a "b c"; echo "ns st=$?"
# a no-shebang script is a fresh shell: BASH_SUBSHELL unchanged, SHLVL+1 (an exec'd
# last command in a subshell first gives the level back)
printf 'echo "sub=$BASH_SUBSHELL lvl=$SHLVL"\n' > lv; chmod +x lv
SHLVL=5; ./lv; (./lv); x=$(./lv); echo "$x"
# ... and afterwards our own diagnostics still carry our line numbers
( : ${unset_var?gone} ) 2>ef; sed 's/^.*: line/line/' ef

# --- command_not_found_handle runs in the forked child: no BASH_SUBSHELL bump
command_not_found_handle() { echo "cnf:$1 [$#] sub=$BASH_SUBSHELL"; return 7; }
nosuch a b; echo "st=$?"
( nosuch ); nosuch | cat; x=$(nosuch q); echo "$x"
unset -f command_not_found_handle

# --- hash -r forgets a command whose file was removed
mkdir pbin; printf '#!/bin/sh\necho disk\n' > pbin/mytool; chmod +x pbin/mytool
OPATH=$PATH; PATH=$PWD/pbin:$PATH
mytool; rm pbin/mytool
hash -r; mytool 2>&1 | norm; echo "st=${PIPESTATUS[0]}"
hash 2>&1 | norm
PATH=$OPATH

# --- PIPESTATUS after an assignment-only / redirection-only command
false; x=1; echo "ps=${PIPESTATUS[*]}"
x=$(false | true); echo "ps=${PIPESTATUS[*]}"
x=$(exit 4) y=$(exit 5); echo "ps=${PIPESTATUS[*]} st=$?"
false; $(exit 6); echo "ps=${PIPESTATUS[*]} st=$?"
false; >/dev/null; echo "ps=${PIPESTATUS[*]}"

# --- BASH_COMMAND seen by an ERR trap is the outer command
trap 'echo "ERR[$?]: $BASH_COMMAND"' ERR
( false )
( exit 2 )
x=$(false)
y=$(echo hi; exit 3)
f() { return 1; }; f
trap - ERR

# --- $_ after eval / source is their own last argument
eval ': evl'; echo "_=$_"
eval ': a b'; echo "_=$_"
eval 'x=1'; echo "_=$_"
eval; echo "_=$_"
echo ': src' > s.sh; . ./s.sh; echo "_=$_"
source ./s.sh arg; echo "_=$_"
for i in 1 2; do eval ': loop'; echo "_$i=$_"; done

# --- extdebug: BASH_ARGV/BASH_ARGC are pushed per frame, not live views of "$@"
shopt -s extdebug
g() { set -- a b c; echo "argv=[${BASH_ARGV[*]}] argc=[${BASH_ARGC[*]}]"; shift; echo "argv=[${BASH_ARGV[*]}] argc=[${BASH_ARGC[*]}]"; }
g 1 2
set -- p q; echo "argv=[${BASH_ARGV[*]}] argc=[${BASH_ARGC[*]}]"
shift; echo "argv=[${BASH_ARGV[*]}] argc=[${BASH_ARGC[*]}]"
shopt -u extdebug; set --

# --- time: TIMEFORMAT validation, `time --` is the POSIX format
TIMEFORMAT='a%Zb'; { time :; } 2>&1 | norm
TIMEFORMAT='a%'; { time :; } 2>&1 | od -c | sed -n 1p
TIMEFORMAT='%%x%3Ry|%lU|%0S'; { time :; } 2>&1 | sed 's/[0-9]/N/g'
unset TIMEFORMAT
{ time -- true; } 2>&1 | sed 's/[0-9]/N/g'
{ time -p -- true; } 2>&1 | sed 's/[0-9]/N/g'

