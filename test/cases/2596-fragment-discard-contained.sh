# A DISCARD (bash's jump_to_top_level) out of eval'd or sourced text: parse_and_execute
# contains it — the rest of THAT text's line is dropped, $? is 1, and the eval/source
# goes on with its next line (so a source's status is its last line's). In a subshell
# environment it isn't contained: it ends the subshell, status 1. Two such DISCARDs:
# a word cut at a $'…' NUL ("bad substitution: no closing `}'") and $FUNCNEST.
# The compiled tier runs eval/source text as a nested fragment whose line markers must
# not leave the outer program's resume point behind (else a later line abort outside
# jumped into the fragment's numbering — a lost script, or a loop forever).
T=${TMPDIR:-/tmp}/fdc$$
mkdir -p "$T"
exec 3>&2 2>"$T/err"
printf '%s\n' 'x="${u-$'"'"'r\0s'"'"'}"' 'echo src-next $?' >"$T/d.inc"
printf '%s\n' 'f' 'echo src-next $?' >"$T/fn.inc"
source "$T/d.inc"; echo sst=$?
source "$T/d.inc"; echo sst2=$?
eval 'x="${u-$'"'"'r\0s'"'"'}"'; echo est=$?
for i in 1 2; do source "$T/d.inc"; echo in $i; done
FUNCNEST=1; f(){ g; }; g(){ :; }
source "$T/fn.inc"; echo fsst=$?
source "$T/fn.inc"; echo fsst2=$?
eval 'f; echo in-eval $?
echo l2 $?'; echo fest=$?
( eval 'f
echo e2 $?'; echo sub $? ); echo after-sub $?
( source "$T/d.inc"; echo sub $? ); echo after-sub2 $?
( eval 'echo $((1/0))
echo e2 $?'; echo sub $? ); echo after-sub3 $?
FUNCNEST=
# hot: a compiled loop running eval/source text that aborts, then its own abort
n=0
for ((i = 0; i < 200; i++)); do
	source "$T/d.inc" >/dev/null
	eval 'x="${u-$'"'"'r\0s'"'"'}"
n=$((n + 1))'
done
echo "hot n=$n"
for i in 1 2; do
	eval 'x=1
y=2'
	if [ $i = 2 ]; then echo $((i / 0)); fi
done
echo "after eval-then-div0"
h() { eval 'a=1
b=2'; echo $((1 / 0)); echo not reached; }
h; h; h
echo "after fn-eval-div0"
exec 2>&3
sed 's#^[^ ]*: line#line#' "$T/err" | sort | uniq -c
rm -rf "$T"
