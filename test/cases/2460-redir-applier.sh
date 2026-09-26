# The one redirection applier (rt.redir_open) in both tiers: open flags per op, noclobber
# (set -C) and its non-regular exemption, >| / &> / >&word / <>, {v} named fds that persist
# (and varredir_close), here-docs on other fds, open failures, a restricted shell, and
# redirections inside pipeline stages (a stage writes its moved fd 1 directly)
exec {v}>f1; echo "v=$v"; echo x >&$v; echo y >&$v; cat f1
exec {w}>f2 {u}>f3; echo "$w $u"; exec {w}>&- {u}>&-
: {q}>f4; echo "q=$q"; echo z >&$q; cat f4; exec {q}>&-
shopt -s varredir_close; : {r}>f5; echo "r=$r"; (echo zz >&$r) 2>&1 | sed 's/.*: //'; shopt -u varredir_close
set -C; echo a > f6; echo b > f6; echo "st=$?"; echo c >| f6; cat f6; echo d > /dev/null; echo "dn=$?"
echo e &> f6; echo "both=$?"; echo g >& f6; echo "gw=$?"; echo h &>> f6; cat f6; set +C
echo rw > f7; exec 3<>f7; read -r l <&3; echo "$l"; echo more >&3; exec 3>&-; cat f7
cat 3<<E <&3
hd3
E
cat 0<<<"here"
echo x > nodir/f; echo "nd=$?"
cat < nosuch; echo "ns=$?"
{ echo out; echo err >&2; } > f8 2>&1; cat f8
echo s1 >/dev/full | cat; echo "full=${PIPESTATUS[*]}"
{ echo p1; echo p2 > f9; echo p3; } | cat; cat f9
for i in 1 2 3; do echo $i >> f10; done; cat f10
while read -r l; do echo "r:$l"; done < f10
f() { echo fn; } ; f > f11; cat f11
x=$(echo cap; echo capf > f12); echo "$x"; cat f12
{ exec > f1; echo x; } | cat; cat f1
{ echo a; exec 3> f2; echo b >&3; echo c; } | cat; cat f2
g() { echo g1; echo g2 >&2; } 2>f3
{ g; echo after; } | cat; cat f3
{ echo q; cat <<E; echo w; } | cat
hd
E
echo s1 | { cat > f4; echo s2; } | cat; cat f4
{ echo o1 >/dev/full; echo "st=$?"; } | cat
( echo sub > f5; echo sub2 ) | cat; cat f5
x=$( { echo in; echo er >&2; } 2>&1 | cat ); echo "[$x]"
( set -r; echo a > r1; echo "o=$?"; echo a >& r1; echo "g=$?"; echo a 3<> r1; echo "rw=$?"; { :; } >> r1; echo "cp=$?"; echo x >&2 2>/dev/null; echo "dn=$?"; cat < /dev/null; echo "in=$?" )
ls
