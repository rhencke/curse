add() { r=$(( $1 + $2 )); }; s=0; for ((i=0;i<20000;i++)); do add $s $i; s=$r; done; echo $s
