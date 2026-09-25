# Trap handlers that run repeatedly (the tier compiles a recurring handler): $LINENO and
# error-prefix lines stay the interrupted command's, return/ERR/line-abort semantics hold.
trap 'echo usr1 $x; x=$((x+1))' USR1
x=0
for i in 1 2 3 4; do kill -USR1 $$; done
f() { trap 'return 7' USR2; kill -USR2 $$; echo notreached; }
for i in 1 2 3; do f; echo "f=$?"; done
trap 'echo err $? $LINENO; false' ERR
for i in 1 2 3; do false; done
trap - ERR
trap 'echo $((1/0)); echo same; ' USR1
echo next
for i in 1 2 3; do kill -USR1 $$; echo after $i; done
trap 'echo bye $x' EXIT
for i in 1 2 3; do (exit 3); done
g() { trap 'echo ret in $FUNCNAME' RETURN; :; }
g; g
trap 'echo "in trap $LINENO $((LINENO+0))"; echo ${x:?unset here}' USR1
unset x
kill -USR1 $$
kill -USR1 $$
trap 'echo e $LINENO; : ${nope:?gone}' ERR
false
false
trap - ERR USR1
trap 'false; echo $LINENO err' ERR
trap 'false; echo $LINENO debug' DEBUG
for i in 1 2 3; do false; done
trap - DEBUG ERR
