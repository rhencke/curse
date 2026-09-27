# A here-document in $(…) whose delimiter line is `DELIM  )`: bash 5.2 ends the body at
# that line (parse_comsub reads the `)` as the substitution's end; the heredoc reader then
# sees `DELIM  ` — still warned as delimited by end-of-file). A backtick body has no such
# form: its last `DELIM  ` line is body text. The same text run again is compiled from its
# own text (a daemon worker keeps it for the next request) — it must be read the same way.
f() {
z=$(cat <<EOF
hey
EOF  )
echo "[$z]"
}
f 2>/dev/null; f 2>/dev/null; f 2>/dev/null
for ((i = 0; i < 200; i++)); do f; done 2>/dev/null | uniq -c
eval 'for ((i = 0; i < 3; i++)); do y=$(cat <<EOF
yo
EOF  ); echo "[$y]"; done' 2>/dev/null
for i in 1 2 3; do x=`cat <<EOF
hi
EOF  `; echo "[$x]"; done 2>/dev/null
