# set -x traces an assignment with its EXPANDED value, before any attribute acts on it:
# `a[0]=1+1` on an -i array traces `1+1`, a -l element `ABC` (bash's do_assignment_internal
# traces the word, then binds). In a nameref program these take the full assignment path.
exec 2>&1
declare -n r=q
declare -ai a
declare -l low
set -x
a[0]=1+1
a[1]+=3
low[0]=ABC
x=$((2*3))
set +x
echo "${a[@]} $low $x"
