# An if/else as a pipeline stage (or any disqualifying context): the else clause has no
# condition — the compiled tier's lift scan once crashed on it (the program fell back to
# the interpreter, and pure compiled mode died).
if false; then :; else x=1; echo in; fi | cat
n=0
for ((i = 0; i < 150; i++)); do
	r=$(if [ $((i % 2)) = 1 ]; then echo a; else y=2; echo b; fi | cat)
	[ "$r" = b ] && n=$((n + 1))
done
echo "$n ${x-unset} ${y-unset}"
