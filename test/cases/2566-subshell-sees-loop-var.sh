# Pinned bash behaviour: a ( … ) subshell sees the shell's variables as they are when it
# starts — a for (( )) counter too, on every pass (the compiled tier kept the counter in a
# native local and the subshell read a stale copy: `0 0 0`).
for ((i = 0; i < 3; i++)); do (echo "$i"); done
g() { echo "$1"; }
n=0
for ((i = 0; i < 200; i++)); do
	(g "$((i % 2))")
	x=$((i * 2)); (echo "$x $n") ; n=$((n + 1))
done | sort | uniq -c | sort -k2 | head -5
while ((n > 197)); do (echo "w$n"); n=$((n - 1)); done
