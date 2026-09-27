# A trap a $(…) inherits — DEBUG (and RETURN) under `set -T`, ERR under `set -E` — runs
# inside the command substitution's subshell: its handler's changes are the subshell's
# and never reach the parent, however simple the body (curse runs a pure body without
# full isolation — not when such a trap can run in it). Also in a hot loop (compiled).
set -T
n=0
trap 'n=$((n+1))' DEBUG
z=$(echo c)
trap - DEBUG
echo "debug n=$n"
n=0
trap 'n=$((n+1))' DEBUG
for ((i = 0; i < 150; i++)); do x=$(echo "$i"); done
trap - DEBUG
echo "hot debug n=$n x=$x"
set +T
set -E
e=0
trap 'e=$((e+1))' ERR
x=$(false)
y=$(echo ok; false)
trap - ERR
echo "err e=$e"
