# repeated function calls with locals and params
add() { local a=$1 b=$2; echo $((a + b)); }
total=0
for ((i=0; i<100000; i++)); do
  total=$(add "$total" "$i")
done
echo "$total"
