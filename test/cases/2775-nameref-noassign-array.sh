# `declare -n` on BASH_ARGV, FUNCNAME, GROUPS, … (arrays, noassign): "reference variable
# cannot be an array", status 1 — for `local -n`, only with a subscript; a plain one is
# "variable may not be assigned value". curse failed silently (fuzz F86).
declare -n BASH_ARGV["a b"]=x; echo "st $?"
declare -n BASH_ARGV[1]=x; echo "st $?"
declare -n FUNCNAME[0]=x; echo "st $?"
declare -n BASH_ARGV=x; echo "st $?"
declare -n GROUPS[a]=x; echo "st $?"
declare -n BASH_ARGV; echo "st $?"
declare -n BASH_LINENO+=x; echo "st $?"
declare +n BASH_ARGV; echo "plus $?"
f() { local -n BASH_SOURCE["x"]=y; echo "f $?"; local -n FUNCNAME; echo "f2 $?"; local -n FUNCNAME=x; echo "f3 $?"; local -n FUNCNAME[1]; echo "f4 $?"; }; f
declare -n A["a b"]=x; echo "A $?"
i=0; while [ $i -lt 150 ]; do declare -n GROUPS[$i]=z; echo "l $?"; i=$((i + 1)); done 2>&1 | sed 's/GROUPS\[[0-9]*\]/GROUPS[N]/' | sort | uniq -c
