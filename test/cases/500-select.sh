# select: menu loop reading choices from stdin (menu/PS3 go to stderr)
# Choose 2 (banana), then an out-of-range 9, then blank (redisplay), then 1.
select fruit in apple banana cherry; do
  echo "reply=$REPLY fruit=[$fruit]"
  [[ $fruit == apple ]] && break
done < <(printf '2\n9\n\n1\n')
echo "after select, fruit=$fruit"

# break out immediately on the first valid choice
select x in one two three; do
  echo "picked $x"
  break
done <<< "3"
echo "done1"

# EOF (no input) ends the loop without running the body
select y in a b; do
  echo "should not run"
done < /dev/null
echo "done2 status ok"

# continue: keep looping until a specific pick, then break
select c in red green blue; do
  [[ $c == green ]] && { echo "got green"; break; }
  echo "not green: [$c] reply $REPLY"
done < <(printf '1\n2\n')
echo "end"
