# bash counts a `for`/`select` loop before it expands the word list (execute_for_command's
# loop_level++): a break/continue in a command substitution there is inside a loop, so its
# arguments are checked — `break: too many arguments` — instead of "only meaningful in a
# `for', `while', or `until' loop" (fuzz F79: the interpreter; the compiled tier inside a
# function).
for i in `break -1 b`; do :; done
echo st=$?
for i in `continue 1 2`; do :; done
select s in `break x y`; do break; done <<< 1
for i in $(break 2 3) a; do echo $i; done
f() { for i in `break -1 b`; do :; done; echo "f $?"; }; f
eval 'for i in `break a b`; do :; done'; echo "eval $?"
while [ ${n:=0} -lt 150 ]; do n=$((n+1)); for i in `continue a b` x; do :; done; done 2>&1 | sort | uniq -c
g() { for i in ${u:-`break a b`} x; do :; done; select s in ${u:-`break c d`}; do break; done <<< 1; echo "g $?"; }; g
h() { for i in $(for j in 1; do break 2; done) y; do echo $i; done; }; h
