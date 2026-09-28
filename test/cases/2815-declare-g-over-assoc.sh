# `declare -g NAME=(…)` (typeset too, no -A/-a) in a function over a GLOBAL associative
# NAME: bash expands and quotes the words for the associative array, then converts it to
# an indexed one that stores them as they are — the quotes stay; a [key]'s quoted text is
# an arithmetic subscript (`'k'`: an error that abandons the command) (leftover L16). A
# local of that name, -A or -a (refused: can't convert), or the top level: as usual.
declare -A x=([k]=v)
f() { declare -g x=(a b); echo "st $?"; }; f; declare -p x
declare -A x=([k]=v); g() { declare -g x=("a b" c); }; g; declare -p x
declare -A x=([k]=v); g2() { typeset -gr x2=(1); declare -A x3; }; g2; declare -p x2
declare -A x4=([k]=v); g4() { typeset -gx x4=(1 2 3); }; g4; declare -p x4
declare -A y=([k]=v); h() { declare -g y=([k]=v a); echo "h $?"; }; h; echo "after $?"
declare -p y
declare -A z=([k]=v); h2() { declare -gi z=(1+1 2); echo "h2 $?"; }; h2; declare -p z
echo next
declare -A w=([k]=v); h3() { declare -ga w=(1); echo "h3 $?"; }; h3; declare -p w
declare -A u=([k]=v); h4() { declare -gA u=(a b); }; h4; declare -p u
k() { declare -A v=([k]=v); k2; declare -p v; }; k2() { declare -g v=(a b); }; v=1; k; declare -p v
declare -A t=([k]=v); declare -g t=(a b); declare -p t
declare -A e=([k]=v); eval 'fe() { declare -g e=($1 "$2"); }; fe p "q r"'; declare -p e
printf 'declare -A s=([k]=v); fs() { declare -g s=(1); }; fs; declare -p s\n' > s2815.sh; . ./s2815.sh
trap 'declare -A r=([k]=v); fr() { declare -g r=(x); }; fr; declare -p r' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do declare -A m=([k]=v); fm() { declare -g m=("$i"); }; fm; i=$((i + 1)); done; declare -p m
rm -f s2815.sh
