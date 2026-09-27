# A nameref's value must be an identifier or a valid array reference (bash's
# valid_nameref_value: NAME[SUB] whose subscript, read as skipsubscript reads it —
# quotes, backquotes, $( ) — ends at the last byte, not empty). curse took any
# `NAME[….]`: `declare -n r='A["]'` succeeded and expanding `$r` raised the parser's EOF
# error as a raw Lua error that killed the script (fuzz F4).
declare -n r='A["]'; echo "s=$?"
$r
echo "after $?"
declare -n r2='a[]'; echo "s=$?"
declare -n r3='a[1]x'; echo "s=$?"
declare -n r4='a[`echo ]`]'; echo "s=$?"
a=([1]=one); declare -n r5='a["1"]'; echo "s=$? $r5"
declare -n r6; r6='A["]'; echo "s=$?"
for r6 in 'b["]' a; do echo "in $r6"; done; echo "s=$?"
f() { local -n l='A["]'; echo "fn=$?"; }; f
eval "declare -n r7='B[\"x]'"; echo "eval=$?"
q='C[$(]'; declare -n r8; r8=$q; echo "s=$?"; unset -n r8
n=0; for ((i = 0; i < 150; i++)); do declare -n rr="Z[\"$i]" 2>/dev/null || n=$((n + 1)); done; echo "loop $n"
