# docs/bash-ub.md: printf text past INT_MAX bytes. glibc's printf family counts in an int:
# a `*` precision of exactly INT_MAX makes bash's stdout printf emit INT_MAX spaces before
# the number (4 GiB), and printf -v (vsnprintf's -1, EOVERFLOW, used as a length by bash's
# vbprintf) keeps whatever the buffer held — 15 spaces, "acd" for 'ab%.*fcd'; a `*` width
# that big overflows vbadd's int size and xrealloc fails, fatal (status 2). curse's pinned
# choice: stdout gets the exact text, streamed; printf -v with a text past INT_MAX is
# "xrealloc: cannot allocate N bytes" (the true size), fatal, status 2. (Output only to
# /dev/null: dd counts it.)
n() { dd of=/dev/null bs=1M 2>&1 | tail -1 | cut -d' ' -f1; }
printf '%.*f' 2147483647 1 | n
( printf -v y '%.*f' 2147483646 1; echo not reached ) 2>&1 | sed 's/^[^:]*: //'
echo "st ${PIPESTATUS[0]}"
( printf -v x '%*s' 2147483647 a; echo not reached ) 2>&1 | sed 's/^[^:]*: //'
echo "st ${PIPESTATUS[0]}"
f() { printf -v z 'ab%.*fcd' "$1" 1; }; ( f 2147483646 ) 2>&1 | sed 's/^[^:]*: //'
printf -v w '%.*f' 1048600 1; echo "${#w}"
