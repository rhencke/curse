# docs/bash-ub.md: `jobs` with an ambiguous spec — bash reads jobs[-2] (UB). Run by hand,
# bash 5.2.21 gives status 0 for this very script; curse's pinned choice is
# "ambiguous job spec" AND "%spec: no such job", status 1, in the main shell and (hot:
# 150 calls) from a function.
e=${TMPDIR:-/tmp}/ubjobs.$$
sleep 5 & sleep 6 &
jobs %sleep 2>"$e"; echo "st=$?"
sed 's/^[^:]*: line [0-9]*: //' "$e"
f() { jobs %sleep 2>/dev/null; r="$r$?"; }
r=; for ((i = 0; i < 150; i++)); do f; done; echo "${#r} ${r//1/}."
rm -f "$e"; kill %1 %2 2>/dev/null; wait 2>/dev/null
