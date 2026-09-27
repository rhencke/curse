#@ guards: a trapped signal interrupting the open of a FIFO by `$(< f)` or `source f` fails it — "f: Interrupted system call", status 1, the trap running AFTER that diagnostic (bash: subst.c's and _evalfile's open have no retry; the handler only marks the trap pending) — while a redirection's open (redir.c redir_open) is retried once the trap has run; in curse the FIFO open waits on a helper thread (lib_cursesig.c curse_aopen) while jobs run, so the wait itself must end on the signal and hold its trap
#@ timeout: 30
# Deterministic: the signal is sent by `sthelp sendwhen` only once the shell sleeps in a
# system call (waiting in the open), so bash fails/retries each open at one fixed point.
H=$STH
f=${TMPDIR:-/tmp}/oe.$$
mkfifo "$f" || exit 9
trap 'echo "  trapped"' USR1
signo=$(kill -l USR1)
fn() { x=$(< "$f"); echo "fn cap st=$? x=[$x]"; }
{
for how in plain eval func dot; do
	echo "== $how"
	"$H" sendwhen $$ $signo 5000 any &
	case $how in
	plain) x=$(< "$f"); echo "cap st=$? x=[$x]" ;;
	eval) eval 'x=$(< "$f")'; echo "cap st=$? x=[$x]" ;;
	func) fn ;;
	dot) echo 'x=$(< "$f"); echo "dot cap st=$? x=[$x]"' >"$f.src"; . "$f.src" ;;
	esac
	wait $!; echo "sender st=$?"
	"$H" sendwhen $$ $signo 5000 any &
	case $how in
	eval) eval 'source "$f"'; echo "src st=$?" ;;
	*) source "$f"; echo "src st=$?" ;;
	esac
	wait $!; echo "sender st=$?"
	echo "-- a redirection's open is retried"
	"$H" sendwhen $$ $signo 5000 any "$f" &
	read x <"$f"; echo "read st=$? x=$x"
	wait $!; echo "sender st=$?"
done
} >"$f.out" 2>&1
sed "s#${f}#F#g; s#^.*: line [0-9]*: #E: #" "$f.out"
rm -f "$f" "$f.src" "$f.out"
"$STH" probe
