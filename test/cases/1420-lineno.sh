# $LINENO reports the current source line, updated per command; it is the line
# of the executing command, not of a function's call site.
echo "a=$LINENO"
echo "b=$LINENO"

x=$LINENO
echo "assign=$x"

f() {
  echo "in f=$LINENO"
}
f
f

if true; then
  echo "if=$LINENO"
fi

i=0
while (( i < 2 )); do
  echo "while=$LINENO"
  i=$((i + 1))
done

for w in one two; do
  echo "for=$LINENO"
done

case x in
  x) echo "case=$LINENO" ;;
esac
