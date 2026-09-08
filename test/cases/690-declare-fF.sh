# declare -F lists function names; declare -f reports existence
alpha() { echo a; }
gamma() { echo g; }
beta() { echo b; }

# -F with no args lists all function names, sorted
declare -F

# -F name tests whether each is a function
declare -F beta
echo "beta rc=$?"
declare -F nofunc
echo "nofunc rc=$?"

# -f exit status: 0 if the function exists, 1 otherwise
declare -f alpha >/dev/null
echo "alpha exists: $?"
declare -f missing >/dev/null
echo "missing: $?"

# typeset is the same builtin
typeset -F gamma
echo "typeset gamma rc=$?"
