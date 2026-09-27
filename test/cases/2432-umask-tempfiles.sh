# The shell's own temp files (a here-document too big for a pipe, an fd-level $(…)
# capture) under a restrictive umask, and in $TMPDIR: bash creates its here-document file
# and fchmods it 0600, so `umask 777` (mkstemp's file would be mode 000) can't block the
# reopen for reading; and it leaves nothing behind. (curse once failed the big
# here-document with "cannot create temp file", and leaked /tmp/lua_* files from $(…).)
_tmpd=$(mktemp -d); cd "$_tmpd" || exit 1
mkdir tmp; export TMPDIR=$PWD/tmp
big() { local i; for ((i = 0; i < 9000; i++)); do echo "line $i of the document"; done; }
body=$(big)
for m in 777 277 077 022; do
  ( umask $m
    cat <<END | wc -lc
$body
END
    echo "st=$?"
    cat <<<"$body" | tail -1
    x=$(umask; cd /nonexistent 2>&1; echo z); echo "[$x]" | sed 's/^.*line [0-9]*: //'
    t() { local v; v=$(echo q; set -o nosuch 2>&1); echo "[$v]"; }; t 2>&1 | sed 's/^.*line [0-9]*: //'
  )
done
ls -A tmp; echo "left in TMPDIR: $(ls -A tmp | wc -l)"
cd / && rm -rf "$_tmpd"   # (leave nothing behind)
