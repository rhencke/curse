# A `*` width or precision past INT_MAX is clamped (getint: "Numerical result out of range",
# naming the word after it — bash has stepped past the number) and the padding is written
# as it is formatted: 2 GiB of it. curse built the padded text in memory and died of an
# escaped Lua "not enough memory" (fuzz F13); it now streams a huge pad in chunks.
printf '[%*d]' 9999999999 1 >/dev/null; echo "after $?"
printf '[%.*d]' 9999999999 1 >/dev/null; echo "after $?"
printf '[%*d]' -9999999999 1 >/dev/null; echo "after $?"
printf '[%*s]' 3000000000 x >/dev/null; echo "after $?"
printf '%*s' 9999999999 >/dev/null; echo "after $?"
printf '[%*f]' 9999999999 1 >/dev/null; echo "after $?"
printf 'a%*db\n' 3000000 1 | wc -c
printf '%-*dX\n' 2000000 7 | tail -c 3
printf '%0*d\n' 2000000 -5 | head -c 3; echo
printf '%*.*d|\n' 2000000 1500000 42 | tail -c 5
printf '%.*d|\n' 1500000 42 | head -c 3; echo
printf '%*s|%*s|\n' 1100000 x 1200000 y | wc -c
printf '%0*f|\n' 2000000 -1.5 | head -c 3; echo
printf '%-*e|\n' 2000000 1 | tail -c 3
printf 'lines\n%*d%n\n' 2000000 1 n | wc -c; printf '%*d%n' 2000000 1 n >/dev/null; echo "n=$n"
f() { printf '%*d' "$1" 2 | wc -c; }; f 1500000
eval "printf '%*s' 1048576 z" | wc -c
trap "printf '%*s' 1300000 t | wc -c" USR1; kill -USR1 $$
for ((i = 0; i < 150; i++)); do printf '%*d' 1048577 "$i"; done | wc -c
printf '[%*d]' 9999999999 1 | tail -c 3; echo
