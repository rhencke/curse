# An arithmetic error in an array subscript is bash's DISCARD (array_expand_index): out of
# every eval, function and trap level. Out of the EXIT trap, run_exit_trap catches it: the
# handler ends and the shell's status is the one it had before the trap. curse re-raised it
# past the end of the script — an escaped `(non-string error)` (fuzz F56) — and a subshell
# ended with status 1; the compiled subscript path didn't raise it as a DISCARD at all.
( trap '$[a[!]]; echo no' EXIT; exit 4 ); echo "sub $?"
( trap 'echo in; $[a[!]]
echo no2' EXIT; false ); echo "sub2 $?"
( f() { exit 3; }; trap '$[a[!]]; echo no' EXIT; f ); echo "fn $?"
( eval "trap '\$[a[!]]' EXIT"; exit 5 ); echo "eval $?"
x=$( trap '$[b[!]]' EXIT; echo out ); echo "cs $x $?"
printf 'trap %s EXIT\nexit 7\n' "'echo \${c[!]}'" > s2750.sh
( . ./s2750.sh ); echo "source $?"
# (an `exit` in a sourced file runs the EXIT trap in the file's frame, as in a function's)
printf 'echo in\nexit 7\n' > s2750b.sh
( trap 'echo "src=$BASH_SOURCE"; nosuch' EXIT; . ./s2750b.sh ); echo "srcframe $?"
i=0; while [ $i -lt 150 ]; do ( trap '$[a[!]]' EXIT; exit 2 ); echo "st $?"; i=$((i + 1)); done 2>&1 | sort | uniq -c
rm -f s2750.sh s2750b.sh
trap '$[a[!]]; echo no' EXIT
exit 6
