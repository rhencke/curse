# Warm (compiled) runs must behave like the first, interpreted run: whatever run-time
# state compiled code depends on is in its cache key or checked when it runs.
# - `command -v/-V` compiled (rt.command_query) is interp's command.def branch: the option
#   scan after -v (-x invalid, `--`, -p), alias requoting, posix "special" wording and
#   absolute paths for relative PATH hits. Run from hot loops so compiled code answers,
#   and from alias-defining (line-mode) code whose warm run compiles each line.
# - a hot loop / function compiled from its own source text parses with the extglob
#   state it was READ under (tier loop_fragment / fn_hot), not what is live later.
# - a program's cached module is keyed by the parse options the shell started with:
#   the same -c text with and without -O extglob.
# - line mode (a program that defines aliases, or one whose parse depends on a guessed
#   extglob state): each line compiles alone, so the state earlier lines set (set -k)
#   must reach it at run time; trap handler text expands aliases like bash's.
e() { local l; while IFS= read -r l; do l=${l//"$PWD"/PWD}; echo "${l#*line [0-9]*: }"; done; }
mkdir -p d1; printf '#!/bin/sh\necho d1-foo\n' > d1/foo; chmod +x d1/foo
P0=$PATH
q1() {
	command -v -x; echo "st=$?"
	command -v -- foo; command -V -- foo | e; echo "st=$?"
	command -vV echo; command -Vv nosuch; echo "st=$?"
	command -v q; command -V q
	command -V export
}
echo "-- command -v/-V, hot loop"
alias q="it's"
PATH=d1:$P0
for i in {1..120}; do
	if ((i == 120)); then q1 2>&1 | e; else q1 >/dev/null 2>&1; fi
done
echo "-- the same, posix mode (special builtins, absolute paths)"
unalias -a
( set -o posix; for i in {1..120}; do
	if ((i == 120)); then q1 2>&1 | e; else q1 >/dev/null 2>&1; fi
done )
PATH=$P0
echo "-- line mode: aliases in use, every line compiled on a warm run"
shopt -s expand_aliases; alias q="it's" cv='command -v'
cv q; command -v q; cv -x 2>&1 | e
PATH=d1; cv foo; set -o posix; cv foo | e; command -V export; set +o posix
PATH=$P0
echo "-- line mode: set -k from an earlier line reaches later lines and functions"
kf() { set -- K=4 y; echo "$# $*"; }
set -k
set -- K=3 z; echo "$# $*"
kf; eval 'set -- K=5 x'; echo "$# $*"; eval 'set -- K=5 x'; echo "$# $*"
set +k
echo "-- trap handlers expand aliases (parsed when they run)"
shopt -s expand_aliases # (set +o posix turned it off)
alias say=echo
trap 'say "err: $BASH_COMMAND"' ERR
false; (exit 3)
trap - ERR
echo "-- line mode: what earlier lines set up reaches later lines"
false
echo "ps=${PIPESTATUS[*]}"
sg() { echo "${FUNCNAME[*]} ${BASH_LINENO[*]}"; }
sf() { sg; }
sf
x=$(say a; say b); echo "[$x]"
alias sy=echo; y=$(sy c); echo "[$y]"
unalias sy; z=$(sy d 2>&1); echo "[${z#*line [0-9]*: }]"
trap 'echo "dbg: $BASH_COMMAND"' DEBUG
say one
trap - DEBUG
shopt -s extdebug
trap '[[ $skip != 1 ]] || { skip=0; false; }' DEBUG
skip=1
say skipped
say shown
trap - DEBUG
shopt -u extdebug
unalias -a; shopt -u expand_aliases

echo "-- hot fragments keep the extglob state they were parsed under"
shopt -s extglob
( f() { [[ !(x) ]] && echo -n y || echo -n n; }; for i in {1..150}; do f; done; echo ) | tr -s yn
( i=0; while ((i < 150)); do [[ !(x) ]] && echo -n Y || echo -n N; i=$((i+1)); done; echo ) | tr -s YN
shopt -u extglob

S=${THIS_SH:-bash}
echo "-- extglob-dependent parses the compiler can only guess run a line at a time"
cat > xg1.sh <<'X'
g() { [[ !(x) ]] && echo -n y || echo -n n; }
shopt -s extglob
for i in {1..150}; do g; done; echo
h() { [[ !(x) ]] && echo -n y || echo -n n; }
for i in {1..150}; do h; done; echo
X
cat > xg2.sh <<'X'
shopt -s extglob
f() { [[ !(x) ]] && echo y || echo n; }
shopt -u extglob
f
g() { case a in @(a|b)) echo Y;; esac; }
f; g
X
for i in 1 2; do "$S" xg1.sh | tr -s yn; "$S" xg2.sh 2>&1 | e; done

echo "-- a program's module is keyed by the options the shell started with"
for o in +O +O -O -O +O; do "$S" $o extglob -c '[[ !(x) ]] && echo y || echo n'; done
