# The RETURN trap (set -T): its $LINENO is the line of the `return` that ended the
# function — with or without a status word, however deep in the body — and the
# function's definition line when the body just ran out (bash's run_return_trap runs with
# the current line_number). `exit` in the RETURN trap exits the shell, with its status
# (_run_trap_internal). Also in a hot loop (compiled bodies) and a function that returns
# from inside a loop.
set -T
trap 'echo "RETURN line=$LINENO fn=${FUNCNAME[0]} st=$?"' RETURN
f() {
	echo in f
	return 3
}
f; echo "st=$?"
g() {
	echo in g
}
g
h() {
	if true; then
		return
	fi
}
h
k() {
	local i
	for ((i = 0; ; i++)); do
		if [ $i = 2 ]; then
			return 7
		fi
	done
}
k; echo "st=$?"
trap 'l="$l $LINENO"' RETURN
r() {
	[ "$1" = 0 ] && return 1
	:
}
l=; for ((j = 0; j < 200; j++)); do r $((j % 2)); done
echo "hot:$(printf '%s\n' $l | sort | uniq -c | tr -s ' ' | tr '\n' ',')"
trap 'echo "exiting from RETURN"; exit 5' RETURN
q() { return 1; }
q
echo not-reached
