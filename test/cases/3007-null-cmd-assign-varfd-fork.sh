# A null command with a prefix assignment and a {v} redirection: bash's execute_null_command
# forks for the {v} one — the child does the redirections and exits, so v is never set —
# and the assignment stays (fuzz leftover M5; the compiled tier set v).
x=1 {v}>/dev/null; echo "x=$x v=${v-unset} st=$?"
y=$(echo 2) {w}>/dev/null; echo "y=$y w=${w-unset} st=$?"
q=4 {u}</nonexistent_m5; echo "q=$q u=${u-unset} st=$?"
z=3 0</dev/null; echo "z=$z st=$?"
f() { a=5 {k}>/dev/null; echo "a=$a k=${k-unset}"; }; f
eval 'b=6 {k2}>/dev/null'; echo "b=$b k2=${k2-unset}"
i=0; while [ $i -lt 150 ]; do n=$i {fd}>/dev/null; i=$((i + 1)); done; echo "n=$n fd=${fd-unset}"
