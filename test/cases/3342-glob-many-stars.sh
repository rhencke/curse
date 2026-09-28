# An unquoted word made of 100000 `*`s and an `x` matches no file and stays as it is (bash
# prints it). curse died of SIGSEGV matching it (a 20000-star word ran for minutes)
# (stress-attack S13, CRASH).
p=$(printf '%.0s*' $(seq 100000))x
echo $p | wc -c
echo "after: $?"
q=$(printf '%.0s*' $(seq 3000))x
echo $q | wc -c
[[ abc == $q ]]; echo "dbracket: $?"
