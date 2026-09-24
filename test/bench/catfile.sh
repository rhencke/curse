for ((i=0;i<2000;i++)); do x=$(< $BENCH_TMP/inc.sh); done; echo ${#x}
