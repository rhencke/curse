# A here-document's $( … ) is parsed as the body expands, over the rest of the body: a
# syntax error in it is `command substitution: line N:` with N = the command's line + 1 +
# the lines the substitution read, showing that line of the rest of the body (with its
# `)`), and fails the command (status 1) — an unclosed one reads to the end of the body.
# Same line in every tier (leftover L7).
echo start
cat <<E
a
b $( if
c
E
echo "st $?"
cat <<E
x
$(echo a; fi; echo b)
E
echo "st $?"
cat <<E
$(
fi)
E
echo "st $?"
f() {
	cat <<E
one
two $(fi)
E
	echo "f $?"
}
f
eval 'cat <<E
$(fi) z
E
echo "eval $?"'
printf 'cat <<E\n\n$( if\n\nE\necho "src $?"\n' > s2905.sh; . ./s2905.sh
trap 'cat <<E
$(fi)
E
echo "trap $?"' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do cat <<E; i=$((i + 1)); done 2>&1 | sort | uniq -c
$(fi)
E
rm -f s2905.sh
