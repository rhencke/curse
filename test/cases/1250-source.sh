# source (.) runs a file in the current shell: definitions propagate, the name
# may be dynamic, `return` returns from the source, positional args are passed.
d=$(mktemp -d)

cat > "$d/lib.sh" <<'LIB'
greet() { echo "hi $1"; }
LIBVAR=libval
echo "lib sees arg: $1"
return 0
echo "unreached in lib"
LIB

# static name, with an argument
. "$d/lib.sh" theArg
greet world
echo "LIBVAR=$LIBVAR ret=$?"

# a function defined in the sourced file is callable, and mutates our vars
inc() { COUNT=$((COUNT + 1)); }
COUNT=0
cat > "$d/inc.sh" <<'INC'
inc; inc; inc
INC
source "$d/inc.sh"
echo "COUNT=$COUNT"

# dynamic name resolves and runs the same way
name="$d/lib.sh"
. "$name" other
echo "dyn LIBVAR=$LIBVAR"

# `.` searches PATH-relative too, but an absolute/relative path is used as-is
echo done

rm -rf "$d"
