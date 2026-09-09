# Loop control edge cases: an implicit `for` over "$@", break/continue appearing
# in a loop condition, and break/continue argument handling.

# `for x; do` with no `in` iterates the positional parameters, like `in "$@"`.
fun() { for i; do echo "$i"; done; echo "fin=$i"; }
fun 1 2 3
# An explicit empty list iterates nothing.
for x in; do echo nope; done; echo empty-ok

# `break` / `continue` in the condition act on that loop, not an enclosing one.
while break; do echo x; done; echo done1
for i in 1 2 3; do echo "i=$i"; while break; do echo x; done; done; echo done2

# A non-numeric count is a fatal error (status 128) that aborts the shell, so
# run it in a subshell to keep going and observe the status.
( for i in 1 2; do for j in a b; do echo "$i$j"; break oops; done; echo "outer=$i"; done ) 2>/dev/null
echo "badbreak=$?"
( for i in 1 2 3; do echo "c$i"; continue foo; done ) 2>/dev/null
echo "badcont=$?"

# A numeric count breaks out of that many levels.
for i in 1 2; do for j in a b; do echo "n$i$j"; break 2; done; echo "unreached=$i"; done
echo end
