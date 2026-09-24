n=0; for ((i=0;i<30000;i++)); do s="k$((i%7))"; if [ "$s" = k3 ] || [[ $s == k[45] ]]; then n=$((n+1)); fi; done; echo $n
