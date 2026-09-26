# A prefix assignment is part of its command: it leaves $?, $_ and PIPESTATUS as they
# were for the command to see (a command substitution in the value sets $?).
f() { echo "in: $? [$_] ${PIPESTATUS[*]}"; }
false; x=1 f
x=$(exit 3) f
echo a b; x=1 f
false | true; x=1 f
(exit 4); x=$(exit 5) y=2 f
