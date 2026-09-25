# redir.c corners: fd moves (n>&m-) restored after a command, {varname}
# allocation/closing/bad variables and varredir_close, `>&word` (digits vs
# filename vs `-`), noclobber on non-regular files and dangling symlinks,
# `1<&-` inside pipelines/captures, set -u / failglob / posix mode in
# redirection words and here-docs, here-doc expansion errors, fd inheritance.
# Everything runs inside one pipe so `> /dev/stdout` can't truncate a file.
n() { sed 's/^.*line [0-9]*: //'; }
{
# --- fds opened by the shell (exec, per-command) are inherited by children
lsfd() { bash -c 'cd /proc/$$/fd && echo *'; }
exec 3>i1 7>i2; lsfd; lsfd 5>i3; exec 3>&- 7>&-; lsfd

# --- n>&m- / n<&m- on a plain command: m is closed only for that command
printf 'a\nb\n' > f
exec 6<f
read -r x <&6-; echo "x=$x"
read -r y <&6; echo "y=$y st=$?"
exec 6<&- 4>o
echo one >&4-; echo two >&4; echo "st=$?"; exec 4>&-; cat o

# --- {varname}: lowest free fd >= 10, reuse, close via the variable
exec {a}>fa; exec {b}>fb; echo "a=$a b=$b"
exec {a}>&-; exec {c}>fc; echo "c=$c"; exec {b}>&- {c}>&-
exec 3>f3; exec {v}<&3-; echo "moved: $((v >= 10))"; { echo x >&3; } 2>&1 | n
exec {v}>&-
readonly R=5; { exec {R}>fr; echo "st=$?"; } 2>&1 | n
{ exec {GROUPS}>fg; echo "st=$?"; } 2>&1 | n
unset U; { exec {U}>&-; echo "st=$?"; } 2>&1 | n
U=; { exec {U}>&-; echo "st=$?"; } 2>&1 | n
shopt -s varredir_close
echo hi {e}>fe; { echo later >&$e; echo "st=$?"; } 2>&1 | n
shopt -u varredir_close

# --- >&word: only all-digit words are fds; anything else is a file
echo a >&0x2; echo b >&1.0; echo c >& ' 1'; ls 0x2 1.0 ' 1'
{ echo d >&4294967297; echo "st=$?"; } 2>&1 | n
{ echo e >&-1; echo "st=$?"; } 2>&1 | n
{ echo f >& nodir/f; echo "st=$?"; } 2>&1 | n
mkdir dir; { echo g >& dir; echo "st=$?"; } 2>&1 | n

# --- noclobber: non-regular targets are fine, a dangling symlink is not
set -C
{ echo x >& /dev/null; echo "st=$?"; } 2>&1 | n
{ echo x &> /dev/null; echo "st=$?"; } 2>&1 | n
echo old > nc; { echo x >& nc; echo "st=$?"; } 2>&1 | n
ln -s missing dangling; { echo x > dangling; echo "st=$?"; } 2>&1 | n
set +C

# --- closing fd 1 with the input form inside a pipeline / capture
{ echo hi 1<&-; echo "st=$?"; } 2>&1 | n
z=$(echo hi 1<&- 2>/dev/null; echo "st=$?"); echo "z=$z"
{ pwd >&-; echo "st=$?"; } 2>&1 | n

# --- set -u: fatal in a filename, not in a here-string/here-doc body
( set -u; echo x > $NOPE; echo "survived $?" ) 2>&1 | n
( set -u; cat <<< $NOPE; echo "survived $?" ) 2>&1 | n
( set -u; cat <<E
$NOPE
E
echo "survived $?" ) 2>&1 | n

# --- failglob aborts in a filename; posix mode neither splits nor globs it
( shopt -s failglob; echo hi > nomatch*; echo "st=$?" ) 2>&1 | n
( set -o posix; w="a b"; echo hi > $w; echo "st=$?"; cat "a b" ) 2>&1 | n
( set -o posix; touch pq; echo hi > p*; cat 'p*' ) 2>&1 | n

# --- a here-doc expansion error names the whole body
{ cat <<E
a ${x;} b
E
echo "st=$?"; } 2>&1 | n

# --- /dev/fd/N, /dev/stdout, /dev/stderr
exec 8>df; echo via-devfd > /dev/fd/8; exec 8>&-; cat < df
echo via-stdout > /dev/stdout
{ echo via-stderr > /dev/stderr; } 2>&1
{ cat < /dev/fd/9; echo "st=$?"; } 2>&1 | n
} 2>&1 | cat
