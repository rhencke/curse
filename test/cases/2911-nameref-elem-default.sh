# ${ref-word} / :- / + / :+ / = / := through a nameref to an array ELEMENT test that
# element — its subscript evaluated, `D[a b]` an arith error — in every tier; an
# assignment (= / :=) substitutes the array's element 0, as bash does (with no element 0
# bash crashes: docs/bash-ub.md, test/ub) (leftover L12).
typeset -n r='D[a b]'; echo ${r-unset}; echo "st $?"
echo next
typeset -n q='E[1+]'; echo "${q:-u}"; echo "st $?"
a=(x "" z); declare -n r1='a[1]' s1='a[5]' t1='a[2]'
echo ${r1-u} ${r1:-v} ${s1-w} ${t1:+y} ${s1+n} "${r1-U}" "${s1:-V}"
echo ${r1:=q} ${s1=w}; declare -p a
x=abc; declare -n rx='x[3]'; echo "${rx:=q}"; declare -p x
declare -i b=(1 2); declare -n t='b[5]'; echo "[${t:=3+4}]"; declare -p b
f() { local -n lr='a[7]'; echo "${lr-f}" "${lr=g}"; }; f; declare -p a
eval 'declare -n er="a[8]"; echo ${er:-e}'
printf 'declare -n sr="a[9]"; echo ${sr+s}${sr-S}\n' > s2911.sh; . ./s2911.sh
trap 'declare -n tr="a[2]"; echo ${tr:+T}' USR1; kill -USR1 $$; trap - USR1
c=(1); declare -n cr='c[1]'; for ((i = 0; i < 150; i++)); do unset 'c[1]'; v=${cr:-$i}; done; echo "$v"
rm -f s2911.sh
