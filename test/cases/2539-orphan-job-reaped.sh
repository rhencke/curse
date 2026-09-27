# A job started inside a pipeline stage or ( … ) is not the parent shell's: when that
# subshell ends, the job's process is an orphan (bash's exited child's children go to
# init, which reaps them). curse runs those subshells in-process, so it must reap such a
# process itself once it ends — never leave a zombie (they piled up on daemon workers).
zombies() { ps -o stat= --ppid $$ | grep -c '^Z'; }
{ /bin/true & } | cat
( /bin/true & )
x=$(/bin/true & echo)
/bin/sleep 0.2
wait
echo "zombies: $(zombies)"
for ((i = 0; i < 150; i++)); do
	{ /bin/true & } | cat
done
/bin/sleep 0.3
wait
echo "zombies after 150: $(zombies)"
