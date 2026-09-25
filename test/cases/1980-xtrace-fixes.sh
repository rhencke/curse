# set -x details: a negated PARENTHESIZED [[ ]] primary traces without its `!`; a
# declaration's array literal traces before its own redirection applies; a function an
# eval defined runs its DEBUG hooks once a trap is set after it was compiled
exec 2>&1
set -x
[[ ! ( a < b ) ]]
[[ ! a > b ]]
f() { local -a c=(1 "2 3") 2>/dev/null; }
f
set +x
set -T
eval 'g() { n=$((n+1)); : $n; }'
for i in 1 2 3; do g; done
trap 'c=$((c+1))' DEBUG
n=0; c=0
for i in 1 2 3 4; do g; done
trap - DEBUG
echo "n=$n c=$c"
