# Pinned bash behaviour: `set -n` (noexec) in a non-interactive shell stops ALL execution
# from the next command on — the rest of the function, loop, eval text or subshell it ran
# in too — while the shell keeps reading its input: a later syntax error is still reported.
trap 'echo EXIT-trap' EXIT
( set -n; echo "sub not reached" ); echo "subshell $?"
x=$(set -o noexec; echo "comsub not reached"); echo "comsub [$x] $?"
g() { set -n; echo "g not reached"; }
( g; echo "after g not reached" ); echo "g-sub $?"
eval 'set -n; echo "eval not reached"' | cat; echo "pipe ${PIPESTATUS[*]}"
# a sourced file / eval text is still read to its end (a here-document at its end warns)
s=${TMPDIR:-/tmp}/c3384.$$
printf 'set -n\necho "src not reached"\ncat <<E\nx\n' >"$s"
( h() { . "$s"; echo "h not reached"; }; h; echo "not reached" ) 2>&1 | sed 's/^[^:]*: //'
( k() { eval $'set -n\necho no\ncat <<E\ny'; echo "k not reached"; }; k ) 2>&1 | sed 's/^[^:]*: //'
rm -f "$s"
f() {
	n=$((n + 1))
	if ((n == 160)); then
		echo "at $n"
		eval 'set -n'
		echo "f not reached"
	fi
}
n=0
for ((i = 0; i < 300; i++)); do f; done
echo "loop not reached"
if then fi
echo "never"
