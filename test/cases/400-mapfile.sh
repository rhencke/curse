# mapfile -t: read lines into an array, stripping the newline
data=$'alpha\nbeta\ngamma'
mapfile -t lines <<< "$data"
echo "count: ${#lines[@]}"
echo "0: ${lines[0]}"
echo "2: ${lines[2]}"
for l in "${lines[@]}"; do echo "line: [$l]"; done

# without -t, each element keeps its trailing newline
mapfile raw <<< $'x\ny'
echo "raw0: [${raw[0]}]"
printf 'raw count: %d\n' "${#raw[@]}"

# readarray is an alias
readarray -t arr <<< $'one\ntwo\nthree'
echo "arr: ${arr[*]}"

# -s skip and -n count (options precede the array name)
mapfile -t -s 1 -n 2 part <<< $'a\nb\nc\nd\ne'
echo "part: ${part[*]}"

# -O origin assigns into an existing array
nums=(zero one)
mapfile -t -O 2 nums <<< $'two\nthree'
echo "nums: ${nums[*]} len ${#nums[@]}"

# custom delimiter
mapfile -t -d , csv <<< "a,b,c,d"
echo "csv count: ${#csv[@]}"
echo "csv0: [${csv[0]}]"
