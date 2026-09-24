# break / continue, from bash's builtins/break.def (+ get_numeric_arg, and
# execute_cmd.c's loop_level resets): a count <= 0 is "loop count out of range"
# and ends ALL the loops; a count past the nesting clamps; `--`; the count is
# legal_number (blanks, sign); two operands are "too many arguments"; functions,
# ( … ) and compound pipeline stages start at loop level 0, $( … ) doesn't; a
# multi-level break/continue leaves the level right for what follows; a
# non-numeric count is fatal (status 128).
e() { sed 's/^.*line [0-9]*: //'; }
for i in 1 2; do for j in a b; do echo "$i$j"; break 0; echo no; done; echo "outer $i"; done 2>&1 | e; echo "st=${PIPESTATUS[0]}"
for i in 1 2; do for j in a b; do echo "$i$j"; continue -1; echo no; done; echo "outer $i"; done 2>&1 | e
for i in 1 2; do for j in a b; do echo "$i$j"; break 5; done; echo "outer $i"; done; echo "st=$?"
for i in 1 2; do for j in a b; do echo "$i$j"; continue 9; done; echo "outer $i"; done; echo "st=$?"
for i in 1 2; do for j in a b; do echo "$i$j"; break -- 2; done; done; echo "dd st=$?"
for i in 1 2; do break ' 1 '; done; echo "sp st=$?"
for i in 1 2; do for j in a b; do echo "$i$j"; break +2; done; done; echo "plus st=$?"
for i in 1 2; do echo "t$i"; break 1 2; echo "same"; done 2>&1 | e; echo "tm"
f() { break; echo "f after st=$?"; }; for i in 1 2; do f 2>&1 | e; echo "loop $i"; done
g() { for k in x y; do echo "g$k"; break 2; done; echo "g end"; }; for i in 1 2; do g; echo "L$i"; done
for i in 1 2; do (echo "sub$i"; break; echo nope) 2>&1 | e; echo "after sub $i"; done
for i in 1 2; do echo "$i" | while read l; do echo "w$l"; break 2; done; echo "piped $i"; done
for i in 1 2; do { break; echo grp; } 2>&1 | e; echo "gp $i"; done
for i in 1 2; do x=$(break; echo in); echo "cs $i:[$x]"; done
break 2>&1 | e; echo "top"
( set -o posix; break; echo "posix st=$?" ) 2>&1 | e
for i in 1 2 3; do while :; do continue 2; done; echo never; done; echo "c2 i=$i"
i=0; until (( i++ >= 3 )); do for j in 1; do continue 2; echo no; done; done; echo "until i=$i"
for i in 1 2; do eval 'break'; echo no; done; echo "eval i=$i"
for i in 1 2; do b=break; $b; echo no; done; echo "dyn i=$i"
n=0; while break 2>/dev/null; do n=1; done; echo "cond-break n=$n"
for i in 1 2; do n=0; while continue 2; do n=1; done; echo never; done; echo "cond-cont2 i=$i"
# the loop level after multi-level breaks/continues (a leak once crashed a later clamp)
for i in 1; do for j in 1; do break 2; done; done
for i in 1; do for j in 1 2; do for k in 1; do continue 3; done; done; done
break 2>&1 | e; echo "level ok"
for i in 1 2; do for j in a b; do continue 3; done; echo "o$i"; done; echo "clamp ok"
for i in 1 2; do echo "in $i"; continue 0x1; echo "same line"; done
echo "not reached"
