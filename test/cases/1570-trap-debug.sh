# The DEBUG trap runs before each simple command, with $LINENO set to that
# command's line, and its own exit status is discarded ($? is preserved). It is
# not re-entered by its own handler and is not inherited by functions.
debuglog() { echo "  [$1]"; return 42; }  # the return 42 must be ignored
trap 'debuglog $LINENO' DEBUG

echo A
echo "status=$?"
x=5
echo "x=$x status=$?"
echo B && echo C
(( y = 1 + 2 ))
[[ foo == foo ]] && echo matched

# not inherited by a function: the DEBUG fires once (before the call), not for
# the commands inside f.
f() { echo in-f; echo in-f-2; }
f

echo done
