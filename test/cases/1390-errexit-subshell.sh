# errexit is suppressed inside a subshell that forms an if/while condition (and
# re-enabling it there is moot), but a subshell in an ordinary context still
# honors errexit.

set -o errexit

# The subshell is the `if` condition: failures inside don't exit it, and its
# status is the last command's (echo 4 -> success), so the then-branch runs.
if ( echo 1; false; echo 2; set -o errexit; echo 3; false; echo 4 ); then
  echo 5
fi
echo 6

# The left operand of || is also a suppressed context, so this subshell runs to
# the end (echo b) and returns 0, and the || branch does not fire.
( echo a; false; echo b ) || echo "sub-failed=$?"
echo 7
