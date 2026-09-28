# A subshell writing into a process substitution whose reader has gone dies of SIGPIPE
# (status 141) and ALONE: the script goes on. curse (in-process subshell) let the SIGPIPE
# end the whole script with status 141 when the subshell's stdout was redirected to the
# procsub, and lost the subshell's status line when it wrote to an fd held open on one
# (stress-attack S5).
( for ((i = 0; i < 20000; i++)); do echo yyyyyyyy; done > >(head -c 10 > /dev/null) ) 2> /dev/null
echo "redirected subshell: $?"
echo "the script goes on"
exec 3> >(head -c 1 > /dev/null)
sleep 0.2
( for ((i = 0; i < 20000; i++)); do echo yyyyyyyy; done >&3 ) 2> /dev/null
echo "subshell into a dead procsub fd: $?"
{ for ((i = 0; i < 20000; i++)); do echo yyyyyyyy; done >&3; } 2> /dev/null
echo "group into it: $?"
exec 3>&-
echo end
