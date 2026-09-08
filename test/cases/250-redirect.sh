cd "$(mktemp -d)"

echo hello > out.txt
cat out.txt
echo world >> out.txt
cat out.txt

printf 'a\nb\nc\n' > f2
wc -l < f2

cat <<< "herestring input"
tr a-z A-Z <<< "shout"

echo "combined" > both.txt 2>&1
cat both.txt

this_command_does_not_exist_xyz 2>/dev/null
echo "after missing: $?"

echo discarded > /dev/null
echo "still here"

# read from a redirected file
printf 'alpha\nbeta\ngamma\n' > lines.txt
while read line; do
  echo "got: $line"
done < lines.txt

# read splits fields
echo "one two three four" > fields.txt
read a b c < fields.txt
echo "a=$a b=$b c=$c"
