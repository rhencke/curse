# `test`/`[` integer comparisons parse plain signed decimal (bash's legal_number),
# NOT arithmetic: a leading 0 stays decimal (no octal/hex), and a non-integer is
# an error (status 2). Arithmetic `$(( ))` is the opposite — a leading 0 IS octal,
# so a bad octal digit is a fatal error that aborts just that command (status 1)
# and the script keeps going.

# Plain decimal, sign, and surrounding whitespace are accepted.
[ 5 -eq 5 ] && echo eq
[ +5 -eq 5 ] && echo plus
[ -3 -lt -2 ] && echo neg
[ " 7 " -eq 7 ] && echo spaced

# A leading zero is decimal here (not octal): 010 == 10, and 08/09 are valid.
[ 010 -eq 10 ] && echo dec010
[ 08 -eq 8 ] && echo dec08
[ 09 -gt 8 ] && echo dec09

# 64-bit range compares exactly (beyond 32- and 53-bit).
[ 4294967296 -gt 4294967295 ] && echo wide32
[ 9223372036854775807 -gt 9223372036854775806 ] && echo wide64

# Non-integers and arithmetic expressions are errors (status 2), not evaluated.
[ a -eq b ] 2>/dev/null; echo "aeqb=$?"
[ 1+2 -eq 3 ] 2>/dev/null; echo "recur=$?"
[ 0x10 -eq 16 ] 2>/dev/null; echo "hex=$?"

# `test -o optname` reports a `set -o` option; an unknown name is just false.
[ -o nounset ]; echo "nounset=$?"
set -o nounset
[ -o nounset ]; echo "nounset2=$?"
set +o nounset
[ -o bogusopt ]; echo "bogus=$?"

# Arithmetic DOES do octal — a bad octal digit aborts the command (status 1),
# then the script continues to the next command.
echo $(( 010 ))
echo $(( 0x1f ))
echo "before"
echo $(( 083 )) 2>/dev/null
echo "after=$?"
x=$(( 5 / 0 )) 2>/dev/null
echo "div=$?"
echo "done"
