n=0; for ((i=0;i<20000;i++)); do [[ "abc$i" =~ ^abc([0-9]+)5$ ]] && n=$((n+1)); done; echo $n
