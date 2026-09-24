v1=a; v2=b; for ((i=0;i<30000;i++)); do n=v$((i%2+1)); x=${!n}; done; echo $x
