# $'...' ANSI-C quoting is recognized inside a ${x:-word} default operand even
# when the whole expansion is double-quoted (a bash quirk); a plain "$'...'"
# string stays literal.
x=

echo "quoted default: [${x:-$'\t'}]" | cat -A
echo "unquoted default: [${x:-$'AB'}]"
echo "plain dq string: [$'\t']" | cat -A

y=set
echo "set value ignores default: [${y:-$'\t'}]"
