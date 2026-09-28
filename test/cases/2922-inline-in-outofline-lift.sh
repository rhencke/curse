# A function that calls another function twice, where the callee updates an arithmetic-only
# global: bash counts every call. curse's compiled code (the callee inlined into the
# out-of-line caller, the var lifted to a run-local native integer the caller never saw)
# lost updates — tiered printed 198 for 400, compiled 0 (stress-attack S12). Each program
# runs as its own script: eval/source/a trap anywhere in one disables that inlining.
S=${THIS_SH:-bash}
t() { printf '%s\n' "$1" > s2922.sh; "$S" s2922.sh; }
t 'f2() { x=$((x + 1)); }
f1() { f2; f2; }
x=0
for ((r = 0; r < 200; r++)); do f1; done
echo "two levels: $x"'
t 'g3() { y=$((y + 1)); }
g2() { g3; g3; }
g1() { g2; g2; }
y=0
for ((r = 0; r < 200; r++)); do if ((r < 0)); then g1; fi; g2; done
echo "dead call + two levels: $y"'
t 'h2() { ((z++)); }
h1() { h2; h2; h2; }
z=0
for ((r = 0; r < 300; r++)); do h1; done
echo "three calls: $z"'
t 'k2() { w=$((w + 2)); }
k1() { if :; then k2; fi; for q in 1; do k2; done; }
w=0; i=0; while [ $i -lt 150 ]; do k1; i=$((i + 1)); done; echo "nested: $w"'
eval 'e2() { v=$((v + 1)); }; e1() { e2; e2; }'; v=0; for ((r = 0; r < 150; r++)); do e1; done; echo "eval: $v"
printf 'f2() { x=$((x + 1)); }; f1() { f2; f2; }; x=0; for ((r = 0; r < 150; r++)); do f1; done; echo "source: $x"\n' > s2922.sh; . ./s2922.sh
trap 'f1' USR1; x=0; kill -USR1 $$; trap - USR1; echo "trap: $x"
rm -f s2922.sh
