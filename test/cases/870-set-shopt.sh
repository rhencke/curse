# $- flags, set -f (noglob), set with no args, shopt -p / -o

# $- reflects the current set options
set -efuC
o=$-
for c in e f u C; do [[ $o == *$c* ]] && echo "has-$c"; done
set +efuC

# set -f disables pathname expansion
set -f
echo *.no_such_glob_zz
set +f

# set with no args lists variables (bash quoting: bare/single/$'')
__P_A=hello
__P_B="a b"
__P_C=
__P_arr=(1 2 "3 4")
set | grep '^__P_'

# shopt -p prints the reusable form
shopt -u nullglob
shopt -p nullglob
shopt -s nullglob
shopt -p nullglob
shopt -u nullglob

# shopt -o lists set-style options
shopt -o | grep -oE '^(errexit|noglob|nounset) '

# shopt -p -o prints set -o/+o form
shopt -p -o | grep -E '^set [-+]o (errexit|nounset)$'

# shopt -q queries quietly via exit status
shopt -s dotglob
shopt -q dotglob && echo "dotglob-on"
shopt -u dotglob
shopt -q dotglob || echo "dotglob-off"
