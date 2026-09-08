# eval runs a constructed command in the current shell
cmd="echo hello from eval"
eval "$cmd"

# eval reads and modifies current-shell variables
x=1
eval 'x=$((x + 10)); y=set-by-eval'
echo "x=$x y=$y"

# dynamic variable name
name=dynvar
eval "$name=computed"
echo "dynvar=$dynvar"

# return inside eval returns from the enclosing function
f() {
  eval 'for i in 1 2 3; do
    [[ $i -eq 2 ]] && return 42
    echo "loop $i"
  done'
  echo "not reached"
}
f
echo "f returned $?"

# break inside eval affects the enclosing loop
for n in a b c; do
  eval '[[ $n == b ]] && break'
  echo "n=$n"
done

# source runs a file in the current shell (shared scope + positional params)
d=$(mktemp -d)
cd "$d"
cat > lib.sh <<'LIB'
greet() { echo "hi $1 from $2"; }
libvar="loaded"
echo "sourced args: $1 $2"
LIB
source ./lib.sh alpha beta
echo "libvar=$libvar"
greet world lib

set -- outer1 outer2
source ./lib.sh inner1 inner2
echo "after source: $1 $2"

# . is the same as source
echo 'echo dotted' > d.sh
. ./d.sh

cd /
rm -rf "$d"
