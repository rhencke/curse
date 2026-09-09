# for-x-in outer loop with a nested arithmetic loop
sum=0
for x in 1 2 3 4 5 6 7 8 9 10; do
  for ((i=1; i<=2000000; i++)); do
    sum=$((sum + x))
  done
done
echo "$sum"
