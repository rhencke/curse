# A command substitution with no command in it — $(), $( ), ``, $(# comment) — runs no
# subshell in bash, so it is no substitution: an assignment's status is 0 (not the $?
# before it), and one after a real substitution keeps that one's status.
false; x=$(); echo $?
false; x=$( ); echo $?
false; x=``; echo $?
false; x=$(# c
); echo $?
false; y=$(true)$(); echo $?
false; echo $() $?
false; x=$(exit 3)$(); echo $?
false; x=$(exit 3)$( ); echo $?
false; $(); echo $?
false; x=1 $(); echo $?
false; a=($()); echo "$? ${#a[@]}"
false; a[1]=$(); echo $?
false; declare d=$(); echo $?
f() { false; x=$(); s=$?; false; x=$(exit 4)$(); echo "f$s g$?"; }
for ((i = 0; i < 160; i++)); do f; done | uniq -c
n=0
for ((i = 0; i < 160; i++)); do false; v=$(); [ $? = 0 ] && n=$((n + 1)); done
echo "n=$n"
