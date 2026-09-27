# An error in a file sourced from inside a function is labelled with the SOURCED
# file's name (error.c's error_prolog: BASH_SOURCE[0]), whichever tier runs the
# function — not the name of the file that defined the function.
exec 2>&1
d=${TMPDIR:-/tmp}/srcerr.$$
mkdir -p "$d"
printf 'echo "in-src $LINENO"\nnosuch_cmd_q\n((1/0))\n' > "$d/inc.sh"
g() { . "$d/inc.sh"; echo "after ${FUNCNAME[0]}"; }
f() { source "$d/inc.sh"; }
g 2>&1 | sed "s|$d/||"
f 2>&1 | sed "s|$d/||"
n=0
for i in $(seq 200); do g >"$d/out" 2>&1; n=$((n+1)); done
sed "s|$d/||" "$d/out"; echo "n=$n"
h() { local j; for ((j=0; j<160; j++)); do . "$d/inc.sh"; done >"$d/out2" 2>&1; tail -2 "$d/out2" | sed "s|$d/||"; }
h
eval 'g' 2>&1 | sed "s|$d/||"
rm -rf "$d"
