f=$BENCH_TMP/out.txt; : > $f; for ((i=0;i<5000;i++)); do echo "line $i" >> $f; done; wc -l < $f
