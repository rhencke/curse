# docs/bash-ub.md: `jobs` with an ambiguous spec in the main shell — bash reads
# jobs[-2] (UB); curse's pinned choice is bash's common case: only "ambiguous job
# spec", status 0. (Checked hot too: 150 calls from a function.)
e=${TMPDIR:-/tmp}/ubjobs.$$
sleep 5 & sleep 6 &
jobs %sleep 2>"$e"; echo "st=$?"
sed 's/^[^:]*: line [0-9]*: //' "$e"
f() { jobs %sleep 2>/dev/null; r="$r$?"; }
r=; for ((i = 0; i < 150; i++)); do f; done; echo "${#r} ${r%%1*}" | cut -c1-8
rm -f "$e"; kill %1 %2 2>/dev/null; wait 2>/dev/null
