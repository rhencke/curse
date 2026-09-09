# ${#} in a hot loop — worst case for the inline->helper change
s="the quick brown fox jumps over the lazy dog"
acc=0
for ((i=0; i<200000; i++)); do
  n=${#s}
  acc=$((acc + n))
done
echo "$acc"
