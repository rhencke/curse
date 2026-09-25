# posix mode: a prefix assignment on a special builtin persists (and is exported);
# on a regular builtin/function it doesn't. Compiled via rt.simple_run's persist mode.
set -o posix
v=6 :
echo "v=${v-unset}"
sh -c 'echo "env v=$v"'
w=7 eval 'echo in:$w'
echo "w=${w-unset}"
u=1 export q=2
echo "u=${u-unset} q=$q"
p=9 true
echo "p=${p-unset}"
a=A x=tmp unset x
echo "a=$a x=${x-unset}"
f() { echo "f z=$z"; }
z=3 f
echo "z=${z-unset}"
