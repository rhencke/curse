# A trap handler the compiler never saw — its text built at run time and set through
# `eval "$s"` or a sourced file — reads and assigns variables the running loop keeps
# (in curse's compiled tier: in native registers). Every handler sees, and updates, the
# live values. (The variable names never appear as literal words: they come from octal.)
nm() { printf "\\$(printf %o "$1")"; }
N=$(nm 110) K=$(nm 107) U=$(nm 117) E=$(nm 101)
# 1. a signal trap set by eval, run()-level counter
s="trap 'echo usr1 \$$N; $N=1000' USR1"
n=0
for ((i = 0; i < 300; i++)); do
	n=$((n + 1))
	if ((i == 5)); then eval "$s"; fi
	if ((i == 150)); then kill -USR1 $$; fi
done
echo "1: n=$n"
trap - USR1
# 2. a DEBUG trap set by eval inside a function, on the function's local counter
g() {
	local k=0 j
	eval "trap '(( $K == 160 )) && { echo dbg \$$K; $K=500; }' DEBUG"
	for ((j = 0; j < 200; j++)); do k=$((k + 1)); done
	trap - DEBUG
	echo "2: k=$k"
}
g
# 3. an ERR trap from a sourced file, run()-level counter
f=${TMPDIR:-/tmp}/b1t.$$
printf '%s\n' "trap 'echo err \$$E; $E=\$(( $E + 100 ))' ERR" >"$f"
e=0
for ((i = 0; i < 200; i++)); do
	e=$((e + 1))
	if ((i == 3)); then . "$f"; fi
	if ((i == 150)); then false; fi
done
trap - ERR
rm -f "$f"
echo "3: e=$e"
# 4. a signal trap set by eval, a counter a function also updates
h() { u=$((u + 1)); }
u=0
for ((i = 0; i < 300; i++)); do
	h
	if ((i == 2)); then eval "trap 'echo usr2 \$$U; $U=\$(( $U * 2 ))' USR2"; fi
	if ((i == 199)); then kill -USR2 $$; fi
done
echo "4: u=$u"
