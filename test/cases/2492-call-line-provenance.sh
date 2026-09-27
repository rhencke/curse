# BASH_LINENO[0] is the line of the call, whichever tier makes it: a function the
# interpreter defined, called from compiled code after a tiered switch (or from a hot
# function compiled standalone), still pushes its call's line — not a stale one.
# A function imported from the environment is bash's: BASH_SOURCE "environment", its
# body numbered from line 0 (an error on line 0 carries no `line N:`), and a program
# calling it keeps the call stack it reads.
exec 2>&1
h() { r="${BASH_LINENO[*]}"; }
g() { h; }
for i in $(seq 200); do g; done; echo "A $r"
k() { ((1/0)); }
for i in $(seq 200); do k 2>/dev/null; done; k
w() { h; echo "W $r"; }; w
x() { local i; for ((i=0;i<200;i++)); do h; done; echo "X $r"; }
x
y() { (( $1 > 0 )) && y $(( $1 - 1 )) || { h; echo "Y $r"; }; }
y 3
z() { eval 'h'; echo "Z $r"; }; z
d=${TMPDIR:-/tmp}/imp.$$
mkdir -p "$d"
printf '\n\nm\nshopt -s extdebug; declare -F m\nn() {\n true | false; m\n}\nn\nfor i in $(seq 200); do n; done 2>&1 | sort | uniq -c\nq() { local i; for ((i=0;i<160;i++)); do m; done 2>&1 | tail -3; }; q\ne\n' > "$d/child.sh"
m() { echo "L=$LINENO S=${BASH_SOURCE[*]##*/} BL=${BASH_LINENO[*]} P=${PIPESTATUS[*]}"; nosuch_m; ((1/0)); echo "L2=$LINENO"; }
e() { nosuch_e; }
export -f m e
"$THIS_SH" "$d/child.sh" 2>&1
"$THIS_SH" -c 'm; e' 2>&1
rm -rf "$d"
