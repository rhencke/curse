a=(); for ((i=0;i<20000;i++)); do a+=("v$i"); done; n=0; for x in "${a[@]}"; do n=$((n+${#x})); done; echo $n ${#a[@]}
