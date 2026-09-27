# A simple command's words — its arguments, prefix-assignment values, declaration
# NAME=(…) literals — all expand BEFORE its redirections apply (bash's
# execute_simple_command: expand, then do_redirections). An error inside one (a
# $( … ) that fails, an arithmetic error) goes to the stderr from before them:
# `echo "$(bad)" 2>/dev/null` still reports, and inside `$( … 2>&1)` it isn't captured.
exec 2>&1
zz=0
x=$(echo $(nosuch_in) 2>&1); echo "x=[$x]"
y=$(echo "$( ((1/zz)) )" 2>&1); echo "y=[$y]"
z=$( { echo $(nosuch_z); } 2>&1 ); echo "z=[$z]"
echo $(nosuch_w) 2>/dev/null
v=$(echo $(nosuch_v 2>&1) 2>/dev/null); echo "v=[$v]"
a=$(echo $( ((1/zz)) ) 2>&1); echo "a=[$a]"
b=$(echo "$(nosuch_b)" 2>&1); echo "b=[$b]"
c=$(echo "$(echo $((1/zz)))" 2>&1); echo "c=[$c]"
d=$(echo "$( (( 2/zz )); echo hi )" 2>&1); echo "d=[$d]"
e=$(echo "$( let 1/zz )" 2>&1); echo "e=[$e]"
f=$(echo "$( cd /nonexist )" 2>&1); echo "f=[$f]"
g=$(echo "$( x=$((1/zz)) )" 2>&1); echo "g=[$g]"
printf '%s\n' "$(nosuch_1)" 2>/dev/null
cat /dev/null "$(nosuch_2)" 2>/dev/null
f() { :; }
f "$(nosuch_3)" 2>/dev/null
g() { echo "g:$1"; }
g "$(nosuch_4)" 2>/dev/null
for i in $(seq 160); do x=$(echo "$(nosuch_l)" 2>&1); done 2>&1 | sort | uniq -c
