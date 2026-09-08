# printf -v assigns formatted output to a variable (no stdout, no newline)
printf -v msg "%s=%d" foo 42
echo "msg: [$msg]"

printf -v line "%s" hello
echo "line: [$line]"

# reassigning the variable replaces it
printf -v msg "%s" replaced
echo "again: [$msg]"

# printf -v into an array element
declare -a arr
printf -v 'arr[2]' "%d" 99
echo "arr2: [${arr[2]}] len: ${#arr[@]}"

# width / padding / precision on stdout
printf '[%5d]\n' 7
printf '[%-5d]\n' 7
printf '[%05d]\n' 42
printf '[%5s]\n' hi
printf '[%-5s]\n' hi
printf '[%.3s]\n' hello
printf '[%.4d]\n' 12
printf '[%+d]\n' 5
printf '[%x]\n' 255
printf '[%08.4d]\n' 3

# multiple format cycles accumulate
printf '%s,' a b c
printf '\n'
