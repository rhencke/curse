declare -A m; for ((i=0;i<20000;i++)); do m["k$((i%500))"]=$i; done; n=0; for k in "${!m[@]}"; do n=$((n+m[$k])); done; echo $n
