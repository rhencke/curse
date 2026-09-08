x=5
if [ "$x" = 5 ]; then
  echo "x is five"
fi
if [ "$x" -gt 10 ]; then
  echo "big"
elif [ "$x" -gt 3 ]; then
  echo "medium"
else
  echo "small"
fi
if true; then echo yes; else echo no; fi
name=world
if [ -n "$name" ]; then echo "has name: $name"; fi
if [ -z "" ]; then echo "empty is empty"; fi
