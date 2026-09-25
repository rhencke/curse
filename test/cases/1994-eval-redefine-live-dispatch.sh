# eval redefining names at run time: each compiled simple command guards its literal
# name and, once it changed, runs its live-dispatch variant (rt.exec_dynamic, argv
# built as for that name); pipelines and ( … ) keep their compiled stages/bodies.
f() { echo "f $#: $*"; }
x="a  b"
f $x "$x"
echo one; local_test() { local v=$1 w="$2"; echo "lt $v|$w"; declare -i n=2+2; echo n=$n; }
local_test "p q" r
eval 'f() { echo "new f: $1"; }; echo() { builtin echo "E: $*"; }'
f $x "$x"
echo two $x
local_test "p q" r
unset -f echo
echo three
eval 'local_test() { echo replaced; }'
local_test
for i in 1 2; do f $i; done
true | f piped
( f sub )
