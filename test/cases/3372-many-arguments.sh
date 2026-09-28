# Commands with tens of thousands of arguments: a function call, `set --`, an array
# assignment and a builtin's argument list. curse failed with a Lua error ("too many results
# to unpack", the script ended, status 1) from about 10000 arguments on (stress-attack S14).
f() { echo "function: $#"; }
f $(seq 10000)
f $(seq 60000)
set -- $(seq 60000); echo "set: $# ${60000}"
a=($(seq 60000)); echo "array: ${#a[@]}"
printf '%s\n' "${a[@]}" | tail -1
echo end
