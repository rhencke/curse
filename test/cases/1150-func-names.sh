# bash accepts almost any word as a function name in the `name () { … }` form,
# not just POSIX identifiers.

# hyphens
list-things() { echo "listing $1"; }
list-things files

# dots (namespaced helpers)
pkg.install() { echo "install $*"; }
pkg.install curl wget

# mixed punctuation
_x-y+z() { echo weird; }
_x-y+z

# leading colon
:noop() { echo ":noop ran"; }
:noop

# a hyphenated function can be redefined and called again
list-things() { echo "v2 $1"; }
list-things data

# empty and non-empty array assignments must NOT be misread as functions
a=()
echo "empty=${#a[@]}"
b=(one two three)
echo "b=${b[*]} n=${#b[@]}"
c+=(x)
echo "c=${c[*]}"

# a normal identifier function still works
plain() { echo plain; }
plain
