# A trap handler's $( … ) numbers its lines from the handler's own line, as $LINENO in the
# handler does (a signal trap counts from 1; DEBUG/ERR/RETURN keep the trapped line) — in
# every tier (leftover L17).
echo one
trap 'echo "h $LINENO $(echo $LINENO)"
echo "$(
echo $LINENO)"' USR1
kill -USR1 $$
f() { kill -USR1 $$; }
f
trap 'echo "d $LINENO $(echo $LINENO)"' DEBUG
:
trap - DEBUG
trap 'echo "e $LINENO $(echo $LINENO)
$(echo $LINENO)"' ERR
false
trap - ERR
g() { trap 'echo "r $LINENO $(echo $LINENO)"' RETURN; :; }
g
trap - RETURN
trap 'echo "x $LINENO $(echo $LINENO)"' EXIT
i=0; trap 'echo "u $LINENO $(echo $LINENO)"' USR2; while [ $i -lt 150 ]; do [ $i = 120 ] && kill -USR2 $$; i=$((i+1)); done
eval 'trap '"'"'echo "v $LINENO $(echo $LINENO)"'"'"' USR1; kill -USR1 $$'
printf 'trap '"'"'echo "s $LINENO $(echo $LINENO)"'"'"' USR1\nkill -USR1 $$\n' > s2816.sh; . ./s2816.sh; rm -f s2816.sh
