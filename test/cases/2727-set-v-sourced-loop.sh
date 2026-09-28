# `set -v` while a sourced file or an eval'd string holds a loop: its lines are echoed as
# they're read, in every tier. The compiled tier's `.` handed a file it couldn't compile to
# the interpreter without the reader's hook (an escaped Lua error: attempt to call local
# 'hook'), and ran one it could compile without echoing its lines (fuzz F51).
printf 'for i in 1 2; do :; done\necho "in $i"\n' > s2727.sh
printf 'for i in 1; do echo $"x"; done\n' > t2727.sh
. ./t2727.sh; echo "quiet $?"
set -v
. ./s2727.sh
. ./t2727.sh
eval 'for i in 1 2 3; do :; done
echo "eval $i"'
f() { . ./s2727.sh; }; f
trap '. ./s2727.sh' USR1; kill -USR1 $$; trap - USR1
while false; do :; done; . ./s2727.sh
j=0; while [ $j -lt 150 ]; do . ./s2727.sh; eval 'for i in 3; do :; done'; j=$((j + 1)); done 2>&1 | sort | uniq -c
set +v
rm -f s2727.sh t2727.sh
