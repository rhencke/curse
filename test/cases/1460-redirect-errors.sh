# A failed redirection reports status 1 and skips the command, and the shell
# keeps going — it is not a crash. stderr wording isn't compared by this suite.

d=$(mktemp -d)

# Empty target is an "ambiguous redirect".
echo hi > "" 2>/dev/null
echo "empty=$?"

# Reading a nonexistent file fails the command.
cat < "$d/nope" 2>/dev/null
echo "noread=$?"

# Redirecting to a directory fails.
echo hi > "$d" 2>/dev/null
echo "dir=$?"

# ...and normal redirects still work afterward.
echo ok > "$d/f"
cat "$d/f"

# >| forces past noclobber; &>> appends both streams.
set -C
echo one > "$d/c"
echo two >| "$d/c"
cat "$d/c"
{ echo out; echo err >&2; } &>> "$d/c"
cat "$d/c"

rm -rf "$d"
echo done
