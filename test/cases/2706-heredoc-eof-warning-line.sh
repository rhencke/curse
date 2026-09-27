# A here-document ended by end-of-file warns at the line the input ended on ("here-document
# at line N delimited by end-of-file"), then the syntax error follows. The compiled tier
# printed a warning carried by a syntax error at the error's line (its statement's pc
# line) — `line 3' for `line 2' (fuzz F6): the warning now names its own line in every tier.
echo start
cat <<E1; echo b
x
E1
f() { eval "$1"; echo "st=$?"; }
f 'cat <<E2
y'
eval 'cat <<E3
z'
n=0; for ((i = 0; i < 150; i++)); do eval 'cat <<E4
w' >/dev/null 2>&1; n=$((n + $?)); done; echo "loop $n"
trap 'eval "cat <<E5
t"' USR1; kill -USR1 $$
{ <<EOF
x; } &
