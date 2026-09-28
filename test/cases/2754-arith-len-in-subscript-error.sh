# A ${#name} inside an arithmetic subscript stays as written: bash's error shows the text
# expanded (`< 0 `). The compiled tier read ${#name} in arithmetic natively through a
# reserved name and re-read the subscript with that name in it: `< __curse_len_a ` (fuzz F68).
a=(1 2 3); x=(5 6 7 8); v=1
echo $(( x[ $v < ${#a} ] + ${#a} )) $(( ${#a} * x[${#a}] ))
e() { eval "$1"; echo "st $?"; }
v=
e 'echo $(( x[ $v < ${#a} ] ))'
f() { echo $(( x[ $v < ${#a} ] )); }; f; echo "function $?"
i=0; while [ $i -lt 150 ]; do ( echo $(( x[ $v < ${#a} ] )) ); i=$((i + 1)); done 2>&1 | sort | uniq -c
