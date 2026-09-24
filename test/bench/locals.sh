f() { local a=$1 b=$2 c; c=$((a*b)); local d="$a-$b"; echo -n; r=$c; }; for ((i=0;i<20000;i++)); do f $i 3; done; echo $r
