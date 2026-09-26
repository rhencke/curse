# NAME=(…) as a command prefix is a literal string, and set -x traces it as one.
exec 2>&1
set -x
a=(1 2) echo arr
a+=(3) b=4 printenv a
set +x
