# set -x in compiled code: every command kind traces its expanded words to stderr
# (PS4 prefix, quoting, $(…) depth), matching bash's xtrace output
exec 2>&1
set -x
x=1 true a
y=2
z=$y w=3
declare -i n
n=1+1
f() { echo "in f $1"; local q=1 r; return 3; }
f "a b"
echo hi 2>/dev/null
[[ -n $y && ! -f /nonexist ]]
[[ $y == 2 || $y =~ ^[0-9]+$ ]]
(( y + 1 ))
for i in 1 2; do :; done
for ((i=0;i<2;i++)); do :; done
case $y in 2) : ;; esac
a=(1 "2 3")
a[1]=q
a+=(r)
s="a b"; s+=" c"
x=$((n+2))
declare -a b=(4 "5 6")
v=$(echo sub $(echo deep))
: ${u:=def}
[ -n x ]
test 1 -eq 1
IFS=: read -r rr <<< "a:b"
if [ $y -lt 5 ]; then echo lt; fi
k=0; while (( k < 2 )); do (( k++ )); done
while [ $k -gt 0 ]; do k=$((k-1)); done
for w in a; do break; done
PS4='[$LINENO] '
echo "it's"
set +x
echo done
