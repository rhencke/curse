# A ( … ) whose redirection sends its output elsewhere: everything its builtins wrote —
# also compgen/complete, which buffer their output — goes to that target, never to the
# shell's own stdout after the subshell ends (oil builtin-completion #39 in a loop).
d=${TMPDIR:-/tmp}/sf$$; mkdir -p "$d"; cd "$d" || exit
( compgen -W "a b" a ) >/dev/null
( complete -W "x y" cmd; complete -p cmd ) >out
echo "out: $(<out)"
f() { compgen -W "one two" o; }
( f ) >/dev/null
( f ) 2>/dev/null >out2; echo "out2: $(<out2)"
touch 'foo bar' "foo'bar"
for ((i = 0; i < 150; i++)); do
	( compgen -f "foo b"; compgen -f "foo'" ) >/dev/null 2>&1
done
( compgen -f "foo b"; compgen -f "foo'" )
echo end
cd / && rm -rf "$d"
