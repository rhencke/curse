# RETURN traps fire from compiled function calls: one a function sets fires as it
# returns (in its frame), a top-level one only under functrace, and the handler sees the
# $? from before `return N` (N is the call's status once it has run)
g() { trap 'echo "ret in $FUNCNAME st=$?"' RETURN; false; return 4; }
g; echo "g=$?"
trap - RETURN
trap 'echo top-ret' RETURN
h() { echo in h; }
h; echo "h=$?"
set -T
k() { false; return 5; }
for i in 1 2; do k; echo "k=$?"; done
set +T
trap - RETURN
m() { eval "trap 'echo eval-ret \$?' RETURN"; return 3; }
m; echo "m=$?"
trap - RETURN
n() { :; }
n; echo "n=$?"
