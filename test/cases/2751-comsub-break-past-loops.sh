# `break N` / `continue N` for more loops than a command substitution's body has: it ends
# the loops it has, and the substitution. The compiled body compared sh.loopdepth, which a
# shell outside every loop left nil — an escaped `attempt to compare number with nil` from
# the interpreter and the tiered runner (fuzz F58).
echo $(for i in 1; do break 2; done)
echo st=$?
x=$(for i in 1 2; do echo $i; continue 3; done); echo "x=$x $?"
f() { echo $(while :; do break 5; done) f; }; f
eval 'echo $(for i in 1; do break 2; done) e'
trap 'echo $(until false; do break 2; done) t' USR1; kill -USR1 $$
for j in 1 2; do echo $(for i in 1; do break 2; done) j$j; done
i=0; while [ $i -lt 150 ]; do y=$(for k in 1; do echo $k; break 2; done)$y; i=$((i + 1)); done; echo "loop $i ${#y}"
