# Redirects now parse after an arithmetic command and an array assignment, and a
# standalone array assignment reports the right status (0, or 1 to a readonly).

# Trailing redirect on (( )) and on an array append parses and applies.
(( 1 / 0 )) 2>/dev/null; echo "arith_err=$?"
(( 5 > 3 )) 2>/dev/null; echo "arith_ok=$?"
a=(1); a+=(2 3) 2>/dev/null; echo "append=${a[*]}"

# A fresh array assignment resets $? to 0.
false
b=(x y z)
echo "fresh=$?"

# Assigning to a readonly array (set or append) fails with status 1, value kept.
# (Kept on separate lines: a readonly-assignment error aborts the rest of its
# ;-list in bash, which curse does not replicate.)
declare -ar r=(10 20)
r+=(30)
echo "ro_append=${r[*]} $?"
r=(99)
echo "ro_set=${r[*]} $?"

# A readonly associative-array element too.
declare -Ar m=([k]=1)
m[k]=2
echo "ro_elem=${m[k]} $?"
echo done
