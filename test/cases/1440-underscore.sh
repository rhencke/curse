# $_ holds the last argument of the previous simple command (or the command name
# if it had none); a pure assignment clears it; inside a function it starts as
# the caller's previous value and the call's own arg lands after it returns.

echo one two three
echo "last=[$_]"

: single
echo "colon=[$_]"

: 'foo'"bar"          # concatenated last arg
echo "concat=[$_]"

s=bar                 # a pure assignment clears $_
echo "assign=[$_]"

echo marker
f() { echo "in=[$_]"; }
f theArg
echo "after=[$_]"

# ${_} form works too.
echo abc def
echo "braced=[${_}]"
