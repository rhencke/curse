# posix mode: a prefix on a special builtin persists — but `builtin exec` is not one
# (a temporary binding); an array-element prefix on a special builtin is a fatal error.
exec 2>&1
set -o posix
x=1 :; echo x=$x
unset y; y=2 unset y; echo y=${y-unset}
w=1 builtin exec; echo w=$w
v=3 command exec; echo v=$v
a[1]=z :
echo not reached
