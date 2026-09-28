# An array subscript in arithmetic runs to its `]` as skipsubscript reads it — '…', "…",
# `…`, $( … ), ${ … } nest — so `a["]` or `a[$(]` in a variable's value never closes: "bad
# array subscript" naming the rest of the text (leftover L9). (`let` used to crash on it.)
x='a[$(]'; echo $((x)); echo "st $?"
x='a["]'; echo $((x)); echo "st $?"
x='a[1'; echo $((x)); echo "st $?"
a=(3 4 5); x='a[$(echo 1)]'; echo $((x)); x='a["1"]'; echo $((x)) 2>&1; echo "st $?"
let 'y=a[$(]'; echo "st $?"
let 'y=a["]'; echo "st $?"
f() { local v='a[$(]'; echo $(( v + 1 )); echo "f $?"; }; f; echo "st $?"
eval 'x="a[\"]"; (( x )); echo "e $?"'; echo "eval $?"
printf 'x=a[\\"]; echo $((x))\necho "src $?"\n' > s2808.sh; . ./s2808.sh
trap 'x="a[\$(]"; echo $((x)); echo no' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do x='a[$(]'; y=$((x)); i=$((i + 1)); done 2>&1 | sort | uniq -c
y=0; for i in {1..150}; do x='a[i%3]'; y=$((y + x)); done; echo "$y"
rm -f s2808.sh
