# findcmd.c / hashcmd.c / flags.c: command search along $PATH (relative, empty, `~`,
# trailing-slash elements; non-executable and directory matches; the "file to lose on";
# PATH unset/empty; `command -p` hashing; EXECIGNORE), the hash table's path rules
# (relative entries shown as ./x, HASH_CHKDOT re-checking ./NAME, checkhash and posix
# re-validation, `hash -p` quirks, -l quoting, subshell isolation), and flags.c:
# `$-` letters/order, the full set -o / set +o listings, -t onecmd, -n, -k, -a, -P.
S=${THIS_SH:-bash}
e() { sed 's/^.*line [0-9]*: //'; }
p() { sed "s|$PWD|.|g"; }
T=/usr/bin:/bin
mk() { printf '#!/bin/sh\necho %s\n' "$2" > "$1"; chmod +x "$1"; }
mkdir -p d1 d2 d3/qq b sub bin; mkdir d1/baz
printf 'echo d1-foo\n' > d1/foo; printf 'echo d1-bar\n' > d1/bar; printf 'echo nx\n' > nx
mk d2/foo d2-foo; mk d2/baz d2-baz; mk dc dot-cmd; mk b/x b-x; mk bin/tx tilde-x; mk hx here-x
hash -r
echo "== relative PATH: non-exec and directory matches are skipped; hashed as ./dir/cmd"
PATH=d1:d2:$T; foo; baz; hash -t foo; type foo; command -v foo; hash | grep -v /usr/
echo "== only a non-executable match: exec it anyway (Permission denied, 126)"
bar 2>&1 | e; echo "st=${PIPESTATUS[0]}"; hash -t bar 2>&1 | e
PATH=d3:$T; qq 2>&1 | e; echo "dir-only st=${PIPESTATUS[0]}"
echo "== empty elements and dot forms"
PATH=$T:; dc; hash -t dc; PATH=/nonexist::$T; dc; hash -t dc; PATH=./.:$T; dc; hash -t dc
echo "== trailing slash / doubled slashes / ~ in a PATH element"
PATH=$PWD/bin/:$T; tx; hash -t tx | p
PATH=$PWD//bin//:$T; tx; hash -t tx | p
HOME=$PWD; PATH="~/bin:$T"; tx; echo "st=$?"; type -P tx | p; command -v tx | p
( set -o posix; hash -r; tx 2>&1 | e; echo "posix st=${PIPESTATUS[0]}" )
echo "== PATH unset / empty: the cwd, never hashed; non-exec file gets exec'd"
f() { hx; hash; type hx; type -P hx; type -a hx; nx; echo "nx st=$?"; nosuch; echo "st=$?"; }
( unset PATH; f 2>&1 | while IFS= read -r l; do echo "${l//$PWD/.}"; done ) | e
( PATH=; f 2>&1 | while IFS= read -r l; do echo "${l//$PWD/.}"; done ) | e
echo "== command -p searches the standard path and hashes the result"
( PATH=/nonexist; command -p cat </dev/null; command -V cat; echo "PATH=$PATH" )
echo "== EXECIGNORE (full-path patterns, case-insensitive, no fallback to the ignored file)"
cp b/x d1/xx; cp b/x d2/xx; cp b/x d1/yy; PATH=$PWD/d1:$PWD/d2:$T; hash -r
EXECIGNORE="$PWD/d1/*"; xx; hash -t xx | p
yy 2>&1 | e; echo "st=${PIPESTATUS[0]}"; type -P yy | p; echo "tP st=${PIPESTATUS[0]}"
command -v yy | p; echo "cv st=${PIPESTATUS[0]}"
"$PWD/d1/yy"; echo "abs st=$?"
EXECIGNORE='*/d1/x?:*/d2/*'; hash -r; xx 2>&1 | e; echo "st=${PIPESTATUS[0]}"
EXECIGNORE='*/D1/XX'; hash -r; type -P xx | p
EXECIGNORE=xx; hash -r; type -P xx | p; unset EXECIGNORE
echo "== checkhash: a vanished/non-exec hashed file is searched again (always in posix mode)"
mk d1/x d1-x; PATH=$PWD/d1:$PWD/b:$T; hash -r; x; rm d1/x
x 2>&1 | p | e; echo "st=${PIPESTATUS[0]}"
shopt -s checkhash; x; hash -t x | p; shopt -u checkhash
mk d1/x d1-x; hash -r; x; chmod -x d1/x; x 2>&1 | p | e; echo "st=${PIPESTATUS[0]}"
shopt -s checkhash; x; hash -t x | p; shopt -u checkhash
chmod +x d1/x; hash -p "$PWD/d1/x" x; rm d1/x; ( set -o posix; x; hash -t x | p )
echo "== HASH_CHKDOT: '.' before the hashed dir -> ./NAME is re-checked"
PATH=.:$PWD/b:$T; hash -r; x; hash -t x | p
mk x dot-x; x; hash -t x | p; rm x; x
echo "== relative hash entries after cd"
PATH=b:$T; hash -r; x; hash -t x; cd sub; x 2>&1 | e; echo "st=${PIPESTATUS[0]}"; hash -t x; cd ..
PATH=.:$T; mk y top-y; y; hash -t y; cd sub; y 2>&1 | e; echo "st=${PIPESTATUS[0]}"; cd ..
echo "== hash -p quirks, -t of a dead relative entry, -l quoting vs -lt"
hash -r; hash -p /bin/true t1; hash -p ./rel t2; hash -p 'a b' t3
hash -t t1 t2 2>&1 | e; echo "st=${PIPESTATUS[0]}"
hash -l; hash -lt t3; hash -lt t1 t3
hash -r; hash -p /bin/true; echo "st=$?"; hash -p /bin/true --; echo "st=$?"
hash -p /bin/echo e1; hash -p /bin/true; hash -p /bin/true -l; echo "st=$?"
echo "== the table is per-subshell"
PATH=$T; hash -r; cat </dev/null
( PATH=/bin; hash >/dev/null ); hash; ( unset PATH; hash ) 2>/dev/null; hash
v=$(tr a b </dev/null); v=$(cat </dev/null); hash
echo "== flags: \$- order, invalid letters, full listings"
echo "[$-]"; set -abfkmpuCEHPT; echo "[$-]"; set +abfkmpuCEHPT +B +h; echo "[$-]"; set -Bh
for o in -i +i -c -s; do set $o 2>&1 | e; echo "st=${PIPESTATUS[0]}"; done
set -o; set +o
$S -c 'echo "$-"'; echo 'echo "$-"' | $S; $S -s a <<<'echo "$- $#"'; $S +hB -euc 'echo "$-"'
echo "== -t: exit after one command (the rest of that line still runs)"
printf 'echo a; echo b\necho c\n' | $S -t; echo "st=$?"
printf 'echo 1; set -t; echo 2\necho 3\n' | $S; printf 'set -t\necho x\n' | $S; echo "st=$?"
$S -c 'f() { set -t; echo in-f; }; f; echo same
echo next'
echo "== -n mid-line"
$S -c 'echo a; set -n; echo b
echo c; exit 3'; echo "st=$?"
echo "== -k: assignments anywhere are environment (after an earlier set -H, too)"
set -k; kf() { echo "K=${K-unset} args=$*"; }; kf a K=1 b; echo K=2 hi; echo "K=${K-unset}"
set -- K=3 z; echo "$# $*"; /usr/bin/printenv K K=4; set +k
echo "== -a exports every kind of assignment"
set -a; for fv in 1; do :; done; printf -v pv %s 1; getopts a: go -a x; read rv <<<"r"
: $(( av=1 )); let lv=2; xv=1; unset xv; xv+=2; set +a
declare -p fv pv go OPTARG av lv rv xv
echo "== -P / -o physical"
ln -s d2 lnk; cd lnk; echo "${PWD##*/}"; cd ..; set -P; cd lnk; echo "${PWD##*/}"; cd ..; set +P
set -o physical; cd lnk; w=$(pwd); echo "${w##*/}"; cd ..; set +o physical
