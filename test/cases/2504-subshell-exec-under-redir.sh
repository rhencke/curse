# An `exec` inside a redirected group inside a subshell / $(…): the subshell's fds end
# as they were when it began — not as they were (group-redirected) when exec ran. A
# failed `exec 9>/nonexistent/q` under `2>&1` once left the parent's stderr on the
# finished capture for good.
T=$(mktemp -d) || exit 1; cd "$T" || exit 1
x=$( { exec 9>/nonexistent/q; } 2>&1 ); echo "x=[${x#*: }]"
echo "stderr still works" >&2
ls /nonexistent-2504 2>&1 | sed 's/^ls: //'
( { exec 3>a; echo into-a >&3; } 2>/dev/null ); echo "fd3 open? $( (: >&3) 2>/dev/null && echo y || echo n)"
( { exec 13>b; } 13>c; echo to13 >&13 ); echo "fd13 open? $( (: >&13) 2>/dev/null && echo y || echo n)"
cat a b c 2>/dev/null
for ((i = 0; i < 150; i++)); do
	x=$( { exec 9>/nonexistent/q; } 2>&1 ); y=$( { exec 4>&2; } 2>/dev/null; echo ok >&4 )
done
echo "x=[${x#*: }] y=[$y]"
echo "stderr still works" >&2
cd / && rm -rf "$T"
