i=0; while [ $i -lt 500 ]; do echo $i | cat >/dev/null; i=$((i+1)); done; echo done
