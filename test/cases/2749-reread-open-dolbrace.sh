# Text the parser keeps raw and re-reads at expansion time — an arithmetic text's ${…}, a
# ${x/PAT/REP}'s pattern — can hold a ${ that never closes. bash reports it when the word
# expands: "TEXT: bad substitution" (the name runs to the end), "bad substitution: no
# closing `}' in TEXT" (after an operator), and a `/` inside a nested ${…}/$(…)/`…` never
# splits PAT from REP (skip_to_delim), so `${x/${/}}` is the pattern `${/}`. And
# `A=$((()))$(())` is not one $((…)): the `))` at its end closes the second. Each escaped
# as a Lua parse error (fuzz F53, F54, F55). Inside $((…)) only a $( nests (P_ARITH): a
# ${ there is text, so `$(( ${ ))` reads and fails when it expands.
x=a
e() { eval "$1"; echo "st $?"; }
e 'A=$((()))$(()); echo "A=$A"'
e 'echo $[${]'
e 'A=$[${]'
e 'echo ${x/${/}}'
e 'echo "${x/${/}}"'
e 'echo ${x//${/}/b} ${x/$(echo /)/c} ${x/`echo /`/d} ${x/${x/a/}/e}'
e 'echo $[1+${x:-]'
e 'echo $[1 + ${#]'
e 'echo $[1 + ${#x]'
e 'echo $(( 2 + ${x}${ ))'
e '(( ${ ))'
e 'echo $[${a$(echo })]'
e 'echo $(( 1 + ${x:-4} )) $(( ${x:-")"} + 1 ))'
A=$((()))$(()); echo "top $?"
echo "top2 $?"
printf 'echo ${x/${/}}\necho after\nA=$((()))$(())\n' > s2749.sh
. ./s2749.sh; echo "source $?"
f() { echo $[1+${x/]; echo no; }; f; echo "function $?"
trap 'echo ${x/${/}}; echo "trap $?"' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do
  (echo $[${x]); (A=$((()))$(())); (echo "${x/${/}/z}"); echo "$? ${x/${x}/y}"
  i=$((i + 1))
done 2>&1 | sort | uniq -c  # (in a loop an expansion error abandons the loop: each runs in ( ))
rm -f s2749.sh
