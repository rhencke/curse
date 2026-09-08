# type -t classifies names into one word
myfunc() { echo hi; }
type -t echo
type -t myfunc
type -t if
type -t while
type -t cat
type -t nosuch_xyz || echo "not found: $?"

# type descriptive (avoid plain `type funcname`: bash prints the body)
type echo
type if

# a function shadows the builtin; builtin/command reach past it
echo() { command echo "shadowed:" "$@"; }
echo hello
builtin echo direct
command echo viacommand

# command -v reports how a name resolves (name for func/builtin/keyword)
command -v echo
command -v myfunc
command -v if
command -v nosuch_xyz || echo "cv fail: $?"

# command -V is verbose (avoid functions: bash prints their body)
command -V printf
command -V if
