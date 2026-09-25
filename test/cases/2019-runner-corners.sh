# return with extra args / a redirect, prefix-only commands with redirects, and process
# substitutions in runner-dispatched commands (drained after the command).
f() { return 3 4; echo "not here"; }
f; echo "f=$?"
g() { return 5 > /dev/null; echo no; }
g; echo "g=$?"
h() { return -- 6 7; }
h; echo "h=$?"
t=$(mktemp -d)
abc=def > "$t/out"; echo "abc=$abc st=$?"; ls "$t"
xyz=1 > /nonexistent/dir/f; echo "xyz=$xyz st=$?"
q=$(exit 4) > /dev/null; echo "st=$?"
arr=(1 2) > /dev/null; echo "${arr[1]}"
rm -rf "$t"
f() { cat "$1"; } 2>/dev/null
f <(echo from-procsub)
eval 'cat' <(echo x) 2>/dev/null; echo "st=$?"
t=$(mktemp); echo 'cat "$1"' > "$t"
. "$t" <(echo sourced-ps)
x=1 cat <(echo "prefix-ps")
declare -a arr=($(cat <(echo 1 2)))
echo "${arr[@]}"
rm -f "$t"
# (a nameref cycle's failed write abandons the rest of an assignment list: status 1)
typeset -n r1=r2; typeset -n r2=r1
a=1 r1=z
echo $?
r1=z b=$(exit 3)
echo $?
r1=z >/dev/null
echo $?
echo end
