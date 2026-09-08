# test / [ follow bash's argc-based grammar: an operator name can be an operand,
# and -a/-o bind as AND/OR only where the grammar expects an operator.

# `-o` here is the value of $1 (an operand), not the OR operator
set -- -o
test $# -ne 0 -a "$1" != "--"; echo "a=$?"
test $# -ne 0 -a -o != "--"; echo "b=$?"

# 3 args: `( = )` is an equality comparison, not a parenthesized string test
test '(' = ')'; echo "c=$?"
test '(' == ')'; echo "d=$?"
test 0 -eq 0 -a '(' = ')'; echo "e=$?"

# AND / OR precedence (-a binds tighter than -o)
test a = a -o b = c; echo "f=$?"
test a = b -o c = c; echo "g=$?"
test a = a -a b = b; echo "h=$?"
test a = a -a b = c; echo "i=$?"

# negation and parenthesized subexpressions
test ! '(' 1 -eq 2 ')'; echo "j=$?"
test '(' 1 -eq 1 ')' -a -n x; echo "k=$?"
test ! x = x; echo "l=$?"

# a lone operator name is just a non-empty string
[ -o ]; echo "m=$?"
[ = ]; echo "n=$?"
[ '' ]; echo "o=$?"

# unary file test still works
[ -e / ]; echo "p=$?"
[ ! -e /no/such/path ]; echo "q=$?"
