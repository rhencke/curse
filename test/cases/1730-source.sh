# source / ., from bash's builtins/source.def: usage (no file, options, `--`);
# the file for a bare name comes from $PATH only with shopt sourcepath, else
# the current directory; arguments replace $@ for the file's duration — a `set`
# in the file keeps its values at top level but not inside a function; an empty
# file leaves $? 0; `return`, a syntax error (reported, status 2), not-found
# and directory errors; the DEBUG trap reaches into the file only with set -T;
# $0, FUNCNAME and BASH_SOURCE inside; posix mode's fatal not-found error.
rm -rf pdir sub; mkdir -p pdir sub
e() { sed "s/^.*line [0-9]*: //"; }
printf 'echo "args: $# [$*]"\n' > a.sh
printf 'set -- x y z\n' > setargs.sh
printf 'echo "in b: ${BASH_SOURCE[0]} $LINENO"; return 3; echo no\n' > b.sh
printf 'echo "from path"\n' > pdir/pp.sh
printf 'echo "from cwd"\n' > pp.sh
printf 'false\n' > f.sh
: > empty.sh
source 2>&1 | e; echo "st=${PIPESTATUS[0]}"
source -x a.sh 2>&1 | e; echo "st=${PIPESTATUS[0]}"
source -- a.sh 1 2
set -- p q; . ./a.sh; . ./a.sh r; echo "after: $# [$*]"
set -- p q; . ./setargs.sh extra; echo "set in src w/ args: $# [$*]"
set -- p q; . ./setargs.sh; echo "set in src: $# [$*]"
f() { . ./setargs.sh arg; echo "in f: $# [$*]"; }; set -- p q; f 1 2; echo "outer: $# [$*]"
. ./b.sh; echo "ret st=$?"
. ./f.sh; echo "false st=$?"
false; . ./empty.sh; echo "empty st=$?"
. ./nosuch.sh 2>&1 | e; echo "st=${PIPESTATUS[0]}"
. ./sub 2>&1 | e; echo "dir st=${PIPESTATUS[0]}"
PATH=$PWD/pdir:$PATH; . pp.sh
shopt -u sourcepath; . pp.sh; shopt -s sourcepath
rm pp.sh; . pp.sh; mv pdir/pp.sh .; . pp.sh 2>&1 | e
. nothere.sh 2>&1 | e; echo "nf st=${PIPESTATUS[0]}"
shopt -u sourcepath; . nothere.sh 2>&1 | e; shopt -s sourcepath
trap 'echo DBG' DEBUG; printf 'echo body\n' > d.sh; . ./d.sh; trap - DEBUG
set -T; trap 'echo DBG2' DEBUG; . ./d.sh; trap - DEBUG; set +T
printf 'echo "\$0=[$0]" "${FUNCNAME[*]-}" "${BASH_SOURCE[*]}"\n' > n.sh; g() { . ./n.sh; }; g 2>&1 | sed "s|$PWD|.|g; s|[^ ]*so.sh|SELF|g; s|run.lua|SELF|g"
printf 'return\n' > r.sh; false; . ./r.sh; echo "bare ret st=$?"
printf 'exit 4\n' > x.sh; ( . ./x.sh; echo no ); echo "exit st=$?"
printf 'echo "syntax ("\n( \n' > syn.sh; . ./syn.sh 2>&1 | e; echo "syn st=${PIPESTATUS[0]}"
printf 'local v=1 2>&1; echo "local st=$?"\n' > l.sh; . ./l.sh 2>&1 | e
( set -o posix; . ./nothere.sh 2>/dev/null; echo "posix continues" ); echo "posix st=$?"
( set -o posix; command . ./nothere.sh 2>/dev/null; echo "posix command continues $?" )
printf 'echo "a:$1"; shift; echo "b:$1"\n' > sh.sh; set -- orig; . ./sh.sh x y; echo "restored: $1"
