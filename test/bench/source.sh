echo 'v=$((v+1))' > $BENCH_TMP/inc.sh; v=0; for ((i=0;i<2000;i++)); do . $BENCH_TMP/inc.sh; done; echo $v
