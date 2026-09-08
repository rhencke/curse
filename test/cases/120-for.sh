for f in apple banana cherry; do
  echo "fruit: $f"
done
total=0
for n in 1 2 3 4 5; do
  total=$((total + n))
done
echo "total=$total"
for ((i = 0; i < 3; i++)); do
  echo "count $i"
done
for x in $(echo a b c); do
  echo "x=$x"
done
