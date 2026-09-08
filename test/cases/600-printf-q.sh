# printf %q quotes a value for safe reuse as shell input
printf '[%q]\n' hello
printf '[%q]\n' "a b"
printf '[%q]\n' ""
printf '[%q]\n' "it's"
printf '[%q]\n' 'a$b`c\d'
printf '[%q]\n' "quote\"here"
printf '[%q]\n' "semi;pipe|amp&"
printf '[%q]\n' "star*q?br[x]"
printf '[%q]\n' /usr/local/bin
printf '[%q]\n' $'tab\tnl\nend'

# multiple args cycle the format
printf '%q\n' one two "th ree"

# capture with -v
printf -v qq '%q' "x y"
echo "qq=$qq"
