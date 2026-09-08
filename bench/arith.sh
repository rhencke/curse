# tight arithmetic loop
sum=0
for ((i=1; i<=500000; i++)); do
  sum=$((sum + i * 2 - 1))
done
echo "$sum"
