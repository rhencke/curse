# A here-document delimiter in a $( … ) whose quote never closes is the substitution's
# syntax error: "unexpected EOF while looking for matching `"'" at the quote's line, as
# parse_comsub reads the word. curse took the quote to the end and reported a missing `)`
# at the last line (fuzz F81).
e() { eval "$1"; echo "st $?"; }
e 'echo ${M=$(cat <<"\"
x
\
)}'
e 'echo ${M=$(cat <<"E
x
)}
echo after'
e 'echo $(cat <<"E
x
)'
e 'echo $(cat <<E"
x
)'
e "x=\$(cat <<'E
y
)"
i=0; while [ $i -lt 150 ]; do e 'y=$(cat <<"Q
)'; i=$((i + 1)); done 2>&1 | sort | uniq -c
