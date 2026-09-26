# Multibyte IFS bytes and QUOTED text (bash subst.c): a word bash word-splits is scanned
# as one CTLESC-marked string. quote_string puts ONE CTLESC before a whole multibyte char,
# but string_extract_verbatim skips just CTLESC and the next byte (`i += 2`), so the
# char's later bytes are tested alone (MEMBER): one that is an IFS byte delimits.
# The lone word "$@" is bash's shortcut (never split); "${@}", "${a[@]}" & co. are not.
export LC_ALL=C.UTF-8
p() { printf '%s:' "$1"; shift; printf '<%s>' "$@" | od -An -tx1 | tr -d '\n'; echo; }
x=a; e=é; q=(aéb cé); set -- aéb cé
IFS=$'\xa9'
p 1 $x"é"; p 2 "$x"é; p 3 $x'é'; p 4 $x$'\xc3\xa9'; p 5 "$@"; p 6 "$@x"; p 7 x"$@"
p 8 "${q[@]}"; p 9 $x"$e"; p 10 "$e"; p 11 "$*"; p 12 "${q[*]}"; p 13 $@
p 14 "é$@"; p 15 "${@}"; p 16 é"${q[@]}"; p 17 \é$x; p 18 "${q[@]:0}"; p 19 "${@/a/z}"
p 20 "${q[@]^^}"; p 21 "${q[@]#a}"; p 22 "${@:1}"; p 23 ${x:+"é"}; p 24 "é"$((1))
p 25 "é"$(echo a); p 26 "${q[*]}"$x
for i in "$@"; do p f1 "$i"; done
for i in "${q[@]}"; do p f2 "$i"; done
a=("$@"); p a1 "${a[@]}"
a=("é"$x); p a2 "${a[@]}"
f() { p fn "$@"; }; f "$@"; f "${@}"
IFS=é
p i1 é$x; p i2 "$@"; p i3 "${@}"; p i4 $x"à"; p i5 "é"; p i6 $x"é"
# an exposed byte ending a quoted "…$@…" segment delimits no trailing field (bash splits
# the segment alone first): what follows joins the field before it
set -- a é; y=Y
p s1 "$@"$e; p s2 ${y:+"$@"}$e; p s3 ${y:+"$@"}b; p s4 "${@}"b
# a has_dollar_at word splits UNstripped: its leading IFS whitespace is a delimiter of its
# own, taking one non-whitespace IFS char with it (no empty first field)
IFS=': '; x=' :a'; set -- z; e=()
p h1 $x; p h2 $x"$@"; p h3 $x$@; p h4 $x"${e[@]}"; p h5 $x$*; p h6 $x${*}; p h7 $x"$*"
p h8 $x${q[*]}; p h9 $x"${q[*]}"; p h10 $x${!q[*]}; p h11 $x${!q[@]}; p h12 $x${y:-$@}
p h13 $x${u:-$@}; p h14 $x${e[@]:-w}; p h15 $x${q[@]:-w}; p h16 $x${q[@]:+w}; p h17 $x${e[@]:+w}
unset IFS
# the same in hot code
g() { IFS=$'\xa9'; set -- $1; printf '<%s>' "${@}"; unset IFS; }
for ((i = 0; i < 200; i++)); do r=$(g 'aéb'); n=$((n + ${#r})); done; echo "$r" $n | od -An -tx1
