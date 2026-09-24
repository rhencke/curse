n=0; while IFS=: read -r a b c rest; do n=$((n+${#a})); done < $BENCH_TMP/data.txt; echo $n
