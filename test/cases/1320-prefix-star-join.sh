# "${!prefix*}" and "${!arr[*]}" join their matches on IFS[0] (like $*), while
# the @ forms join on a space; a following literal is not word-split.
IFS=x
axb=1
axc=2
axd=3
echo "star: ${!ax*}"
echo "star-suffix: ${!ax*}x"
echo "at: ${!ax@}"

a=(9 8 7)
echo "idx-star: ${!a[*]}"
echo "idx-at: ${!a[@]}"
echo "val-star: ${a[*]}"

# With the default IFS, the star form joins on a space.
unset IFS
echo "default: ${!ax*}"
