# set -v inside a trap handler: the handler's following lines echo as they're read, and
# when it ends the reader's echo is restored (bash saves/restores the parser state) — $-
# keeps (or loses) v; a `set +v` in a handler likewise leaves echo on after it (leftover
# L20). eval and source don't restore it. (All of it on stderr: merged here.)
exec 2>&1
trap 'set -v
echo in trap $-
echo second' USR1
kill -USR1 $$
echo after $-
echo more
trap 'echo t2' USR2
kill -USR2 $$
set +v
echo end $-
set -v
trap 'echo a
set +v
echo b $-
echo c' USR1
kill -USR1 $$
echo after $-
trap 'echo multi
echo line' USR2
kill -USR2 $$
set +v
echo quiet
trap 'set -v; echo x
echo y' USR1
i=0; while [ $i -lt 150 ]; do [ $i = 3 ] || [ $i = 120 ] && kill -USR1 $$; i=$((i + 1)); done
echo end $-
set +v
echo end2
eval "set -v
echo in eval"
echo after $-
printf "set -v\necho src\n" > s2919.sh
set +v
. ./s2919.sh
echo after2 $-
f() { set -v; }
set +v
f
echo after3
rm -f s2919.sh
