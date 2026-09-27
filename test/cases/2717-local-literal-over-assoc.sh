# A declaration builtin's NAME=(…) in a function makes a NEW local (not yet one of this
# function's, no -I, no -A): an indexed array whatever an outer associative one of that
# name is — its literal's words expand as an indexed array's (split, globbed, tildes) and
# `[]=` is a bad subscript. curse expanded it as the outer assoc's (a bare word unexpanded)
# and escaped a Lua error (`attempt to index local 'val'`) storing it (fuzz F20).
declare -A var=([k]=v)
x='h i'
f() { declare var=([]= 0); declare -p var; }
f; echo "after $?"
g() { declare var=([1]=a $x "$x" ~); declare -p var | sed "s#$HOME#HOME#"; }
g; echo "g $?"
h() { local var=([a]=b c); declare -p var; }
h; echo "h $?"
k() { declare -A var=([]= 0); declare -p var; }
k; echo "k $?"
l() { local -A var; declare var=([a]=b c); declare -p var; }
l; echo "l $?"
m() { local -I var=([a]=b c); declare -p var; }
m; echo "m $?"
shopt -s localvar_inherit
n() { local var=([a]=b [c]=d); declare -p var; }
n; echo "n $?"
shopt -u localvar_inherit
declare -p var
eval 'f; echo "eval $?"'
printf 'declare var=([]= 0 1); declare -p var\n' > s2717.sh; o() { . ./s2717.sh; }; o; rm -f s2717.sh
trap 'f; echo "trap $?"' USR1; kill -USR1 $$; trap - USR1
p() { local var=([x]=1 2); c=$((c + ${#var[@]})); }
c=0; for ((i = 0; i < 150; i++)); do p; done; echo "hot $c"
