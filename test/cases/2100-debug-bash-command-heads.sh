# $BASH_COMMAND in a DEBUG trap at a compound command's head reads as bash prints that head:
# `for j in 1 2` (each iteration), `((k<2))` per arithmetic-for slot, `select …` once, `case w in `.
trap 'echo "D:$BASH_COMMAND"' DEBUG
for j in 1 2; do x=$j; : $x; done
for ((k=0;k<2;k++)); do :; done
select s in a; do break; done <<< 1 2>/dev/null
case a in a) true;; esac
while false; do :; done
if true; then :; fi
[[ a ]]
(( 1 ))
trap - DEBUG
