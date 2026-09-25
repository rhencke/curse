# export / readonly per builtins/setattr.def (set_or_show_attributes,
# show_var_attributes, set_var_attribute): -f errors, -n undo, -a/-A with and
# without assignments, namerefs, posix-mode listing and special-builtin exits.
# (runs in this shell, so attribute changes stick; diagnostics normalized)
e() { "$@" 2>err; local st=$?; sed 's/^.*line [0-9]*: //' err; echo "st=$st"; }

# -f on a name that is not a function: both builtins say so, status 1
e readonly -f nof
f() { echo "a b"; }
e readonly -f f nof f2
e export -f f nof
function a/b { :; }
e export -f a/b                       # cannot export
e export -nf a/b                      # -n skips the exportable-name check
e declare -fx a/b                     # declare -fx: neither message
e declare -fx nof; export -nf a/b

# -n: undo only finds existing vars (nothing is created); readonly -n is a no-op
e export -n NOTSET; e declare -p NOTSET
readonly -n NOTSET2; e declare -p NOTSET2
RN=1; readonly -n RN; RN=2; echo "RN=$RN"
declare -rx RX=1; export -n RX; declare -p RX
# ...and `-n` with no names just lists
readonly -n | grep -c 'RX'
export -n | grep -c 'RX'

# a failed assignment to a readonly var still sets the attribute, and later
# operands are still processed
readonly X=1
e export X=3 Z=4; declare -p X Z | sed "s/^/  /"
e readonly X=1 Y=2; echo "Y=$Y"

# -a/-A only matter WITH an assignment (then it's `declare -g[rx]a`)
s=str; export -a s; declare -p s
t=str; export -A t; declare -p t
export -a nn; declare -p nn
readonly -a rr; declare -p rr
export -a s3=(1 2) s4=q; declare -p s3 s4
readonly -A h=([a]=1) h2; declare -p h h2

# export/readonly through a nameref act on the target
declare -n r=tgt; export r; declare -p r tgt
declare -n r2=tgt2; export r2=7; declare -p r2 tgt2
env | grep -a '^r2=\|^tgt2='
declare -n r3=tgt3; tgt3=1; export r3+=2; declare -p r3 tgt3
declare -n r5=t5; readonly r5=8; declare -p r5 t5

# unset names are listed without a value
export UNS; readonly RUN; export -p | grep ' UNS'; readonly -p | grep ' RUN'
UNS=v; env | grep '^UNS='

# listings: quoting, name order, arrays, functions
export Q1=$'a\nb' Q2="it's" Q3='' Q4='a\b'
declare -A aa=([k]=v); export aa; readonly -a ra=(3)
readonly R_b=1 R_a=2 R_C=3
export -p | grep ' \(Q[0-9]\|aa\)'
readonly -p | grep ' \(R_\|ra\)'
g() { echo 2; }; export -f g f; readonly -f f
export -f; readonly -f

# posix mode: `export`/`readonly` replace declare, only a/A/f flags, no bodies
set -o posix
export -p | grep ' \(Q[0-9]\|aa\|UNS\|RX\)'
readonly -p | grep ' \(R_\|ra\|RUN\|RX\)'
export -f; readonly -pf
# ...and an assignment error or bad option in the special builtin exits
(readonly X=2; echo "not reached"); echo "sub=$?"
(export X=2; echo "not reached"); echo "sub=$?"
(readonly -a ra=(4); echo "not reached"); echo "sub=$?"
(export -q 2>/dev/null; echo "not reached"); echo "sub=$?"
(export 1x=5 2>/dev/null; echo "invalid name continues st=$?"); echo "sub=$?"
(readonly -f nof 2>/dev/null; echo "not a function continues st=$?"); echo "sub=$?"
# the general rule for every special builtin (execute_cmd.c): a redirection or
# assignment error exits at once (1), a usage error after the command (2) unless
# its status is tested; `command` takes the property away; plain failures go on
(: > nodir/x; echo "not reached") 2>/dev/null; echo "sub=$?"
(command : > nodir/x; echo "command continues st=$?") 2>/dev/null; echo "sub=$?"
(set -o bogus; echo "not reached") 2>/dev/null; echo "sub=$?"
(set -o bogus || echo "tested continues"; set -Q && :; ! set -Q; echo "st=$?") 2>/dev/null; echo "sub=$?"
(readonly R=1; export R=2 || echo "not reached") 2>/dev/null; echo "sub=$?"
(eval 'set -Q'; echo "not reached") 2>/dev/null; echo "sub=$?"
(eval 'cd -Q'; echo "eval of a regular builtin continues") 2>/dev/null; echo "sub=$?"
(fu() { unset -Q; echo "not reached"; }; fu) 2>/dev/null; echo "sub=$?"
(shift 5; echo "shift continues st=$?") 2>/dev/null; echo "sub=$?"
(trap x BOGUS; unset -f -v x; echo "plain failures continue st=$?") 2>/dev/null; echo "sub=$?"
