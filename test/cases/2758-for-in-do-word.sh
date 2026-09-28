# In `for NAME in WORDS`, only a `;` or a newline ends the list: a `do` there is one of the
# words, so `for i in a do :; done` is a syntax error at `done` (select too). curse took the
# `do` as the loop's keyword and ran it (fuzz F57).
e() { eval "$1"; echo "st $?"; }
e 'for i in a do :; done'
e 'select S in a do :; done'
e 'for i in a b do; do echo $i; done'
e 'for i in do; do echo $i; done'
e 'for i in a do
do echo $i; done'
e 'for i in a
do echo $i; done'
printf 'for i in x do :; done\necho no\n' > s2758.sh; . ./s2758.sh; echo "source $?"
f() { for i in 1 2 do; do echo "f$i"; done; }; f
j=0; while [ $j -lt 150 ]; do for w in do done in; do echo "$w"; done; j=$((j + 1)); done | sort | uniq -c
rm -f s2758.sh
