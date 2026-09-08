# trap reset semantics
# a lone signal operand (no action) clears that trap
trap 'echo should-not-run' EXIT
trap EXIT
echo "cleared EXIT (nothing at exit expected)"

# trap 0 is EXIT; set then clear via `trap 0`
trap 'echo exit-b' EXIT
trap -p EXIT
trap 0
echo "after trap 0"

# same handler for multiple signals; -p prints each
trap 'echo H' USR1 USR2
trap -p USR1
trap -p USR2

# reset multiple with `trap - sig...`
trap - USR1 USR2
echo "usr traps after reset: [$(trap -p USR1)][$(trap -p USR2)]"

# '' ignores a signal (empty handler)
trap '' INT
trap -p INT

# a real EXIT handler still fires at the very end
trap 'echo FINAL_EXIT' EXIT
echo "body done"
