# A readonly variable reached through a nameref: a command-prefix binding `nr=3 cmd` is
# reported under the PREFIX's name (bash's assign_in_env: err_readonly (name)), and a
# standalone `nr=4` aborts the rest of the line like a direct readonly assignment
# (a subscripted target `ref -> a[1]` names the array).
exec 2>&1
readonly r=1
declare -n nr=r
nr=3 true; echo "prefix st=$?"
nr=3 true >/dev/null; echo "prefix+redir st=$?"
nr=4; echo "not reached"
echo "after standalone"
readonly a=(1 2); declare -n ref="a[1]"
ref=5; echo "not reached"
echo "after element"
f() { nr=4; echo "not reached in f"; }
f; echo "not reached after f"
echo "after function"
for ((i = 0; i < 160; i++)); do
	nr=3 true
	if ((i == 159)); then nr=5; echo "not reached in loop"; fi
done 2>&1 | sort | uniq -c
echo "after loop"
g() { nr=6 :; }
for ((i = 0; i < 160; i++)); do g; done 2>&1 | uniq -c
for ((i = 0; i < 160; i++)); do
	if ((i == 159)); then ref=7; fi
done
echo "after loop 2"
