for ((i=0;i<5000;i++)); do set -- a b c d e f g; n=0; while [ $# -gt 0 ]; do n=$((n+1)); shift; done; done; echo $n
