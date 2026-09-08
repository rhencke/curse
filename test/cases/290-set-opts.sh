# set -- : positional parameters
set -- alpha beta gamma
echo "$# args: $1 $2 $3"
for a in "$@"; do echo "arg: $a"; done

# set -o pipefail
set -o pipefail
false | true
echo "pipefail status: $?"
set +o pipefail
false | true
echo "no pipefail status: $?"

# set -u : unset var is an error (subshell so the script continues)
result=$( set -u; echo "before"; echo "$undefined_variable"; echo "after" )
echo "nounset stdout: [$result]"

# set -u allows defaults
set -u
echo "default ok: ${maybe:-fallback}"
set +u

# set -e in a subshell: stops at first failure
out=$( set -e; echo one; false; echo two )
echo "errexit stdout: [$out]"

# set -e not triggered inside a condition
set -e
if false; then echo no; fi
echo "condition ok"
false || echo "or ok"
set +e
