# In an arithmetic text with expansions, bash 5.2 expands each subscript as an unquoted word
# and quotes the result again (expand_array_subscript): `a[$\A]` reads `$A` — the backslash
# removed — while the top level keeps `$\A`. curse kept `$\A` in the subscript (fuzz F75).
e() { eval "$1"; echo "st $?"; }
e 'echo $[a[$\A]]'
e 'echo $(( a[$\A] ))'
e 'echo $(( $\A ))'
e 'echo $(( a[x$\A] ))'
e 'echo $(( a[$\$] ))'
e 'echo $(( a[$\\] ))'
e 'echo $(( a[$\A$\B] ))'
e 'x=1; a=(5 6); echo $(( a[$x] + a[\$x] ))'
e '(( a[$\A] ))'
i=0; while [ $i -lt 150 ]; do ( echo $(( a[$\Q] )) ); i=$((i + 1)); done 2>&1 | sort | uniq -c
