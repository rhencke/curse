trap 'x=1' USR2; for ((i=0;i<20000;i++)); do y=$((i*2)); done; echo $y
