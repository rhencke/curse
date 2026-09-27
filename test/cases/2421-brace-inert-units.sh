# Brace expansion copies whole the units its syntax is inert inside (braces.c
# brace_gobbler): a `\` escape, '…', "…" (whose `\"` doesn't close it and whose $( … )
# nests), `…`, ${…} and $( … )/<( … )/>( … ) — read by the same scanners as the word.
echo "x\"{a,b}"y
echo $(echo ")")x{a,b}
echo {a,$(echo b,c)}
echo {a,"b,c"}d
echo x{a,`echo p,q`}
echo "${u:-"a{b,c}"}"
echo ${u:-"}"}{x,y}
echo ${u:-{b,c}}
echo "${u:-"a{b,c}"}" "x{1,2}"'{3,4}'
echo {a,'b,c'}"$(echo ')')"{d,e}
a=( {x,y}"$(echo "}")" ); echo "${a[@]}"
echo ${u-$'x{a,b}'}{c,d}
echo {1..3}"$(echo x)"
echo "a\\"{1,2}
echo 'a\'{1,2}
( echo $((1+{2,3}))x ) 2>/dev/null || echo arith-err
echo {p,q}$((1+1))
echo <(:){a,b} | sed 's/[0-9][0-9]*/N/g'
v='{a,b}'; echo $v "$v"
echo "$(echo "(" ; (echo q))"
echo "$((1+2))" "$( (echo sub) )"
for (( i=0; i<2; i++ )); do echo "i=$i"; done
for (( i=$(echo 0); i<"2"; i++ )); do echo "j=$i"; done
for (( i=0; i<${#v}; i+=3 )); do echo "k=$i"; done
