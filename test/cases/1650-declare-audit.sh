# builtins/declare.def audit: declare/typeset/local option conflicts, case
# attributes, listing filters, local's attribute handling, readonly arrays,
# nameref validity, EX_BADASSIGN status, arithmetic errors in assignments.
: >errlog; exec 2>>errlog
fl() { sed 's/^.*line [0-9]*: //' errlog; : >errlog; }

# -f with a variable attribute: the reported option is -n, then -i, -A, -a
declare -f -n -i -a foo; echo "st=$?"
declare -f -a -A foo; echo "st=$?"; fl
# -f/-F together print names only; -f -p appends the attribute line
g() { echo g; }; declare -fx g
declare -f -F g; declare -F -f g
declare -f -p g; fl
# posix mode: -F/-f reject a function name that is not an identifier
a-b() { :; }
set -o posix; declare -F a-b; echo "st=$?"; declare -f a-b >/dev/null; echo "st=$?"; set +o posix; fl
# +p is still -p
pv=1; declare +p pv
# -l and -u together cancel each other
declare -lu cl=AbC; declare -ul cu=AbC; declare -p cl cu
# attribute-only listings: -t, and `declare` (set) hides declared-unset vars
declare -t tv=1; declare -t | head -3
declare hid; declare | grep -c '^hid='
# -G: like -g but an existing local at this scope wins
m() { local x=1; declare -G x=2; echo "m $x"; }; x=0; m; echo "x $x"; fl

# local: every attribute, not just -airn
f() {
	local -x lx=1; printenv lx; local -rx rx=2; local -xi xi=2*2
	local -c lc=ab; local -lu lu=Ab; local -xa xa=(1)
	declare -p lx rx xi lc lu xa
	local -a la; local -A lA; declare -p la lA
	local -i c=2; local c+=5; local -i c+=1; echo "c=$c"
	local -; local -p; local -p -; echo "st=$?"
}
f; fl
local --help >/dev/null; echo "st=$?"
# local outside a function, even in a subshell / pipeline / $( )
(local w=1; echo "w=$w"); local z=2 | cat; echo "${PIPESTATUS[0]}"
q=$(local q=1; echo "q=$q"); echo "$q"; fl

# readonly arrays cannot be modified or shadowed through declare/local
declare -ra ra=(1 2)
declare ra[1]=3; echo "st=$?"; declare -a ra[0]=5; echo "st=$?"; echo "${ra[*]}"
declare -rA rA=([a]=1); declare rA[b]=2; echo "st=$?"; declare -p rA
k() { local -a ra; echo "${ra[*]} st=$?"; }; k
k2() { local -a ra=(x); echo "${ra[*]} st=$?"; }; k2
fr() { local -r ro=1; local ro=2; echo "st=$? ro=$ro"; }; fr
declare -r rz=q; declare -n rz; echo "st=$?"; fl

# nameref: self reference through a plain declare; compound assignment through -a
declare -n gr3; declare gr3=gr3; echo "st=$?"
declare -n r9=t9; declare -a r9=(a b); declare -p r9 t9
nf() { declare -n r16=t16; declare -a r16=(x); declare -p t16; }; nf; fl

# declare's assignment errors are EX_BADASSIGN: 4 when it is a pipeline element
declare 1x | cat; echo "p=${PIPESTATUS[0]}"
declare -n nr=1a | cat; echo "p=${PIPESTATUS[0]}"
declare ok=1 1x | cat; echo "p=${PIPESTATUS[0]}"
declare -r rv=1; declare rv=2 | cat; echo "p=${PIPESTATUS[0]}"; fl

# an empty associative key in a compound assignment is rejected per element
declare -A ea=(['']=x [k]=v); echo "st=$?"; declare -p ea
k=; declare -A eb=([$k]=z); declare -p eb
# declare a[@]=x fails but the line goes on (a plain a[@]=x abandons it)
declare -a a6=(1 2); declare a6[@]=at; echo "st=$?"; fl

# dynamic variables carry their attributes
declare -p -i | sed -n 's/^declare \(-[a-z]*\) \([A-Z]*\).*/\1 \2/p'
declare -p OPTIND LINENO SECONDS BASHPID | sed 's/=.*//'; fl

# arithmetic errors in assignments to integer variables: the rest of the
# line is abandoned; declare/local/export errors carry the builtin's name
declare -i x
x='2 x'; echo "a $?"
echo "after a $?"
declare x='3 x'; echo "b $?"
echo "after b $?"
fe() { local -i y='6 x'; echo "e $?"; }; fe; echo "after e"
echo "next"
export x='7 x'; echo "g $?"
echo "after g"
declare -i z=1/0; echo "h $?"
fx() { echo f1; x='1 +'; echo f2; }
fx; echo "after fx"
echo "st=$?"
for i in 1 2; do echo "loop $i"; x='1 x'; done
echo "loop st=$?"
(x='1 x'; echo sub); echo "sub st=$?"
eval 'x="1 x"; echo in-eval'; echo "eval st=$?"
echo "after eval"
fl
