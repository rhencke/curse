# DIRSTACK=(…) is an assignment statement like any other: $_ becomes empty and $? 0
# (the dynamic array's elements go through its assign_func).
cd /tmp
pushd / >/dev/null
: last
DIRSTACK=(/usr /tmp)
echo "[$_] $?"
dirs
