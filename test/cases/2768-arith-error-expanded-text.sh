# bash expands an arithmetic text before it evaluates it, so its errors show the expanded
# text: `(( 2 % (i /= i[${#b}]) ))` fails as `2 % (i /= i[0])`. curse evaluated ${#b} and
# $name natively and showed the source text (fuzz F73).
b=
e() { eval "$1"; echo "st $?"; }
e '(( 2 % (i /= i[${#b}]) ))'
e '(( 2 / (i[${#b}]) ))'
e 'i=5; (( j = i / ${#b} ))'
e '(( ${#b} / 0 ))'
e '(( 2 ** -${#b}1 ))'
e '(( x[${#b}]++ , 1 / ${#b} ))'
e 'v=3; (( $v / 0 ))'
e 'echo $(( 1 / ${#b} ))'
f() { (( 7 % ${#b} )); echo "f $?"; }; f
k=0; while [ $k -lt 150 ]; do (( k++ )); (( 1 / ${#b} )); done 2>&1 | sort | uniq -c
