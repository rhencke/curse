# umask: print, set, symbolic, -S/-p, errors; and if-with-no-else status

umask 0022
umask
umask -S
umask -p

# set octal and observe the effect on a new file's mode
d=$(mktemp -d)
umask 0002
echo one > "$d/one"
umask 0022
echo two > "$d/two"
stat -c '%a' "$d/one" "$d/two"
rm -rf "$d"

# symbolic modification
umask 0124
umask u-r
umask
umask 0124
umask g-w,o-w
umask

# errors leave the umask unchanged
umask 0022
umask 089 2>/dev/null; echo "octal=$?"
umask -rwx 2>/dev/null; echo "dash=$?"
umask '' 2>/dev/null; echo "empty=$?"
umask 'u+r,,u-r' 2>/dev/null; echo "emptyclause=$?"
umask

# an if with a false condition and no else has status 0
if false; then echo no; fi
echo "if-false=$?"
if true; then :; fi
echo "if-true=$?"
false
if [ 1 = 2 ]; then echo no; elif [ 3 = 4 ]; then echo no2; fi
echo "elif-none=$?"
