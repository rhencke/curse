# A command substitution in a declaration's NAME=(…) literal, or in a prefix assignment's
# value, numbers its body from ITS command's line — not from an earlier command's (an eval
# on line 1 left it behind in compiled code) (fuzz F90).
eval 'nosuchc_a' <(echo x) 2>/dev/null; echo "st=$?"
declare -a arr=($(nosuchc_b <(echo 1 2)))
typeset -n r1=r2; typeset -n r2=r1 2>/dev/null
eval 'nosuchc_c' 2>/dev/null
v=$(nosuchc_d) true
eval ':'
declare -a a2=(x `nosuchc_e` y); echo "${#a2[@]}"
f() {
	eval ':'
	local -a l=($(nosuchc_f))
	g=$(nosuchc_g) :
}
f
i=0; while [ $i -lt 150 ]; do eval ':'; declare -a a3=($(nosuchc_h)); i=$((i + 1)); done 2>&1 | sort | uniq -c
