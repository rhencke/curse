fib() { if (( $1 < 2 )); then r=$1; return; fi; fib $(( $1 - 1 )); local a=$r; fib $(( $1 - 2 )); r=$(( a + r )); }; fib 18; echo $r
