# An arithmetic error abandons the rest of the line, but every variable keeps what the
# commands before it did — bash's variables are simply where the aborted command left
# them. The compiled tier keeps arithmetic loop variables in native locals (run()'s, or
# the module's upvalues when a function touches them), so the abort must write those
# back — except while a call that works on the shell's variables is out: then the
# callee's changes (an imported function's here) are the live values.
x=1; for ((i = 0; i < 300; i++)); do x=$i; : $((1 / (i - 200))); done
echo "run-local: $i $x"
f() { :; }
for ((i = 0; i < 300; i++)); do f; : $((1 / (i - 250))); done
echo "function in loop: $i"
g() { ((i += 0)); }
for ((i = 0; i < 300; i++)); do g; : $((1 / (i - 180))); done
echo "function touches it: $i"
for ((j = 0, k = 5; j < 300; j++, k += 2)); do : $((1 / (j - 160))); done
echo "two: $j $k"
for ((n = 0; n < 3; n++)); do
	for ((i = 0; i < 300; i++)); do : $((1 / (i - 170 - n))); done
	echo "in a loop: $n $i"
done
S=${THIS_SH:-bash}
h() { i=$((i + 1)); : $((1 / (i - 401))); }
export -f h
$S -c 'for ((i = 0; i < 600; i++)); do h; done
echo "imported function: $i"' 2>&1 | sed 's/^.*line [0-9]*: //'
$S -c 'for ((i = 0; i < 600; i++)); do : $((1 / (i - 390))); h; done
echo "imported function, own abort: $i"' 2>&1 | sed 's/^.*line [0-9]*: //'
