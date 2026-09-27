# $[ … ] is read like $(( )) (parse_matched_pair '[' ']' P_ARITH): quotes and backquotes
# nest, a $( … ) is a command substitution, and one left open is bash's EOF error for the
# innermost construct; a `$$` is one token, so `"$$(( }` is $$ then text. curse counted
# brackets only — `$[a `]` evaluated `a `` (fuzz F15), `$[$(` at EOF escaped as a raw Lua
# error (F2) — and read `$$((` as `$` then `$((` (F12). (As the word expands, bash's
# string_extract_double_quoted does take `$(` after `$$`: an open one there is a
# substitution's syntax error; and after a command's words, `((` is no arithmetic command.)
S=${THIS_SH:-bash}
t() { "$S" -c "$1" 2>&1 | sed 's/^[^:]*: //'; echo "rc=${PIPESTATUS[0]}"; }
echo $[1+2] "$[3*4]" $[ $(echo 5) + 1 ] $[ "2" + 1 ] $[ (2+3)*2 ]
a=(7 8); echo $[a[1]+1] "x$[ ${#a[@]} ]y" $[ $[1+1] * 3 ] $[ a[$[0]] ]
x="$$(( 1 ))"; [ "$x" = "$$(( 1 ))" ] && echo same
y="${x:+$$}"; [ "$y" = "$$" ] && echo pid
echo $[ `echo 4` + 1 ] "$[ `echo 6` ]"
eval 'echo $[ "]" ]'; echo "eval st=$?"
eval 'echo $[ 1 + ]"'; echo "eval st=$?"
f() { echo $[ $1 * 2 ]; }; f 21
trap 'echo trap $[ "4" * 2 ]' USR1; kill -USR1 $$
s=0; for ((i = 0; i < 200; i++)); do s=$[ s + "1" ]; done; echo "loop $s"
t 'echo $[a `]'
t 'echo $[a "]'
t "echo \$[a ']"
t 'echo $[$('
t '$[$('
t 'echo "$$(( }'
t 'echo $[ 1 + 2'
t 'echo $[ ( ]'
t 'echo $$(( 1 + 1 )); echo $$(echo x)'
t 'echo a ((1))'
t 'x=1 ((1))'
echo "$$(x"; echo "not reached"
echo "st=$?"
z="a$$(echo x)b"; [ "$z" = "a$$(echo x)b" ] && echo "extracted ${#z}"
printf 'echo $[ 2 * "3" ]\necho $[ 1 + `\n' > src2701.sh; . ./src2701.sh; echo "source st=$?"; rm -f src2701.sh
