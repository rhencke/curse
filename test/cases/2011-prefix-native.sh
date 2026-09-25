# Prefix assignments compiled natively (rt.simple_run's bindings): on functions, on
# special builtins, on eval/source, left-to-right visibility.
f() { echo "f: x=$x y=$y"; }
x=1 y=$x f
echo "after: x=${x-unset}"
a=1 b=$a sh -c 'echo "sh: $a $b"'
x=2 eval 'echo "eval: $x"'
echo "after eval: ${x-unset}"
t=$(mktemp); echo 'echo "src: $x $1"' > "$t"
x=3 . "$t" arg
echo "after source: ${x-unset}"
v=5 :
echo "v=${v-unset}"
typeset -i n=2
n+=5 f
echo "n=$n"
s=ab; s+=cd f 2>/dev/null; echo "s=$s"
g() { local x=inner; h; }
h() { echo "h sees x=$x"; }
x=outer g
readonly ro=1
ro=2 f
echo "status=$? ro=$ro"
rm -f "$t"
eval 'true() { echo "redefined true $1"; }'
true a
k=1 true b
unset -f true
true && echo ok
