# EXIT trap runs at the end and sees the shell's final state
cleanup() { echo "cleanup ran, val=$val, status=$?"; }
val="init"
trap cleanup EXIT
trap -p EXIT
val="updated"
true
echo "body done"
