# a helper is DEFINED (previously any function disabled top-level lifting), but
# the hot work is a top-level arithmetic loop whose vars no function touches.
log() { echo "[$1]"; }
log start
sum=0
for ((i=1; i<=20000000; i++)); do
  sum=$((sum + i * 2 - 1))
done
log done
echo "$sum"
