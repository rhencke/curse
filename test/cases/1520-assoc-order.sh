# Associative arrays iterate in bash's hash-table order (FNV-1 over the key's
# UTF-8 bytes into 1024 buckets, buckets ascending, newest-first within a
# bucket), NOT insertion or sorted order. `${!a[@]}`, `${a[@]}`, `declare -p`,
# and `for k in` must all agree with bash.
declare -A m=([apple]=1 [banana]=2 [cherry]=3 [x]=4 [y]=5 [z]=6 [foo]=7 [one]=8 [two]=9 [three]=10)
echo "keys: ${!m[@]}"
echo "vals: ${m[@]}"
declare -p m
for k in "${!m[@]}"; do printf '%s=%s ' "$k" "${m[$k]}"; done; echo

# order must be independent of insertion order for distinct buckets
declare -A n=([z]=1 [y]=2 [x]=3)
echo "n: ${!n[@]}"
