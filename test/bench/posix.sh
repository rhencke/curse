i=0; s=0; while [ $i -lt 30000 ]; do s=$((s+i)); i=$((i+1)); case $i in *7) s=$((s-1));; esac; done; echo $s
