# let's text is already expanded: under assoc_expand_once an associative array's subscript
# runs to its FIRST `]`, quotes and brackets included (expr_skipsubscript's VA_NOEXPAND:
# `let "++a[80's]"` keys `80's`, `a[p[q]` keys `p[q`); any other subscript is read as
# skipsubscript reads it — an unclosed quote runs past every `]` (bad array subscript).
# (Guards the skipsubscript change for F102/F106.)
typeset -A a; b="80's"
shopt -s assoc_expand_once
let "++a[$b]"; declare -p a
let "++a[p[q]"; declare -p a
declare -a c; let "c[1'2]=1"; echo "st $?"
shopt -u assoc_expand_once
let "++a[$b]"; echo "st $?"; declare -p a
f() { shopt -s assoc_expand_once; let "++a[$1]"; shopt -u assoc_expand_once; let "++a[$1]"; }
f "$b"; declare -p a
eval 'shopt -s assoc_expand_once; let "a[e'"'"'v]=7"; shopt -u assoc_expand_once'; declare -p a
printf 'shopt -s assoc_expand_once; let "a[s]x]=1"; echo "src $?"; shopt -u assoc_expand_once\n' > s3047.sh; . ./s3047.sh
trap 'shopt -s assoc_expand_once; let "a[t'"'"']=2"; shopt -u assoc_expand_once' USR1; kill -USR1 $$; trap - USR1; declare -p a
i=0; while [ $i -lt 150 ]; do shopt -s assoc_expand_once; let "++a[$b]"; shopt -u assoc_expand_once; let "++a[$b]"; i=$((i + 1)); done 2>&1 | sort | uniq -c; declare -p a
rm -f s3047.sh
