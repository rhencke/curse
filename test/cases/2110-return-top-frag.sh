# `return` where no function runs (return.def: "can only `return' …", status 2, execution
# goes on) from compiled top-level code: the script, a line of it, a subshell, a pipeline
# stage, a redirected compound, a $( ); a posix shell exits unless the status is tested
# or it ran through command/builtin. Inside a function or sourced file those same spots
# end the subshell/stage/$( ) — or the function/file. `var=x return` binds for the call.
echo a
return 5
echo "st=$?"
x=2 return
echo "[$x] st=$?"
( echo sub; return 3; echo sub2 ); echo "sub=$?"
echo x | { read v; return 2; echo "$v"; }; echo "pipe=$?"
{ echo grp; return 4; echo grp2; } 2>&1; echo "grp=$?"
x=$(echo c; return 1; echo d); echo "[$x]"
return foo; echo "foo=$?"
f() { x=$(return 3; echo hi); echo "[$x] $?"; ( return 6; echo no ); echo "s=$?"
	{ echo in; return 7; echo no; } >&2; echo notreached; }
f 2>&1; echo "f=$?"
g() { local y=2; y=5 return 8; }; g; echo "g=$? [$y]"
h() { { k() { echo "k $1"; return 3; }; k a; echo "k=$?"; } 2>&1 | cat; }; h
cat > rt.inc <<'EOI'
echo s1
( echo insub; return 4; echo nosub ); echo "sub=$?"
{ echo ingrp; return 5; echo nogrp; } 2>&1
echo notreached
EOI
. ./rt.inc; echo "src=$?"
for i in 1 2; do . ./rt.inc; done 2>&1 | head -3
set -o posix
return 3 || echo "tested $?"
command return 3; echo "command $?"
builtin return 3; echo "builtin $?"
return 3
echo "not reached"
