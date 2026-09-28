# A here-document opened in a $( … ) whose delimiter word runs to the end of the text (a
# quote closed only by the last `"`), or opened in a $( … ) inside a ${ … }: bash warns
# "here-document at line N delimited by end-of-file" as it reads the word, before the
# missing `)`. curse gave only the `)` error, or no warning at all (leftovers M4).
e() { eval "$1"; echo "st $?"; }
e 'echo "$(cat <<"E
x
)"'
e 'echo "${M=$(cat <<"E
x
)}"'
e 'echo "$(cat <<E"
x
)"'
e 'echo "$(cat <<E
x
)"'
e 'x="$(cat <<"E"
x
E
)"; echo "$x"'
x="${M=$(cat <<E
x
E)}"; echo "[$x]"
y=${N=$(cat <<E
y
E)}; echo "[$y]"
f() { z=${Q=$(cat <<E
q
E)}; echo "[$z]"; }
f
i=0; while [ $i -lt 150 ]; do unset M; e 'echo "${M=$(cat <<"E
x
)}"'; i=$((i + 1)); done 2>&1 | sort | uniq -c
