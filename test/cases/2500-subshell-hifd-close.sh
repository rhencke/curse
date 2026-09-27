# fds >= 10 a subshell / $(…) opens, replaces or closes (`exec 13>f`, `{v}>f`, `exec 13>&-`)
# are its own: a forked subshell's changes die with it, so the parent (and the externals it
# runs later) never see them. curse runs subshells in-process, so it must undo them itself.
T=${TMPDIR:-/tmp}/curse-2500.$$
chk() { for f in "$@"; do if env test -e /proc/self/fd/$f; then echo -n "$f:open "; else echo -n "$f:closed "; fi; done; echo; }
x=$(exec {c}>/dev/null; echo $c); echo "c=$x"; chk $x
(exec 13>"$T"); chk 13
( : {d}>/dev/null; echo "in: d open? $([ -e /proc/self/fd/$d ] && echo y)" ); chk 10 11
exec 12>"$T.a"
(exec 12>"$T.b"; echo inner >&12); echo parent >&12; cat "$T.a"; echo ---; cat "$T.b"
(exec 12>&-); echo still >&12; cat "$T.a"
{ exec 14>/dev/null; } | cat; chk 14
f() { (exec 15>/dev/null; exec 16>&12); }; f; chk 15 16
eval '(exec 17>/dev/null)'; chk 17
trap '(exec 18>/dev/null)' USR1; kill -USR1 $$; chk 18
( exec 19>/dev/null; ( exec 19>&- ); [ -e /proc/self/fd/19 ] && echo "19 kept by outer" ); chk 19
# hot: the compiled loop body
for ((i = 0; i < 200; i++)); do
	x=$(exec {c}>/dev/null; echo $c); (exec 13>/dev/null 12>&-); y=$( : {d}>/dev/null; echo $d)
done
echo "$x $y"; chk 10 11 12 13
exec 12>&-
rm -f "$T" "$T.a" "$T.b"
