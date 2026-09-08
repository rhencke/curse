# EXIT trap fires on explicit exit and sees the exit status ($? = 4)
trap 'echo "exiting with $?"' EXIT
echo start
false
exit 4
echo "never reached"
