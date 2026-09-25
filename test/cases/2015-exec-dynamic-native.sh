# exec CMD, dynamic command names with prefix assignments, and builtins whose
# arguments split (wait $pid, : ${x:=…}), through the native simple-command runner.
t=$(mktemp)
( exec > "$t"; echo into-file; exec ls /nonexistent-zz 2>/dev/null; echo not-reached )
echo "st=$?"; cat "$t"
( x=5 exec sh -c 'echo "x=$x"' )
c=echo; x=1 $c hi
e=; y=2 $e; echo "y=$y st=$?"
z=3 $(exit 4); echo "z=$z st=$?"
( command exec sh -c 'echo cmd-exec' )
f() { echo "args $#"; }
v=f; k=9 $v a b
rm -f "$t"
sleep 0.1 & p=$!
wait $p; echo "wait=$?"
( exit 7 ) & q=$!
wait $q; echo "wait=$?"
: ${dflt:=set-by-colon}; echo "$dflt"
for i in 1 2; do eval "echo loop-$i" $([ $i = 2 ] && echo '; break'); done
