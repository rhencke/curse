# Pinned bash behaviour: $FUNCNEST counts every call, a one-line function's too — called
# from another function past the limit it fails, and bash abandons the rest of that
# top-level command. (curse's compiled tier had spliced such a small body into its caller,
# skipping the count.)
FUNCNEST=1
f() { x=$((x + 1)); }
g() { f; }
for ((i = 0; i < 150; i++)); do f; done
echo "x=$x"
g; echo "g $?"
echo "after x=$x"
h() { g; }
FUNCNEST=2
for ((i = 0; i < 150; i++)); do g; done
echo "x=$x"
h; echo "h $?"
echo "end x=$x"
