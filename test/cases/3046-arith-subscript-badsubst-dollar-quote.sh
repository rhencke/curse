# A subscript whose ${ never closes runs to the end of the text (skipsubscript), so bash
# reports the whole expression as the bad substitution (` a[${] : bad substitution`); and
# a `$` before a quote in a subscript's EXPANDED text is kept — `a[$\"]` evaluates `$"`
# (only source arithmetic drops a `$` before a quote). curse named `${` / `"` alone
# (leftover M2).
t() { ( eval "echo \$(( $1 ))" ); echo "st $?"; }
t 'a[${]'
t '1 + a[${]'
t 'a[${x]'
t 'a[$\"]'
t 'a[$\"x]'
t 'a[x$\"]'
t "a[\$\\']"
( echo "$(( a[${] ))" ); echo "st $?"
( (( a[${] )) ); echo "st $?"
( echo $[ a[${] ] ); echo "st $?"
( echo $(( a[$\"] )) ); echo "st $?"
f() { ( echo $(( a[$\"] + 1 )) ); echo "f $?"; }; f
printf '( echo $(( b[${] )) ); echo "src $?"\n' > s3046.sh; . ./s3046.sh
trap '( echo $(( c[$\"] )) ); echo "trap $?"' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do ( echo $(( a[$\"] )) ); ( echo $(( a[${] )) ); i=$((i + 1)); done 2>&1 | sort | uniq -c
rm -f s3046.sh
