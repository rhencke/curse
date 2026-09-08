# array slicing: ${arr[@]:offset:length}
arr=(a b c d e)
echo "all: ${arr[@]}"
echo "from2: ${arr[@]:2}"
echo "mid: ${arr[@]:1:2}"
echo "star: ${arr[*]:1:2}"
echo "negoff: ${arr[@]: -2}"
echo "negofflen: ${arr[@]: -3:2}"
echo "over: ${arr[@]:10}"
echo "zerolen: ${arr[@]:1:0}"

# quoted keeps each element a field; unquoted splits
count() { echo "$#"; }
count "${arr[@]:1:3}"
count ${arr[@]:1:3}

# positional slicing: ${@:offset:length}
set -- one two three four five
echo "pos from2: ${@:2}"
echo "pos mid: ${@:2:2}"
echo "pos star: ${*:3}"
count "${@:2:3}"

# slice drives a for loop
for x in "${arr[@]:1:3}"; do
  echo "item: $x"
done
