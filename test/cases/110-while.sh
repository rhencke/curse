i=0
while [ "$i" -lt 3 ]; do
  echo "i=$i"
  i=$((i + 1))
done
echo "done at $i"
n=5
sum=0
while (( n > 0 )); do
  sum=$((sum + n))
  n=$((n - 1))
done
echo "sum=$sum"
