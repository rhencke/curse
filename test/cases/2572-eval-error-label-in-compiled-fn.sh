# The error label of an interpreted command run in a function is the file the function
# was defined in (bash's error_prolog: BASH_SOURCE[0]) — "environment" for one defined
# by -c text, "main" for a script read from stdin — also when the function itself is
# compiled (a program run again starts compiled) and the command (eval text: interpreted
# on first sight) is not.
S=${THIS_SH:-bash}
p='f() { eval "local \"b$1[]\"=3"; }; for ((i = 0; i < 200; i++)); do f $i; done'
for r in 1 2 3; do
	$S -c "$p" 2>&1 | sed 's/b[0-9]*\[\]/b[]/' | sort | uniq -c | sed 's/^ *//'
done
for r in 1 2 3; do
	$S -c 'f() { eval "local \"b[]\"=3"; }; f' 2>&1
done
p='f() { eval "echo \${BASH_SOURCE[0]}:$1 >/dev/null; local \"b$1[]\"=3"; }
g() { f "$@"; }
for ((i = 0; i < 200; i++)); do g $i; done'
for r in 1 2 3; do
	$S -c "$p" 2>&1 | sed 's/b[0-9]*\[\]/b[]/' | sort | uniq -c | sed 's/^ *//'
done
for r in 1 2 3; do
	printf '%s\n' 'f() { eval "local \"b$1[]\"=3"; }' 'for ((i = 0; i < 200; i++)); do f $i; done' | $S 2>&1 |
		sed 's/b[0-9]*\[\]/b[]/' | sort | uniq -c | sed 's/^ *//'
done
