# The DEBUG trap fires before the condition and body commands of compound
# constructs, at the current level: the for-loop header fires once per
# iteration, an if/while condition fires each time it is evaluated.
debuglog() { echo "  [$1]"; }
trap 'debuglog $LINENO' DEBUG

for x in a b; do
  echo "x=$x"
done

if test 1 = 1; then
  echo yes
fi

n=0
while test $n -lt 2; do
  echo "n=$n"
  n=$((n + 1))
done

echo end
