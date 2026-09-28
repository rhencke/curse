# A scalar is its own element 0: `s=42; $(( s[0] + 1 ))` is 43 and "${s[0]}" is 42 — also
# when the compiled tier would keep s in a native local (a function inlined into the main
# program): an element read goes through the shell's variables (leftover L2). Each program
# runs as its own script: eval/source/a trap anywhere in one disables that inlining.
S=${THIS_SH:-bash}
t() { printf '%s\n' "$1" > s2761.sh; "$S" s2761.sh; }
t 'f() { s=42; echo $(( s[0] + 1 )) $(( s[0] )) $(( s + 1 )); }; f'
t 'g() { t=42; echo "${t[0]}" ${#t[0]} $(( t[0] + 1 )); }; g'
t 'h() { u=7; echo "${u[@]}" "${u[*]}" $(( u[0] * 2 )); }; h'
t 'k() { v=$(( $1 + 1 )); w=$(( v[0] * 2 )); }
i=0; while [ $i -lt 150 ]; do k $i; i=$((i + 1)); done; echo "$v $w"'
t 'm=0; for ((n = 0; n < 150; n++)); do m=$((n + 1)); x=${m[0]}; done; echo "$m $x"'
t 'p() { q=$(( q + 1 )); }; q=0; while [ $q -lt 150 ]; do p; done; echo "$(( q[0] ))" "${q[0]}"'
eval 'e=5; echo $(( e[0] + 1 ))'
printf 'f() { s=42; echo $(( s[0] + 1 )); }; f\n' > s2761.sh; . ./s2761.sh
trap 'r=3; echo $(( r[0] * 2 ))' USR1; kill -USR1 $$; trap - USR1
rm -f s2761.sh
