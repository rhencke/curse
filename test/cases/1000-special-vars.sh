# static and dynamic special variables (checked by shape, not exact value)

# PWD is set (has a slash) and exported
echo "$PWD" | grep -q / && echo "pwd-slash"
env | grep -q "^PWD=" && echo "pwd-exported"
cd /
[ "$PWD" = / ] && echo "pwd-tracks-cd"

# UID / EUID / PPID are numeric
echo "$UID" | grep -qE '^[0-9]+$' && echo "uid-num"
echo "$EUID" | grep -qE '^[0-9]+$' && echo "euid-num"
echo "$PPID" | grep -qE '^[0-9]+$' && echo "ppid-num"

# OSTYPE / HOSTTYPE / MACHTYPE are non-empty
[ -n "$OSTYPE" ] && echo "ostype"
[ -n "$HOSTTYPE" ] && echo "hosttype"
[ -n "$MACHTYPE" ] && echo "machtype"

# RANDOM is in range and (almost surely) varies
r=$RANDOM
[ "$r" -ge 0 ] && [ "$r" -le 32767 ] && echo "random-range"
a=$RANDOM; b=$RANDOM; c=$RANDOM
[ "$a" != "$b" ] || [ "$b" != "$c" ] && echo "random-varies"

# SECONDS starts at 0 and is numeric
echo "$SECONDS" | grep -qE '^[0-9]+$' && echo "seconds-num"
