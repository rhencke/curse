# break / continue in for, while, until, and C-style for; with counts

# break out of a for loop
for i in 1 2 3 4 5; do
  [[ $i -eq 3 ]] && break
  echo "for: $i"
done

# continue skips
for i in 1 2 3 4 5; do
  [[ $((i % 2)) -eq 0 ]] && continue
  echo "odd: $i"
done

# while with break
n=0
while true; do
  n=$((n + 1))
  [[ $n -gt 3 ]] && break
  echo "while: $n"
done

# until with continue + break
k=0
until [[ $k -ge 6 ]]; do
  k=$((k + 1))
  [[ $((k % 3)) -ne 0 ]] && continue
  echo "until mult3: $k"
done

# C-style for with continue (step must still run) and break
for ((i = 0; i < 10; i++)); do
  [[ $((i % 2)) -eq 1 ]] && continue
  [[ $i -ge 6 ]] && break
  echo "cfor: $i"
done

# nested loops with break 2 / continue 2
for a in x y z; do
  for b in 1 2 3; do
    [[ $a == y && $b -eq 2 ]] && break 2
    [[ $b -eq 2 ]] && continue 2
    echo "nested: $a$b"
  done
  echo "after-inner: $a"
done

# break inside a function does not escape to a caller loop
f() { break; echo "after break in func"; }
for i in 1 2; do
  f
  echo "loop-continues: $i"
done
echo done
