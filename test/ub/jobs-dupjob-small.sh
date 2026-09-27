# docs/bash-ub.md: `jobs` with an ambiguous spec in a SMALL script. Here bash 5.2.21's
# jobs[-2] read happens to find 0 — "no such job", status 1 — at top level, in a function
# and in a loop; in scripts with more heap history (test/ub/jobs-dupjob.sh, test/cases/1820)
# it gives status 0. curse's pinned choice is status 0 with only "ambiguous job spec",
# in every context (hot too: 150 loop iterations).
sleep 5 & sleep 6 &
jobs %sleep 2>&1 | sed 's/^[^:]*: line [0-9]*: //'
jobs %sleep 2>/dev/null; echo "top=$?"
f() { jobs %sleep 2>/dev/null; echo "fn=$?"; }; f
r=; for ((i = 0; i < 150; i++)); do jobs %sleep 2>/dev/null; r="$r$?"; done; echo "loop ${#r} ${r//0/}."
kill %1 %2 2>/dev/null; wait 2>/dev/null
