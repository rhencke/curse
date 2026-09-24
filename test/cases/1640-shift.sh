# shift, from bash's builtins/shift.def + get_numeric_arg/legal_number (common.c,
# general.c): an optional `--`; the count is strtoimax base 10 with surrounding
# blanks (`0x2`, `1e0`, overflow, '' are "numeric argument required"); a negative
# count is always "out of range"; past $# is status 1, reported only with
# shift_verbose or in posix mode; two operands are "too many arguments", which
# abandons the rest of the line.
p() { echo "$# [$*]"; }
e() { sed 's/^.*line [0-9]*: //'; }
set -- a b c d; shift --; p "$@"
set -- a b c d; shift -- 2; p "$@"
set -- a b c d; shift ' 2 '; echo "st=$? $#"
set -- a b c d; shift +2; echo "st=$? $#"
set -- a b c d; shift -0; echo "st=$? $#"
for bad in 0x2 1e0 2.0 '' -x 99999999999999999999 '2 x'; do
  set -- a b c d; shift "$bad" 2>&1 | e; shift "$bad" 2>/dev/null; echo "st=$? $#"
done
set -- a b c d; shift -1 2>&1 | e; shift -1 2>/dev/null; echo "st=$? $#"
set -- a b c d; shift 5 2>&1 | e; shift 5; echo "st=$? $#"
set -- a b c d; shift 4; echo "st=$? $# [$*]"
set --; shift; echo "st=$? $#"
shopt -s shift_verbose
set -- a b; shift 3 2>&1 | e; shift 3 2>/dev/null; echo "st=$? $#"
set --; shift 2>&1 | e
shopt -u shift_verbose
set -- a b c d; { shift 1 2; echo "same-cmd"; } 2>&1 | e; echo "after"
set -- a b c d; shift 1 2 2>/dev/null; echo "not reached"
echo "next line: $#"
f() { shift 2; echo "in f: $# [$*]"; }; set -- x y; f 1 2 3; echo "outer: $# [$*]"
set -- 1 2 3 4 5 6 7 8 9 10 11 12; shift 3; echo "$1 ${9} ${10}- $#"
set -- a "b c" d; shift; for x; do echo "<$x>"; done
( set -o posix; set -- a; shift 3 2>&1 | e; shift 3 2>/dev/null; echo "posix st=$?" )
