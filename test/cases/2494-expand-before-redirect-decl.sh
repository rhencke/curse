# A simple command's words — its arguments, prefix-assignment values, declaration
# NAME=(…) literals — all expand BEFORE its redirections apply (bash's
# execute_simple_command: expand, then do_redirections). An error inside one (a
# $( … ) that fails, an arithmetic error) goes to the stderr from before them:
# `echo "$(bad)" 2>/dev/null` still reports, and inside `$( … 2>&1)` it isn't captured.
exec 2>&1
zz=0
x=$(echo $(nosuch_in) 2>&1); echo "x=[$x]"
# (declarations and prefix assignments: their values expand before the redirections too)
h() { local x="$(nosuch_5)" 2>/dev/null; }; h
export ex="$(nosuch_6)" 2>/dev/null
[ "$(nosuch_7)" ] 2>/dev/null
test -n "$(nosuch_8)" 2>/dev/null
: "$(nosuch_9)" 2>/dev/null
true "$(nosuch_10)" 2>/dev/null
declare dd="$(nosuch_11)" 2>/dev/null
cd "$(nosuch_12)x" 2>/dev/null
echo "$((1/zz))" 2>/dev/null
echo after
v="$(nosuch_p)" true 2>/dev/null
v="$(nosuch_q)" 2>/dev/null
v="$(nosuch_r)" echo hi 2>/dev/null
echo "$(nosuch_s)" > /dev/null 2>&1
{ echo "$(nosuch_t)"; } 2>/dev/null
echo "$(nosuch_u)" 2>/dev/null | cat
x=$(echo "$(nosuch_v)" 2>&1 >/dev/null); echo "x=[$x]"
declare -a arr=($(nosuch_w)) 2>/dev/null
f2() { local -a la=($(nosuch_x)) 2>/dev/null; }; f2
v="$(nosuch_y)" declare -a arr2=($(nosuch_z)) 2>/dev/null
v="$(nosuch_y2)" printf '' 2>/dev/null
[[ -n "$(nosuch_a)" ]] 2>/dev/null
(( $(nosuch_b 2>&1 | wc -c) + 0 )) 2>/dev/null; echo $?
case "$(nosuch_c)" in *) echo c;; esac 2>/dev/null
f3() { local i; for ((i=0; i<160; i++)); do local lv="$(nosuch_f3)" 2>/dev/null; v="$(nosuch_f3v)" printf "" 2>/dev/null; done 2>&1 | sort | uniq -c; }; f3
