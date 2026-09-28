# A here-document body is expanded as it is read, left to right: a $[ or `…` it never closes
# is "bad substitution: no closing `]' / "`" in TEXT" (the rest of the body), and an open $(
# is the substitution's syntax error, reported at the line the body ends on — after what
# precedes it ran. A DISCARD that sets no status of its own leaves a non-zero one (127 from
# a command not found before it). curse evaluated `$[a[…` as arithmetic, ran an open `…`,
# and failed an open $( before expanding anything (fuzz F70, F83).
x=$(cat <<EOF
$[a[
EOF
)
echo "st $? [$x]"
cat <<EOF
abc $[a[
def
EOF
echo "st $?"
cat <<EOF
ab `echo
EOF
echo "bq $?"
cat <<F
$(nosuch)$(
F
echo "cs $?"
echo a
cat <<F
x $(echo hi >&2)$(
y
F
echo "cs2 $?"
f() { cat <<F
$(false)$[1+
F
echo "f $?"; }; f
i=0; while [ $i -lt 150 ]; do cat <<F
$[a[ $(
F
i=$((i + 1)); done 2>&1 | sort | uniq -c
