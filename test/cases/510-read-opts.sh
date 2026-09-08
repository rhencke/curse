# read: multiple names, last gets the remainder
read a b c <<< "one two three four"
echo "a=$a b=$b c=$c"

# -a splits the line into an array
read -a arr <<< "x y z"
echo "arr=${arr[*]} n=${#arr[@]}"

# custom IFS (per-command assignment)
IFS=: read u p rest <<< "root:x:0:0:root"
echo "u=$u p=$p rest=$rest"

# -d: read up to a custom delimiter
read -d ';' item <<< "hello;world"
echo "item=[$item]"

# -n: stop after N characters
read -n 3 three <<< "abcdefg"
echo "three=[$three]"

# -r keeps backslashes; default read unescapes them
read -r raw <<< 'a\tb\\c'
echo "raw=[$raw]"
read line <<< 'a\tb'
echo "cooked=[$line]"

# read loop over lines from a pipe
printf 'l1\nl2\nl3\n' | while read ln; do echo "got:$ln"; done

# no names -> REPLY (untrimmed)
read <<< "  spaced line  "
echo "reply=[$REPLY]"
