# `set +B` at run time: brace-expanded words and for-in lists run their compiled
# unbraced form (the raw words), `set -B` the expanded one — no interpreter.
echo a{1,2}b x{y,z}
set +B
echo a{1,2}b x{y,z}
for i in {1..3} q{r,s}; do echo -n "$i "; done; echo
f() { local v=w; echo $v{1,2} {a,b}$v; }
f
set -B
f
for i in {1..3} q{r,s}; do echo -n "$i "; done; echo
