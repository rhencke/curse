# ${#s} length is a locale lens: code points in a UTF-8 locale (the default in
# this environment), bytes in C/POSIX. Astral characters count as one.

s=hello
echo "ascii=${#s}"

s=héllo           # é is one code point, two UTF-8 bytes
echo "bmp=${#s}"

s=😀😀            # astral: two code points, four UTF-8 bytes each
echo "astral=${#s}"

# In the C locale, ${#} counts bytes.
export LC_ALL=C
s=héllo
echo "c_bytes=${#s}"
s=😀
echo "c_astral_bytes=${#s}"

# Switching back to a UTF-8 locale restores character counting mid-script.
export LC_ALL=C.UTF-8
echo "back=${#s}"
