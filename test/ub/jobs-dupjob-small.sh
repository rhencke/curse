# docs/bash-ub.md: `jobs` with an ambiguous spec in a SMALL script: here bash 5.2.21's
# jobs[-2] read finds 0 — "no such job", status 1 — at top level, in a function and in a
# loop, which is curse's pinned choice in every context (hot too: 150 loop iterations).
sleep 5 & sleep 6 &
jobs %sleep 2>&1 | sed 's/^[^:]*: line [0-9]*: //'
jobs %sleep 2>/dev/null; echo "top=$?"
f() { jobs %sleep 2>/dev/null; echo "fn=$?"; }; f
r=; for ((i = 0; i < 150; i++)); do jobs %sleep 2>/dev/null; r="$r$?"; done; echo "loop ${#r} ${r//1/}."
kill %1 %2 2>/dev/null; wait 2>/dev/null
