# A trap handler's `break N` / `continue N` clamps N to the loops there are (bash's
# break_builtin: `if (newbreak > loop_level) newbreak = loop_level` — loop_level global,
# so the handler's own loops and the interrupted ones count together, a function's start
# at 0). A handler runs interpreted the first time and compiled after (a daemon worker
# keeps it compiled for the next request): both must clamp, or the level escapes the
# function (an internal error). Hot loops compiled while such a trap is set count their
# depth from the caller's loops, and hand the rest of a level on to them.
trap 'break 5' USR1
g() { for i in 1 2; do for j in a b; do kill -USR1 $$; echo "$i$j"; done; echo "tail $i"; done; echo "g $i$j"; }
g; g; g
t=${TMPDIR:-/tmp}/c2520.$$
for ((k = 0; k < 200; k++)); do g; done > "$t"; sort "$t" | uniq -c
trap 'for x in 1; do break 7; done' USR1
g; g
for ((k = 0; k < 200; k++)); do g; done > "$t"; sort "$t" | uniq -c
trap 'continue 9' USR1
for ((k = 0; k < 200; k++)); do g; done > "$t"; sort "$t" | uniq -c
rm -f "$t"
echo "-- a hot loop inside interpreted loops"
trap 'break 2' USR1
for a in 1 2; do
  for ((k = 0; k < 300; k++)); do [ $k = 200 ] && kill -USR1 $$; done
  echo "a=$a k=$k"
done
echo "after a=$a k=$k"
trap 'continue 2' USR1
for a in 1 2; do
  for b in x; do
    for ((k = 0; k < 300; k++)); do [ $k = 200 ] && kill -USR1 $$; done
    echo "b=$b k=$k"
  done
  echo "a=$a"
done
echo "after a=$a k=$k"
echo "-- eval text inside loops"
trap - USR1
f() { for a in 1 2; do for b in x y; do eval 'for c in 1; do break 9; done'; echo "no $b"; done; echo "no $a"; done; echo "f $a$b"; }
for ((k = 0; k < 200; k++)); do f; done | uniq -c
echo "-- no loop at all: said, status 0"
trap 'break 3' USR1
kill -USR1 $$; echo "st=$?"
