# A `for (( … ))` header or `(( … ))` command split across lines: bash's lexer counts
# the newlines inside the parens, so every later $LINENO stays right. The (( )) command
# is stamped with the line its `))` closed on (make_arith_command); the for header with
# the line it opened on (parse_dparen's arith_for_lineno). Error texts keep a leading
# newline (evalerror skips only blanks), and a slot holding just a newline is an
# expression (0), not an empty slot (1).
exec 2>&1
for (( i=0;
  i<1;
  i++ )); do echo "body $LINENO"; done
echo "after-for $LINENO"
((y=$LINENO +
0
)); echo "arith y=$y at $LINENO"
((1/0 +

0))
echo "after-div $LINENO"
for ((i=0;
i<1/0;
i++)); do :; done
echo "after-bad-for $LINENO"
for ((i=0;
;i++)); do echo never; break; done
echo "nl-slot $LINENO"
(( 
 1/0 ))
let "
 2/0"
f() {
	local n=0 j
	for (( j=0;
	  j<200;
	  j++ )); do (( n += 1
	  )); done
	echo "f n=$n line=$LINENO"
	for ((j=0; j<200;
	  j += (j==180 ? 1/0 : 1))); do
		:
	done
	echo "f done $LINENO"
}
f
eval 'for ((k=0;
k<160;
k++)); do :; done; echo "eval $LINENO"'
echo "end $LINENO"
# a hot loop in eval'd text numbers its loops from 1 again: it must not switch the
# program into the program's own loop 1 (the errored `for` above would re-run)
eval 'for ((k=0; k<200; k++)); do :; done; echo "eval2 $k"'
# a hot loop fragment (subshell) whose init slot holds a newline
( for ((i=0
;i<300;
i++)); do x=$LINENO; done; echo "sub $x $LINENO" )
