# set -k and set -r compile: a NAME=value word anywhere is an assignment under -k (both
# readings compiled, picked at run time); a restricted shell refuses file redirections,
# `/` in command names, cd, `. path` and exec, and its guarded variables are readonly
exec 2>&1
f() { echo "x=$x args=$*"; }
for i in 1 2; do f x=$i y; done
set -k
for i in 1 2; do f x=$i y; echo a=b c; done
set +k
f x=3
set -r
echo start
PATH=/tmp; echo "st=$?"
echo hi > out.txt; echo "redir st=$?"
cd /; echo "cd st=$?"
/bin/echo slash; echo "slash st=$?"
. ./x.sh; echo "dot st=$?"
for i in 1 2; do y=$i; echo "$y" 2>&1; done
exec /bin/true; echo "exec st=$?"
echo end
