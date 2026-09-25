# compiled calls count $FUNCNEST, compiled commands record $BASH_COMMAND, and a builtin
# disabled by `enable -n` runs from $PATH instead (compiled builtin calls check)
exec 2>&1
FUNCNEST=20
d() { (( n++ )); if (( n > 50 )); then return 7; fi; d; }
n=0; d; echo "d=$? n=$n" | sed 's/^.*line [0-9]*: //'
unset FUNCNEST
n=0; d; echo "d=$? n=$n"
trap 'echo "err: $BASH_COMMAND"' ERR
false
x=1; [[ $x == 2 ]]
trap - ERR
echo "cmd: $BASH_COMMAND"
enable -n echo
for i in 1 2; do echo -e "a\tb $i"; type -t echo; done
enable echo
type -t echo
enable -n test
if test 1 -eq 1; then echo still; fi
enable test
