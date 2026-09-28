# A `for`/`select` loop variable that is one of bash's own readonly variables (UID, EUID,
# PPID): each round's assignment fails (`UID: readonly variable`), the body still runs and
# the variable keeps its value; a `for ((UID = …))` init fails and the loop runs no round.
# The compiled tier knew only the program's own `readonly` names and silently overwrote
# UID with the loop word (fuzz F119).
old=$UID
for UID in a b
do
    :
done
echo "UID same: $([ "$UID" = "$old" ] && echo yes || echo no)"
for EUID in x; do echo "body ran: $?"; done
echo "EUID same: $([ "$EUID" = "$(id -u)" ] && echo yes || echo no)"
for ((UID = 0; UID < 3; UID++)); do echo never; done; echo "for (( )): $?"
for ((k = 0; k < 1; UID++)); do echo "one round"; done; echo "step: $?"
select UID in p; do break; done <<< 1 2> /dev/null; echo "select same: $([ "$UID" = "$old" ] && echo yes)"
f() { for UID in q; do :; done; echo "in f: $([ "$UID" = "$old" ] && echo yes)"; }
f
eval 'for UID in r; do :; done'; echo "eval same: $([ "$UID" = "$old" ] && echo yes)"
trap 'for UID in t; do :; done; echo "trap same: $([ "$UID" = "$old" ] && echo yes)"' USR1
kill -USR1 $$
n=0
for ((r = 0; r < 160; r++)); do
    for UID in "$r"; do n=$((n + 1)); done 2> /dev/null
done
echo "rounds $n, UID same: $([ "$UID" = "$old" ] && echo yes || echo no)"
