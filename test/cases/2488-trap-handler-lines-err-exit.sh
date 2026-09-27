# Trap handlers: $LINENO in a multi-line handler counts on from the trapped line — line k
# of the handler is the trapped line + k-1 (parse_and_execute numbers from it); for an
# asynchronous signal and the EXIT trap from 1. The ERR/DEBUG/RETURN/EXIT/signal handlers
# alike, interpreted (first run) and compiled (a recurring handler, hot loops). And
# `exit` in the ERR trap exits the shell with its status (_run_trap_internal).
trap 'echo "ERR a $LINENO"
echo "ERR b $LINENO"
echo "ERR c $LINENO"' ERR
false
set -T
trap 'echo "RET a $LINENO"
echo "RET b $LINENO"' RETURN
f() {
  return 1
}
f
trap - RETURN
trap 'echo "EXIT a $LINENO"
echo "EXIT b $LINENO"' EXIT
trap 'echo "USR1 a $LINENO"
echo "USR1 b $LINENO"' USR1
kill -USR1 $$
x=0
trap '[ $x = 1 ] && echo "DBG a $LINENO"
[ $x = 1 ] && echo "DBG b $LINENO"' DEBUG
x=1
trap - DEBUG
r=
trap 'r="$r $LINENO"
r="$r $LINENO"
r="$r $((LINENO))"' ERR
for ((i = 0; i < 200; i++)); do
	false
done
echo "$r" | tr ' ' '\n' | sort | uniq -c
r=
trap 'r="$r $LINENO"
r="$r $LINENO"' USR1
f() { local i; for ((i = 0; i < 150; i++)); do kill -USR1 $$; done; }
f
echo "$r" | tr ' ' '\n' | sort | uniq -c
trap - USR1
trap 'echo "ERR exits"; exit 3' ERR
g() { local i; for ((i = 0; i < 200; i++)); do [ $i = 170 ] && false; done; }
g
echo not-reached
