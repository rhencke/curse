# a command may begin with a redirection (redirection as a prefix)
d=$(mktemp -d); cd "$d"

# output redirect before the command word
>out echo "written first"
cat out

# here-doc as a command prefix
<<EOF tac
one
two
three
EOF

# input redirect prefix
printf 'a\nb\nc\n' > data
<data wc -l | tr -d ' '

# two here-docs on one command: the last one wins
<<EOF1 cat <<EOF2
first
EOF1
second
EOF2

# a prefix redirect mixed with an assignment
>out2 VAR=x printf 'assigned\n'
cat out2

cd /; rm -rf "$d"
