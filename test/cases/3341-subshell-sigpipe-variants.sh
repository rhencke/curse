# A subshell that dies of SIGPIPE dies ALONE, whatever runs the writes: a function, eval,
# its own trap (runs; the writes fail), its own ignore (a write error), the parent's trap
# (not the subshell's: it dies), a $(…); and a SIGPIPE the subshell sends the parent
# (`kill -PIPE $$`) is the parent's. Over and over (hot loop). curse ran these in-process
# and the SIGPIPE ended the whole script (stress-attack S5).
w() { for ((i = 0; i < 20000; i++)); do echo yyyyyyyy; done; }
( w > >(head -c 10 > /dev/null) ) 2> /dev/null; echo "function: $?"
( eval 'for ((i = 0; i < 20000; i++)); do echo yyyyyyyy; done' > >(head -c 10 > /dev/null) ) 2> /dev/null
echo "eval: $?"
( trap 'n=$((n + 1))' PIPE; n=0; w > >(head -c 10 > /dev/null); echo "own trap ran: $((n > 0))" ) 2> /dev/null
echo "own trap: $?"
( trap '' PIPE; w > >(head -c 10 > /dev/null) ) 2>&1 | sed -E 's/line [0-9]+/line N/' | sort -u
echo "own ignore: ${PIPESTATUS[0]}"
x=$(w > >(head -c 10 > /dev/null); echo in); echo "comsub: $? [$x]"
trap 'echo parent-trap' PIPE
( w > >(head -c 10 > /dev/null) ) 2> /dev/null; echo "parent trapped: $?"
( kill -PIPE $$; echo sent ); echo "sent to the parent: $?"
trap - PIPE
n=0
for ((k = 0; k < 20; k++)); do
	( w > >(head -c 1 > /dev/null) ) 2> /dev/null
	[ $? = 141 ] && n=$((n + 1))
done
echo "hot loop: $n of 20"
echo end
