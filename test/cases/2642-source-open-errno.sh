# `source FILE` that can't open FILE reports the real errno (bash's _evalfile:
# file_error(filename) — the name and strerror(errno)), not always "No such file or
# directory": a mode-000 file is "Permission denied". Likewise `$(< FILE)` (subst.c).
# Status 1 either way.
d=${TMPDIR:-/tmp}/se$$; rm -rf "$d"; mkdir -p "$d"; cd "$d"
echo 'echo sourced' >np; chmod 000 np
if [ -r np ]; then # (root reads it anyway: nothing to test)
	echo "skip"; cd /; rm -rf "$d"; exit 0
fi
f() { source ./np; echo "fn st=$?"; }
{
	source ./np; echo "source st=$?"
	. ./np; echo "dot st=$?"
	source ./missing; echo "missing st=$?"
	x=$(< ./np); echo "cap st=$? x=[$x]"
	eval 'source ./np'; echo "eval st=$?"
	f
	trap 'source ./np; echo "trap st=$?"' USR1; kill -USR1 $$; trap - USR1
	echo 'source ./np; echo "nested st=$?"' >inc; . ./inc
	n=0 m=0
	for ((i = 0; i < 150; i++)); do
		source ./np 2>>errs || n=$((n + 1))
		{ x=$(< ./np); } 2>>errs || m=$((m + 1))
	done
	echo "hot: $n $m"
	sed 's/^.*: line [0-9]*: //' errs | sort | uniq -c | sed 's/^ *//'
} >out 2>&1
sed 's/^.*: line [0-9]*: //' out
cd /; rm -rf "$d"
