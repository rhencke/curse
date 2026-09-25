# hash, from bash's builtins/hash.def + hashcmd.c/hashlib.c: the empty-table
# message (none in posix mode), the listing (hits, bucket order) and -l form,
# -t (one name: the path; several: NAME<TAB>PATH; with -l: reusable), -d, -p (a
# directory is an error), -r, a PATH assignment emptying the table, `hash NAME`
# skipping functions/builtins/paths and starting a count at 0, hits counted by
# every lookup — but a lookup in a pipeline stage stays in that subshell.
e() { sed 's/^.*line [0-9]*: //'; }
mkdir -p bin; for c in alpha beta gamma delta zeta; do printf '#!/bin/sh\necho %s\n' $c > bin/$c; chmod +x bin/$c; done
PATH=$PWD/bin:/usr/bin:/bin
hash 2>&1 | e; echo "empty st=${PIPESTATUS[0]}"
hash -l 2>&1 | e
alpha >/dev/null; beta >/dev/null; beta >/dev/null; gamma >/dev/null
hash | sed "s|$PWD|.|"
hash -l | sed "s|$PWD|.|"
hash -t beta | sed "s|$PWD|.|"; hash -t beta alpha | sed "s|$PWD|.|"
hash -t nosuch 2>&1 | e; echo "st=${PIPESTATUS[0]}"
hash -t 2>&1 | e; echo "t-noarg st=${PIPESTATUS[0]}"
hash -d 2>&1 | e; echo "d-noarg st=${PIPESTATUS[0]}"
hash -d beta; hash | sed "s|$PWD|.|"
hash -d beta 2>&1 | e; echo "d-again st=${PIPESTATUS[0]}"
hash delta zeta nosuch 2>&1 | e; echo "add st=${PIPESTATUS[0]}"; hash | sed "s|$PWD|.|"
f() { :; }; hash f echo /bin/ls ./x; echo "skip st=$?"; hash | sed "s|$PWD|.|"
hash -p /bin/true mytrue; mytrue; echo "p st=$?"; hash -t mytrue
hash -p bin mydir 2>&1 | e; echo "pdir st=${PIPESTATUS[0]}"
hash -lt alpha | sed "s|$PWD|.|"
hash -lt alpha gamma | sed "s|$PWD|.|"
hash -x 2>&1 | e; echo "x st=${PIPESTATUS[0]}"
hash -r; hash 2>&1 | e
hash -r alpha; hash | sed "s|$PWD|.|"
set +h; hash 2>&1 | e; echo "disabled st=${PIPESTATUS[0]}"; set -h
( set -o posix; hash -r; hash; echo "posix empty st=$?" )
hash -r; for c in zeta delta gamma beta alpha; do $c >/dev/null; done; hash | sed "s|$PWD|.|"
hash -l | sed "s|$PWD|.|"
