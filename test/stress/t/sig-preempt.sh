#@ guards: asynchronous preemption of pure compute loops that never reach a VM safepoint (the custom LuaJIT hook + destructive back-edge patch, CURSE_SIG_DESTRUCTIVE, commit 4338191): a trap must run promptly in JIT traces of several shapes, repeatedly, and the loop must resume correctly after each trap
#@ timeout: 60
#@ nested: yes
H=$STH
d=$HOME/pe; mkdir -p "$d"
sig() { rm -f "$d/done"; "$H" hammer $$ ${2:-10} ${3:-1} ${1:-20000} ${1:-20000} "$d/done"; }
settle() { until [ -e "$d/done" ]; do /bin/sleep 0.01; done; }
echo "-- a trap that stops each loop shape"
trap 'stop=1' USR1
stop=0; sig; while [ $stop = 0 ]; do :; done; settle; echo "empty body: stopped"
stop=0; sig; i=0; while ((stop == 0)); do ((i++)); done; settle; echo "arith: stopped"
stop=0; sig; s=; while [ $stop = 0 ]; do s=${s:0:10}x; done; settle; echo "string: stopped"
f() { :; }
stop=0; sig; while [ $stop = 0 ]; do f; done; settle; echo "function call: stopped"
stop=0; sig; for ((;;)); do [ $stop = 1 ] && break; done; settle; echo "for((;;)): stopped"
stop=0; sig; a=(1 2 3); while [ $stop = 0 ]; do a[1]=$((a[1] + 1)); done; settle; echo "array: stopped"
echo "-- a loop interrupted many times keeps its count exact"
n=0
trap 'n=$((n+1))' USR1
sig 3000 10 40
i=0; while [ $i -lt 400000 ]; do i=$((i+1)); done
settle
echo "i=$i traps: $([ $n -ge 1 ] && [ $n -le 40 ] && echo ok || { echo "bad $n" >&2; echo bad; })"
echo "-- exit from a trap inside a JIT loop (a child shell: its own \$\$)"
"$THIS_SH" -c 'trap "exit 7" USR2; "$STH" hammer $$ 12 1 20000 20000 "$1"; while :; do :; done' _ "$d/done"; echo "st=$?"
settle
"$THIS_SH" -c 'trap "echo \"  in trap\"; exit 8" TERM; "$STH" hammer $$ 15 1 20000 20000 "$1"; x=0; while :; do x=$((x ^ 1)); done' _ "$d/done"; echo "st=$?"
settle
echo "-- break/continue/return decided by the trap"
trap 'flag=1' USR1
flag=0; sig; for ((k = 0; ; k++)); do [ $flag = 1 ] && break; done; settle; echo "broke out"
g() { flag=0; sig; while :; do [ $flag = 1 ] && return 4; done; }
g; echo "returned $?"; settle
trap - USR1
rm -rf "$d"
"$STH" probe
