for ((i=0;i<5000;i++)); do read -r a b <<< "x$i y$i"; done; echo $a $b
