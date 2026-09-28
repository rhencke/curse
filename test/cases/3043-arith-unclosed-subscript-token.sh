# A name followed by `[` with no closing `]` (bash's skipsubscript: quotes and ${…} are
# skipped) is "bad array subscript", naming the text from that name on — also after a
# complete operand (`y[t]y[|`) and when an unclosed quote or ${ inside it runs past every
# `]` (`p[++${'k]}]2*A[`). curse said "invalid arithmetic operator" or "bad substitution"
# (fuzz F102, F106).
t() { local e=$1; ( echo "$(( $e ))" ); echo "st $?"; }
t 'y[t]y[|'
t 'y[t]y[1'
t '1 y[1'
t '1 x y[1'
t 'y[1] y[2] @'
t 'y[1'
t '1+y[1'
p='*o*'
t "p[++\${'k]}]2*A["
t "2*p[++\${'k]}]2*A["
t "a['x]']+1"
( echo $(( a[']'] + 1 )) ); echo "st $?"
eval 't "q[\${x]"'
printf 't "r[\\"]"\n' > s3043.sh; . ./s3043.sh
trap 't "z[1]z[2"' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do t "y[$i]y[|"; i=$((i + 1)); done 2>&1 | sed 's/[0-9][0-9]*/N/g' | sort | uniq -c
rm -f s3043.sh
