# builtins/set.def: the `set` and `unset` builtins -- option parsing (bundled
# -o, a missing/empty -o name lists, validate-all-before-apply, -?/--help/+r),
# `set -o`/`set +o` listing, side effects of -o posix/ignoreeof, +B, SHELLOPTS
# readonly-ness, bare `set` listing functions, write errors; unset's option
# scan, readonly vars/functions/array elements, `s[@]` on a scalar, dynamic-scope
# unset (+ localvar_unset), special variables losing their magic when unset.
t() { "$@" 2>e.txt; local s=$?; sed 's/^.*line [0-9]*: //' e.txt; echo "st=$s"; }

echo "== listing (non-interactive: history/histexpand are off)"
set -o | grep -E '^(histexpand|history|braceexpand|posix) '
set +o | grep -E ' (histexpand|history|hashall)$'
echo "== -o with no name / an empty or dash-led name lists, then continues"
t set -o '' | sed -n '1p;$p'
set -o -f | sed -n 2p; echo "dash=$-"
t set +o '' | sed -n 1p
echo "== o inside a bundle takes the next word"
t set -eo pipefail; echo "$- $SHELLOPTS"; set +eo pipefail
t set -oe pipefail; echo "$- $SHELLOPTS"; set +e +o pipefail
t set -oo pipefail nounset; echo "$- $SHELLOPTS"; set +o pipefail +o nounset
set -eo | sed -n 4p; set +e
echo "== every flag is validated before any is applied"
t set -f -z; echo "dash=$-"; set +f
t set '-?'
t set --help | head -2
t unset --help | head -2
( set -r; set +r; echo "st=$? $-" ) 2>/dev/null
echo "== side effects of -o posix / -o ignoreeof"
set -o posix; echo "[${POSIXLY_CORRECT-unset}]"; set +o posix; echo "[${POSIXLY_CORRECT-unset}]"
set -o ignoreeof; echo "[$IGNOREEOF]"; set +o ignoreeof; echo "[${IGNOREEOF-unset}]"
ignoreeof=5; set -o ignoreeof; echo "[${ignoreeof-unset}]"; set +o ignoreeof
echo "== set +B turns brace expansion off at run time"
set +B
echo {a,b} "$SHELLOPTS"
set -B
bx() { set +B; echo {c,d}; set -B; }; bx
echo "== SHELLOPTS is readonly; its export bit survives an option change"
( SHELLOPTS=x; echo "not reached" ) 2>/dev/null; echo "st=$?"
t unset SHELLOPTS
t unset BASHOPTS
declare -n rso=SHELLOPTS; t unset rso; unset -n rso
( export SHELLOPTS; set -u; declare -p SHELLOPTS )
echo "== bare set lists functions (not in posix mode); write errors"
zz_fn() { echo hi; }
set | grep -A3 '^zz_fn'
set -o posix; set | grep -c '^zz_fn'; set +o posix
( set >&- ) 2>&1 | sed 's/^.*line [0-9]*: //'
echo "== unset: options come only first; later -f/-v are names"
b=1; unset a -f b; echo "b=[${b-unset}]"
b=1; unset -- -f b; echo "b=[${b-unset}]"
fb() { echo fb; }; t unset -v x -f fb; fb
echo "== unset of readonly things"
readonly r=1
t unset -n r
rf() { echo rf; }; readonly -f rf
t unset rf; t unset -f rf; rf
readonly -a ra=(1 2); t unset 'ra[0]'; echo "${ra[*]}"
echo "== unset of a subscripted scalar"
s=x; t unset 's[1]'; echo "s=[${s-unset}]"
s=x; t unset 's[@]'; echo "s=[${s-unset}]"
echo "== unset by a non-literal command name"
c=unset; q=1; $c q; echo "q=[${q-unset}]"
echo "== unset in a called function hits the caller's local (dynamic scope)"
x=g
f() { local x=l; g; echo "f sees [${x-unset}]"; }
g() { unset x; echo "g sees [${x-unset}]"; }
h() { local x=l1; k; echo "h sees [${x-unset}]"; }
k() { local x=l2; m; echo "k sees [${x-unset}]"; }
m() { unset x; echo "m sees [${x-unset}]"; unset x; echo "m2 sees [${x-unset}]"; }
f; h; echo "top [$x]"
shopt -s localvar_unset
f; h; echo "top [$x]"
shopt -u localvar_unset
echo "== unsetting a dynamic special variable removes its magic"
unset SECONDS LINENO BASHPID EPOCHSECONDS EPOCHREALTIME SRANDOM BASH_SUBSHELL HISTCMD BASH_COMMAND BASH_ARGV0
for v in SECONDS LINENO BASHPID EPOCHSECONDS EPOCHREALTIME SRANDOM BASH_SUBSHELL HISTCMD BASH_COMMAND BASH_ARGV0; do
	echo "$v=[${!v-unset}]"
done
SECONDS=abc; echo "SECONDS=$SECONDS"
unset FUNCNAME; fnm() { echo "fn=[${FUNCNAME-unset}]"; }; fnm
t unset PPID UID
( unset PATH; nosuchcmd_zz ) 2>&1 | sed 's/^.*line [0-9]*: //'
