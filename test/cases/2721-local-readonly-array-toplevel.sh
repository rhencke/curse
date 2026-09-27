# `local NAME=(…)` outside a function makes no local, so a readonly NAME is the plain
# assignment's error — `NAME: readonly variable`, fatal to the line as `UID=(x)` is — and
# `local` never runs to say it is only meaningful in a function. curse said both, and went
# on (fuzz F25). In a function the local is made (bash: the function's name first).
local UID=(x); echo "not reached $?"
echo "next line $?"
local UID+=(x); echo "not reached"
local -i UID+=(x); echo "not reached"
local -a UID=x; echo "scalar $?"
local UID=x; echo "plain $?"
local X=(y); echo "not readonly $?"
readonly R=1; local R=(z); echo "not reached"
local R=(z) Q=(w); echo "not reached"
declare -r RR; local RR=(z); echo "not reached"
f() { local UID=(x); echo "fn $?"; }; f
eval 'local UID=(x); echo "not reached"'; echo "eval $?"
printf 'local UID=(x)\necho "source next $?"\n' > s2721.sh; . ./s2721.sh; echo "source $?"; rm -f s2721.sh
trap 'local UID=(x); echo "not reached"' USR1; kill -USR1 $$; trap - USR1; echo "trap $?"
n=0; for ((i = 0; i < 150; i++)); do (local UID=(x)) 2>/dev/null || n=$((n + 1)); done; echo "hot $n"
