s=abcdefghijklmnopqrstuvwxyz; for ((i=0;i<30000;i++)); do t=${s:i%20:5}${s: -3}; done; echo $t
