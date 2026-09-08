# subshell exit status
( exit 3 )
echo "subshell exit: $?"

# shift
show() { echo "$# args: $1 $2 $3"; shift; echo "after shift: $# args: $1 $2"; shift 2; echo "left: $#"; }
show a b c d

# exit inside a command substitution ends only the subshell
result=$( exit 7; echo unreached )
echo "cmdsub after exit: [$result]"

# background + wait (deterministic via wait)
{ echo "bg ran"; } &
wait
echo "after wait"

# $! is set after backgrounding
sleep 0 &
if [ -n "$!" ]; then echo "have bg pid"; fi
wait

# exit ends the script
echo "before exit"
exit 0
echo "should not print"
