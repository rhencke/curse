# After an assignment or redirection prefix nothing is a reserved word: `>f }` runs a
# command named `}` (command not found, 127), as `x=1 fi` runs `fi` — curse took the word
# as a misplaced closer, a syntax error (fuzz F49). `{ >f }` then leaves the group open.
( <<F }
F
echo "a $?" )
( >/dev/null }; echo "b $?" )
( x=1 }; echo "c $?" )
( >/dev/null fi; echo "d $?" )
( x=1 done; echo "e $?" )
( >/dev/null then; echo "f $?" )
( 2>&1 esac; echo "g $?" )
( y=2 in; echo "h $?" )
eval '{ >/dev/null }; echo i'; echo "eval $?"
f() { >/dev/null }; echo "function $?"; }; f
printf '>/dev/null }\necho "in $?"\n' > s2747.sh; . ./s2747.sh
trap '2>/dev/null }; echo "trap $?"' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do x=$i }; i=$((i + 1)); done 2>&1 | sort | uniq -c
echo "k $?"; { echo grouped; }; if :; then z=1; fi; echo "$z"
rm -f s2747.sh
