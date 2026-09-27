# bash runs a $( … ) body as parse_comsub re-printed it (print_comsub): `a |⏎b` and `a &&⏎b`
# joined on one line, blank lines and comments gone, compound commands laid out anew,
# newlines between commands kept — so $LINENO and an error's `line N:` count the printed
# lines, from the command's own line. curse counted the source lines (fuzz F18).
x=$( : |
(a1
b1)
)
x=$( : |
a2
)
x=$( :

a3
)
x=$( : # c

a4
)
x=$( { :
} && a5
)
x=$(f() { :; }; a6)
x=$(if :; then :; fi; a7)
x=$(case x in x) :;; esac; a8)
x=$(for i in 1
do b9
c9
done; a9)
x=$( b10 & wait
 c10
 a10)
x=$(echo $LINENO

: |
echo $LINENO); echo "$x" | tr '\n' ' '; echo
cat <(:

a11)
x=$(echo $$'x\nx'); case $x in [0-9]*) echo "pid first";; *) echo "not $x";; esac
x="$(:

a12)"
cat <<E
$(:

a13)
E
x=`:

a14`
f() {
	x=$( : |
	a15 )
}
f
eval 'x=$( : |
a16
)'
printf 'x=$( : |\na17\n)\n' > s2715.sh; . ./s2715.sh; rm -f s2715.sh
for ((i = 0; i < 150; i++)); do x=$( : |
a19 ); done 2>&1 | sort | uniq -c
