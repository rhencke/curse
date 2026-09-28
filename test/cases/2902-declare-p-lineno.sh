# `declare -p LINENO` (typeset, readonly/local listings) shows the line the command runs
# at — in compiled code too, which keeps no running line count (leftover L4).
x=1

declare -p LINENO
typeset -p LINENO; declare -p LINENO x
f() {
	declare -p LINENO
}
f
g() { local -p LINENO 2>/dev/null; declare -p LINENO; }
g
i=0
while [ $i -lt 150 ]; do
	o=$(declare -p LINENO)
	i=$((i + 1))
done
echo "$o"
eval 'declare -p LINENO
declare -p LINENO'
printf 'declare -p LINENO\n\ndeclare -p LINENO\n' > s2902.sh; . ./s2902.sh
trap 'declare -p LINENO' USR1; kill -USR1 $$; trap - USR1
rm -f s2902.sh
