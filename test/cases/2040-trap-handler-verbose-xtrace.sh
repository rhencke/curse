# A recurring trap handler under set -x keeps tracing each run (++ lines), and set -v
# echoes the handler's text each time it is read (bash's parse_and_execute).
t=${TMPDIR:-/tmp}/curse-2040.$$
trap 'echo usr $i' USR1
set -x
for i in 1 2 3; do kill -USR1 $$; done 2>"$t"
set +x
sed 's/USR1 [0-9]*/USR1 PID/' "$t"
set -v
for i in 1 2 3; do kill -USR1 $$; done 2>&1
set +v
rm -f "$t"
