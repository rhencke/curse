# a function called in a tight loop (1M calls)
add() { sum=$((sum + $1)); }
sum=0
for ((i=1; i<=1000000; i++)); do
  add "$i"
done
echo "$sum"
