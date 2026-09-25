# A dynamic command name with redirections: the native runner applies them unless the
# name turns out to be exec (whose redirections persist); an empty one still opens them.
t=$(mktemp)
c=echo; $c hello > "$t"; cat "$t"
e=exec; ( $e > "$t"; echo persisted ); cat "$t"
f() { echo "fn $*"; }; n=f; x=1 $n a 2>/dev/null > "$t"; cat "$t"
d=; $d > "$t"; echo "st=$? $(wc -c < "$t")"
rm -f "$t"
