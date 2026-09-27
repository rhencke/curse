# A line abort resumes after the aborted top-level command — whatever eval/source/trap
# text ran before it. The compiled tier runs that text as a nested fragment with its own
# line markers; the outer program's resume point must survive it (a fragment that left
# its own behind sent the outer abort into the fragment's numbering: the script silently
# ended with status 1, or looped forever). bash: the rest of the loop is abandoned, the
# next line runs, status 0 at the end.
T=${TMPDIR:-/tmp}/fko$$
mkdir -p "$T"
exec 3>&2 2>"$T/err"
printf '%s\n' 'a=1' 'b=2' >"$T/s.inc"
trap ':' USR1
for i in 1 2; do
	kill -USR1 $$
	if [ $i = 2 ]; then echo $((i / 0)); fi
done
echo "usr1 trap $LINENO"
trap - USR1
trap ':' ERR
for i in 1 2; do
	false
	if [ $i = 2 ]; then echo $((i / 0)); fi
done
echo "err trap $LINENO"
trap - ERR
for i in 1 2 3; do
	. "$T/s.inc"
	x=$(echo hi); y=$(echo there)
	if [ $i = 3 ]; then echo $((i / 0)); fi
done
echo "dot in loop $LINENO"
# hot: the fragments run in a compiled loop, the abort after it
for ((i = 0; i < 300; i++)); do
	. "$T/s.inc"
	eval 'c=3
d=4'
	if [ $i = 299 ]; then echo $((i / 0)); fi
done
echo "hot $i $LINENO"
f() {
	eval 'a=1
b=2'
	echo $((1 / 0))
	echo "not reached"
}
f; f; f
echo "fn $LINENO"
exec 2>&3
sed 's#^[^ ]*: line#line#' "$T/err"
rm -rf "$T"
