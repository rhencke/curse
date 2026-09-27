# A <() in an assignment that aborts the line (`a=(<(echo) [x+]=1)`, a readonly binding
# in `x=<(echo) r=<(echo)`) is closed with the line, as bash's top level unlinks its fifo
# list — curse left the pipe ends open for good. And a subscript's syntax error comes
# after what bash evaluated before it: `[x+]` with x=/dev/fd/63 reports x's own error.
fds() { ls /proc/self/fd | grep -v '^[0-3]$' | tr '\n' ' '; echo "."; }
a=(<(echo) [x+]=1); echo "st=$?"; fds
x=<(echo) r=<(echo); echo "x=$x r=$r"; fds
readonly r2=1
x=<(echo) r2=<(echo); echo "st=$?"; fds
r3=(<(echo)); echo "${r3[@]}"; fds
a=([x+]=1)
echo "$((x+))"
a[x+]=1
f() { a=(<(echo) [x+]=1); }; f; echo "f=$?"; fds
eval 'a=(<(echo) [x+]=1)'; fds
y=; b=([y+]=1); echo "b=$?"
for ((i = 0; i < 150; i++)); do
	(x=<(echo) r2=<(echo)); r3=(<(echo)); (a=(<(echo) [x+]=1)); (f)
done 2>&1 | sed 's/line [0-9]*/line N/' | sort | uniq -c
fds
