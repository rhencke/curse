for ((i=0;i<20000;i++)); do printf -v s '%05d:%s:%x' $i abc $i; done; echo $s
