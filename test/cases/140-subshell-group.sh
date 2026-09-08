x=outer
( x=inner; echo "in subshell: $x" )
echo "after subshell: $x"
{ echo grouped1; echo grouped2; }
y=1
{ y=2; }
echo "y=$y"
