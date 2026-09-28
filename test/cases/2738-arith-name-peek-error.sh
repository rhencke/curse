# bash's arithmetic tokenizer, reading a name, reads the token after it too (to see an
# `=`): past a run of names, a character that starts no token is that error — `x⏎y@` and
# `x y@` are "invalid arithmetic operator (error token is "@")", not "syntax error in
# expression" (fuzz F39, found as a subscript spanning lines).
( echo "${a[x
y@]}" ); echo "a $?"
( echo $(( x
y@ )) ); echo "b $?"
( echo $(( x y@ )) ); echo "c $?"
( echo $(( x y z# )) ); echo "d $?"
( echo $(( x y )) ); echo "e $?"
( echo $(( 1
2 )) ); echo "f $?"
( echo $(( 1 y@ )) ); echo "g $?"
( echo $(( a[1] b[2]@ )) ); echo "h $?"
echo $(( x
+1 ))
f() { ( (( p q@ )) ); echo "function $?"; }; f
eval '( : $(( r s% )) )'; echo "eval $?"
printf '( : ${a[u\nv@]} )\necho "in $?"\n' > s2738.sh; . ./s2738.sh; echo "source $?"
trap '( : $(( m n@ )) ); echo "trap $?"' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do ( : $(( i j@ )) ); echo "st $?"; i=$((i + 1)); done 2>&1 | sort | uniq -c
rm -f s2738.sh
