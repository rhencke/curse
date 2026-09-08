echo hello | tr a-z A-Z
printf 'c\na\nb\n' | sort
printf 'one\ntwo\nthree\n' | wc -l
echo "count me" | wc -w
printf 'a\nb\na\nc\nb\n' | sort | uniq
echo "first second third" | cut -d' ' -f2

# pipeline into a while-read
printf 'x\ny\nz\n' | while read item; do
  echo "item: $item"
done

# multi-stage
printf '3\n1\n2\n1\n' | sort | uniq | tr '\n' ' '
echo

# negated pipeline status
if ! echo hi | grep -q bye; then
  echo "no bye"
fi

# pipeline exit status is last stage
echo x | false
echo "status: $?"
echo x | true
echo "status2: $?"
