# Array / positional slice offset and length edge cases.

a=(1 2 3 4 5)

# A negative offset counts from the end; once it passes the start the slice is
# empty, not clamped to the whole array.
for o in 1 2 3 4 5 6; do echo "off -$o -> (${a[*]: -$o})"; done

# A positive offset past the end is empty; length clamps to what's left.
echo "off 3 len 9 -> (${a[*]:3:9})"
echo "off 9 -> (${a[*]:9})"

# A negative length on an ARRAY slice is a fatal error (status 1) that aborts
# just that expansion's command; run it isolated so the script continues.
( echo "[${a[@]:1:-3}]" ) 2>/dev/null; echo "arr_neg_len=$?"

# Positional parameters slice the same way ($0 is index 0).
set -- w x y z
echo "pos -2 -> (${@: -2})"
echo "pos -9 -> (${@: -9})"

# A STRING slice, in contrast, DOES allow a negative length (drop from the end).
s=hello
echo "str: [${s:1:-2}]"
echo "str neg off: [${s: -3}]"
