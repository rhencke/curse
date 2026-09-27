# A readonly prefix binding (or SHELLOPTS/BASHOPTS) is rejected before it binds, exports
# or traces anything (bash's assign_in_env); the command still runs.
exec 2>&1
readonly r=1
r=2 printenv r; echo s=$?
SHELLOPTS=x printenv SHELLOPTS; echo s=$?
BASHOPTS=y echo hi; echo s=$?
f() { echo "f r=$r"; }; r=9 f
set -x
r=3 echo traced
r=4 x=5 echo two 2>/dev/null
set +x
