# subst.c parameter expansion corners (parameter_brace_expand and helpers):
# patsub_replacement default, ~/~~ case toggle, indirection edge cases, ${!prefix*}
# skipping unset vars, @E escapes, @A on positional/nameref, extglob empty matches in
# patsub, subscripted names in unbound/:? diagnostics, := error status, and
# "bad substitution" (bash reports the whole word).
e() { sed 's/^.*line [0-9]*: //'; }

# --- patsub_replacement is ON by default: & is the matched text
x=abc; r='<&>'
echo ${x/b/[&]} "${x/b/$r}" "${x/b/"$r"}" "${x/b/\&}"
a=(xa ya); echo ${a[@]/a/&&} "${a[@]/a/"&"}"
y=aaa; echo ${y//a*/&-} ${y/#a/&&} ${y/%a/[&]}
r='\&'; echo ${x/b/$r} "${x/b/$(echo '&')}"

# --- ~ and ~~ toggle case (parameter_brace_casemod CASE_TOGGLE)
x=AbC; echo ${x~} ${x~~} ${x~~[A]} ${x~[a]}
a=(ab Cd); set -- eF gh; echo ${a[@]~} ${a[*]~~} ${@~} ${*~~}

# --- extglob and empty matches in ${x//pat/rep}
x=abcabc; echo ${x//+(b)/X}          # extglob off: +(b) is literal
shopt -s extglob
echo ${x//!(a)/X} ${x/!(*)/Q}
x=abc; echo ${x//*(z)/Y} ${x//?(b)/-}
shopt -u extglob

# --- single-quoted pattern ending in \ inside a double-quoted ${x/pat/rep}
x='a\b'; y='a\bc\'
echo "${x/'\'/Z}" "${x//'\'/Z}" "${y/'c\'/Z}"

# --- indirection
x=; (echo ${!x}) 2>&1 | e
x='a['; (echo ${!x}) 2>&1 | e
x='@'; set -- 'a b' c
for w in "${!x:1}"; do echo "<$w>"; done
echo "${!x@Q}"
set -- a b; echo ${!#} ${!##}
x=u; (: ${!x?}) 2>&1 | e; (: ${!x:?bad}) 2>&1 | e

# --- ${!prefix*} lists only SET variables
abc=1 abd=2; unset abc; declare abe; declare -a abf
echo ${!ab@}; echo "${!ab*}"

# --- @A / @E transforms
set -- 'a b' c; echo "[${2@A}]" "[${1@A}]"
v=5; declare -n nr=v; echo ${nr@A}
x='\c'; echo "${x@E}|"
x='a\c'; echo "${x@E}|"
x='a\cAb'; echo "${x@E}|" | od -An -c
x='\101\0101\1234'; echo "${x@E}|" | od -An -c
x='a\0b'; echo "${x@E}|"

# --- subscripted names in diagnostics
(set -u; a=(x); echo "${a[3]}") 2>&1 | e
(set -u; a=(); echo "${a[0]}") 2>&1 | e
(set -u; i=2; a=(x); echo "${a[i]}") 2>&1 | e
(set -u; declare -A A=([k]=1); echo "${A[z]}") 2>&1 | e
(set -u; declare -A A=([k]=1); echo "${A[0]}") 2>&1 | e
(set -u; x=abc; echo "${x[1]}") 2>&1 | e
(set -u; unset b; echo "${#b[@]}") 2>&1 | e
(a=(); : ${a[1]:?}) 2>&1 | e
(declare -A A; : ${A[k]?m m}) 2>&1 | e

# --- nounset in a substring offset; bad negative index diagnostic with :-
(set -u; s=abc; echo ${s:u}) 2>&1 | e
(a=(one two); echo ${a[-3]:-d}) 2>&1 | e

# --- huge offset/length
s=abc; echo "[${s:9223372036854775807}]" "[${s:0:9223372036854775807}]"

# --- "${x:-"$@"}" keeps the positional words separate
unset x; set -- 1 2
for w in "${x:-"$@"}"; do echo "<$w>"; done
for w in "${x:-$@}"; do echo "<$w>"; done

# --- nameref to an array element: ${#r}
declare -n r2='arr[1]'; arr=(p q); echo $r2 ${#r2}

# --- bad substitution: bash prints the whole word
(echo a${!1@}b) 2>&1 | e
(x=1; echo a${x@Z}b) 2>&1 | e
(x=a; echo "pre ${#!x}zz") 2>&1 | e
(echo ${%x}) 2>&1 | e
(echo ${a[1]x}) 2>&1 | e
(echo ${x-a}${-x}) 2>&1 | e

# --- := errors: the command is aborted with status 2
readonly ro; echo ${ro:=x}; echo same
echo st=$?
(a=(); : ${a[@]:=x}
echo notreached)
echo st=$?
(echo ${1:=x}) 2>&1 | e; echo st=$?
