# A pipeline stage is a subshell: an `unset` there that REVEALS a caller's shadowed
# variable (dynamic scope) must work on the stage's own copy of that box — once only the
# shadow records were copied, and the stage's write reached the parent's global.
x=global
g() { { unset x; echo "g sees: $x"; x=mod; echo "g set: $x"; } | cat; echo "g: $x"; }
f() { local x=loc; g; echo "f: $x"; }
f; echo "after: $x"
g2() { { unset y; y+=app; echo "stage y=$y"; } | cat; }
f2() { local y=loc; g2; echo "f2: $y"; }
y=gy; f2; echo "y after: $y"
g3() { { unset w; w[1]=z; echo "stage w=${w[*]}"; } | cat; }
f3() { local w=loc; g3; }
w=(a b); f3; echo "w after: ${w[*]}"
# a $(…)'s EXIT trap still runs in the substitution: $BASH_SUBSHELL is its level
x=$(trap 'echo "trap level $BASH_SUBSHELL"' EXIT; echo "body level $BASH_SUBSHELL"); echo "$x"
( trap 'echo "paren trap level $BASH_SUBSHELL"' EXIT; : )
