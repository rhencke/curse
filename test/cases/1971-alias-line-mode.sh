# aliases defined as the script runs (conditionally, in a function, in a loop) change how
# LATER lines parse: the script runs a line at a time, each line compiled on its own
shopt -s expand_aliases
alias say='echo said'
if true; then alias hi='echo hi there'; fi
say one
hi
mk() { alias "$1=echo made $1"; }
mk m1
m1 now
f() { say in f; }
f
for i in 1 2 3; do say $i; done
n=0; while (( n < 150 )); do n=$((n+1)); done; echo $n
alias inc='k=$((k+1))'
k=0; for j in $(seq 120); do inc; done; echo $k
alias sq="echo 'quoted arg'" sp='echo trailing '
sq; sp say
unalias say
say 2>/dev/null || echo gone
x=$(alias hi); echo "$x"
alias x=y; alias x
break
echo after
