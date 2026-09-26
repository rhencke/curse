# The shared scanners under posix mode (a `'` in a double-quoted ${…} is ordinary; $( … )
# bodies alias-expanded as read), extglob case patterns with quoted | and ), and their
# declare -f text.
set -o posix
echo "${IFS+'bar} baz"
x="${u-'a}'}"; echo "$x"
alias e=echo
echo "$(e hi)" $(e ho) "a$(e 'x)')b"
case "$(e z)" in "$(e z)") echo m;; esac
set +o posix
shopt -s extglob
case ab in @(a|b)b|"x|y") echo eg;; esac
case 'x|y' in @(a|b)b|"x|y") echo eg2;; esac
f() { case $1 in @(a|"b)")|c) echo "f$1";; esac; }; f a; f 'b)'; f c; declare -f f
echo "$(echo $'a\'b')" "`echo "q"`"
