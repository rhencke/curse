# a trap handler that breaks/continues acts on the COMPILED loop it interrupted, after the
# command that was running (bash's breaking/continuing); inside a function it is outside any
# loop; levels past the outermost loop clamp
trap 'echo in-trap; break' USR1
for i in 1 2 3; do [ $i = 2 ] && kill -USR1 $$; echo "i=$i"; done
echo "after i=$i"
f() { kill -USR1 $$; echo "f after"; }
for i in 1 2; do f; echo "loop i=$i"; done
trap 'continue' USR1
for i in 1 2 3; do for j in a b; do [ $j = a ] && kill -USR1 $$; echo "$i$j"; done; done
trap 'continue 2' USR1
for i in 1 2; do for j in a b; do [ $j = a ] && kill -USR1 $$; echo "$i$j"; done; echo "tail $i"; done
trap 'break 5' USR1
for i in 1 2; do for j in a b; do kill -USR1 $$; echo "$i$j"; done; echo "tail $i"; done
echo end
n=0
trap 'n=$((n+1)); [ $n -ge 3 ] && break' USR1
while :; do kill -USR1 $$; echo "tick $n"; done
echo "out n=$n"
trap 'continue' USR2
g() { for k in 1 2 3; do [ $k = 2 ] && kill -USR2 $$; echo "g$k"; done; }
g
for i in 1 2; do g; echo "after g $i"; done
trap - USR1 USR2
for i in 1 2; do echo plain $i; done
