# Recurring $(…)/`…` text runs compiled (tier fragments behind capture_src): exit/return/
# break inside, syntax errors (fatal to the command; a backtick's just warns), assignments
# isolated, functions called from the body.
zecho() { echo "$@"; }
eval 'true'
for i in 1 2 3; do x=$(zecho "a$i"); echo "$x"; y=`echo b$i`; echo $y; done
for i in 1 2 3; do echo "$(exit 3)" $?; echo "$(echo z; return 2 2>/dev/null)" $?; done
f() { for i in 1 2; do v=$(echo in; return 4); echo "f $v $?"; done; }
f
for i in 1 2 3; do eval 'c=$(echo a; echo b ))'; echo "c=$c $?"; done 2>&1 | sed "s/^.*line [0-9]*: //"
for i in 1 2 3; do c=`echo a; ( `; echo "bt=$c $?"; done 2>&1 | sed "s/^.*line [0-9]*: //"
for i in 1 2 3; do c=$(n=$((n+1)); echo $n); echo "n=$n c=$c"; done
for i in 1 2; do for j in 1 2; do c=$(break; echo no); echo "br $c"; done; done
# (a body that redirects its builtin's stdout needs the fd-level capture, compiled or not)
for i in 1 2 3; do FOO=$(echo foo 1>&2) 2>/dev/null; echo "FOO=$FOO"; done 2>&1
for i in 1 2 3; do FOO=$(echo foo >&2; echo out); echo "FOO3=$FOO"; done 2>/dev/null
