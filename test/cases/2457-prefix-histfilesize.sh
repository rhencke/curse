# HISTFILESIZE as a command's prefix binding still truncates $HISTFILE (sv_histsize runs
# as it binds).
HISTFILE=$PWD/hist.txt
printf '1\n2\n3\n4\n' > "$HISTFILE"
HISTFILESIZE=2 true
cat "$HISTFILE"
rm -f "$HISTFILE"
