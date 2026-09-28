# shift checks its count as bash's get_numeric_arg does: the number first (a bad one is
# "numeric argument required", status 1, the script goes on), then any argument after it
# ("too many arguments", the rest of the line abandoned). curse checked the count of
# arguments first (fuzz F63).
set -- a b c
shift x 2; echo "after $?"
shift -- y z; echo "dd $?"
shift 1 x; echo "no"
echo "many $?"
f() { shift q 1; echo "f $? $#"; }; f 1 2
eval 'shift w w'; echo "eval $?"
i=0; while [ $i -lt 150 ]; do shift z 9; s=$s$?; i=$((i + 1)); done 2>&1 | sort | uniq -c; echo "${#s}"
