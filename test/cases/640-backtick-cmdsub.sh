# backtick command substitution
echo `echo hi`
x=`echo world`
echo "x=$x"
echo "in dquotes: `echo nested`"
echo `printf 'a\nb\nc\n' | wc -l | tr -d ' '`

files=`echo one two three`
echo "files=$files"

# backtick honoring $ and nested $()
v=inner
echo "`echo $v and $(echo sub)`"

# command-substitution exit status flows to $? on a pure assignment
x=$(exit 7)
echo "assign exit7: $?"
y=$(true)
echo "assign true: $?"
z=5
echo "assign plain: $?"
w=`false`
echo "assign backtick-false: $?"

# a plain assignment with no command sub resets $? to 0
false
plain=1
echo "reset: $?"
