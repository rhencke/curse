# A pure (command-less) assignment that ends non-zero — a readonly target, or a
# failed command substitution in the RHS — fires errexit and the ERR trap like
# any other command. Subshells isolate the exit so the rest of the test runs.

# readonly assignment under errexit aborts (the echo is not reached)
( set -e; readonly r=1; r=2; echo "NOT REACHED" ) 2>/dev/null
echo "ro-errexit=$?"

# failed RHS command sub under errexit aborts
( set -e; x=$(false); echo "NOT REACHED" )
echo "sub-errexit=$?"

# without errexit, a failed assignment just carries the status and continues
readonly q=1
q=2 2>/dev/null
echo "no-errexit continues rc=$?"

# a failed command sub sets $? but (no errexit) execution continues
y=$(false)
echo "sub rc=$?"

# ERR trap fires on a failing assignment
trap 'echo ERR-TRAP' ERR
z=$(false)
echo end
