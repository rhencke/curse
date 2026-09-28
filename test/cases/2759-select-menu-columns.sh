# select prints its menu as bash's print_select_list lays it out: in columns across $COLUMNS
# (80 when unset or not a positive number and stderr is no terminal), numbered down each
# column, padded with tabs then spaces; one row turns into one column. curse printed one item
# per line (fuzz F59).
select x in aaaaaaaaaaaaaa b c d e; do break; done <<< 1
echo "x=$x"
COLUMNS=40; select x in $(seq 1 25); do break; done <<< 3; echo "x=$x"
COLUMNS=200; select x in one two three four five six seven eight nine ten eleven twelve; do break; done <<< 12; echo "x=$x"
COLUMNS=10; select x in a bb; do break; done <<< 2; echo $x
COLUMNS=x; select x in a b c; do break; done <<< 2; echo $x
unset COLUMNS; select x in a $'\t' b; do break; done <<< 2
f() { local COLUMNS=30; select y in $(seq 100 120); do break; done <<< 21; echo "y=$y"; }; f
i=0; while [ $i -lt 150 ]; do select z in p q r s t u; do break; done <<< 6; i=$((i + 1)); done 2>&1 | sort | uniq -c
