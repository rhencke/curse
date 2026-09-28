# A here-document opened inside <( … ) / >( … ) whose `)` ends the line reads its body from
# the following lines, as one inside $( … ) does — bash warns "command substitution: 1
# unterminated here-document" (fuzz F47). curse read them as commands. The warning for a
# second here-document starts at the line its own reading began.
cat <(cat <<EOF)
body
EOF
echo after
cat <(cat <<A) <(cat <<B)
a1
A
b1
B
x=$(cat <<EOF)
dollar
EOF
echo "[$x]"
eval 'cat <(cat <<E)
in eval
E'
f() { cat <(cat <<F)
in function
F
}; f
printf 'cat <(cat <<S)\nsourced\nS\n' > s2746.sh; . ./s2746.sh
trap 'cat <(cat <<T)
in trap
T' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do cat <(cat <<L)
$i
L
i=$((i + 1)); done | tail -1
eval 'cat <<A <<B
a
b'
rm -f s2746.sh
