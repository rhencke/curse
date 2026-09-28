# In arithmetic a `$` inside "…" is just a character of the text bash expands — the
# quotes go, the `$` stays, and the result is parsed as arithmetic, where it's an error:
# `$(( "$"@ ))` reads `$@` (fuzz F38). curse dropped that `$` as if it prefixed a quote
# ($"…"), and read `"$"1` as $1. A `$` before a quote outside "…" is still ignored, and
# the text shown in the error is the one with it dropped.
x=1
( : $(( "$"@ )) ); echo "a $?"
( : $(( "$" )) ); echo "b $?"
( : $(( "$"1 )) ); echo "c $?"
( : $(( $'3' )) ); echo "d $?"
echo $(( $"3" + 1 )) $(( "$x" + 1 )) $(( "x" + 1 )) $(( "1+2" * 3 ))
(( "$x" > 0 )) && echo yes
f() { ( : $(( "$"# )) ); echo "function $?"; }; f
eval '( : $(( 2 + "$"x )) )'; echo "eval $?"
printf '( : $(( "$"@ )) )\necho "in $?"\n' > s2737.sh; . ./s2737.sh; echo "source $?"
trap '( : $(( "$"@ )) ); echo "trap $?"' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do ( : $(( "$"@ )) ); echo "st $? $(( "$i" % 2 ))"; i=$((i + 1)); done 2>&1 | sort | uniq -c
rm -f s2737.sh
