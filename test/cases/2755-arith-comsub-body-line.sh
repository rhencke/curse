# A $(…) / `…` inside an arithmetic text ([[ … -gt … ]] operands, (( )), $((…))) numbers its
# body's lines from the command's line. The compiled tier keeps no current line per command,
# so the body took the line an earlier command left: `line 1` for a command on line 2 (fuzz F76).
(( 1 ))
[[ ( `export -f b[]=` -gt 1 ) ]]
(( 1 ))
[[ `export -f c[]=` -gt 1 ]]
(( 1 ))
[[ ( $(export -f d[]=) -gt 1 ) ]]
(( 1 ))
(( `export -f e[]=` + 1 ))
(( 1 ))
echo $(( $(export -f g[]=) 1 ))
f() {
  (( 1 ))
  [[ `export -f h[]=` -lt 1 ]]
}
f; f
i=0; while [ $i -lt 150 ]; do (( i++ ))
[[ `export -f j[]=` -eq 1 ]]; done 2>&1 | sort | uniq -c
