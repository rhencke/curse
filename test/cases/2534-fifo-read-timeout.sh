# `read -t` on a NAMED FIFO: the open (a redirection, before read's timer starts) blocks until
# a writer opens; then read times out (142) only while the writer holds the FIFO open
# without a full line, and sees EOF (1) once it has closed — whether the writer is a
# subshell, a group, a simple builtin or an external.
d=${TMPDIR:-/tmp}/rf$$; mkdir -p $d; mkfifo $d/f
(sleep 0.2; echo hi > $d/f) & read -t 1 x < $d/f; echo "a $? $x"; wait
(echo hi > $d/f) & read -t 1 x < $d/f; echo "b $? $x"; wait
(printf hi > $d/f) & read -t 1 x < $d/f; echo "c $? $x"; wait
(exec 3>$d/f; sleep 0.3) & read -t .1 x < $d/f; echo "d $? $x"; wait
(exec 3>$d/f) & read -t 1 x < $d/f; echo "e $? [$x]"; wait
{ sleep 0.1; echo hi > $d/f; } & read -t 1 x < $d/f; echo "f $? $x"; wait
sleep 0.3 > $d/f & read -t .1 x < $d/f; echo "g $? $x"; wait
echo hi > $d/f & read -t 1 x < $d/f; echo "h $? $x"; wait
/bin/echo hi > $d/f & read -t 1 x < $d/f; echo "i $? $x"; wait
rm -rf $d
d=${TMPDIR:-/tmp}/rg$$; mkdir -p $d; mkfifo $d/f
(sleep 0.4; exec 3>$d/f) & t0=${EPOCHREALTIME/./}; read -t .1 x < $d/f; echo "j $? [$x] $(( (${EPOCHREALTIME/./} - t0) > 300000 ))"; wait
(sleep 0.4; exec 3>$d/f; sleep .3) & read -t .1 x < $d/f; echo "k $? [$x]"; wait
exec 5<>$d/f; read -t .1 x <&5; echo "l $? [$x]"; exec 5<&-
rm -rf $d
echo "-- hot: 150 writers, a line then EOF"
d=${TMPDIR:-/tmp}/rh$$; mkdir -p $d; mkfifo $d/f
n=0 e=0
for ((i = 0; i < 150; i++)); do
	(echo "w$i" >$d/f) &
	read -t 2 x <$d/f && [ "$x" = "w$i" ] && n=$((n + 1))
	wait
	(exec 3>$d/f) &
	read -t 2 x <$d/f; [ $? = 1 ] && e=$((e + 1))
	wait
done
echo "lines: $n eofs: $e"
rm -rf $d
