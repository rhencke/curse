# Hot functions whose bodies are interp ASTs (redefined, defined in a subshell) compile
# standalone from their definition text: $LINENO, FUNCNAME, errors keep their lines.
td=${TMPDIR:-/tmp}/curse-2070.$$; mkdir -p "$td"
printf 'add() {\n\tlocal a=$1\n\tr=$((r + a))\n\t[ $a = 250 ] && echo "line $LINENO in ${FUNCNAME[0]}"\n\treturn 0\n}\n' > "$td/lib.inc"
. "$td/lib.inc"
r=0
for i in {1..300}; do add $i; done
echo r=$r
eval 'mul() { m=$((m * 2)); (( m > 1000000 )) && return 3; : ${nope:-}; }'
m=1; for i in {1..150}; do mul || { echo "mul=$? m=$m"; m=1; }; done
g() { echo one; }
g() { c=$((c+1)); }
for i in {1..200}; do g; done; echo c=$c
( h() { d=$((d+1)); }; for i in {1..200}; do h; done; echo d=$d )
k() { local x; x=$1; if [ $x -eq 150 ]; then echo "k $x ${undef:?boom}"; fi; }
for i in {1..160}; do k $i; done 2>&1 | sed 's/^.*line/line/'
rm -rf "$td"
