# Pinned bash behaviour: in "…", a ${NAME-WORD} (- = ? + and their : forms) translates a
# $'…' in WORD as the line is read (parse_matched_pair: ansiexpand), and a NUL it yields
# ends the word's C string — so the word is cut there and expanding it is `bad
# substitution: no closing `}'` (status 1, the rest of the line abandoned). Unquoted, in a
# pattern operator (#), or in a here-document, the $'…' stays and just ends at its NUL.
exec 2>&1
echo a; echo "${u-$'r\0s'}"; echo b
echo "st $?"
echo ${u-$'r\0s'}; echo c
echo "[${u#$'r\0'}]"
x="a${u:+$'\x00'}"; echo never
echo "st $?"
cat <<E
${u-$'r\0s'}
E
f() { echo "${u-$'q\0'}"; echo f-never; }
g() { eval 'echo "${v=$'"'"'\c@'"'"'}"'; echo "g $?"; }
for ((i = 0; i < 200; i++)); do
	(f; echo f-line-never) 2>&1
	echo "f $?"
	(g) 2>&1
	echo "g $?"
done | sort | uniq -c
