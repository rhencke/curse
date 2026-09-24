n=0; for ((i=0;i<20000;i++)); do [[ -f /etc/passwd && -d /tmp && ! -e /nonexist ]] && n=$((n+1)); done; echo $n
