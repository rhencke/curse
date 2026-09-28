# To bash's grammar any WORD before `()` names a function — a quoted one (`'f'()`, `"g"()`,
# `a'b'()`, `\h()`) too, and `function 'k'`: the definition is not a valid identifier when it
# runs (status 1, the text as written), not a syntax error. curse rejected the `(` (fuzz F65).
'f'() { echo hi; }; echo "st $?"
"g"() { :; }; echo "dq $?"
a'b'() { :; }; echo "mixed $?"
\h() { :; }; echo "bs $?"
'f'()
{ :; }; echo "nl $?"
function 'k' { :; }; echo "kw $?"
'f' () { :; }; echo "sp $?"
declare -F
eval "'e'() { :; }"; echo "eval $?"
x() { "y"() { :; }; echo "inner $?"; }; x
i=0; while [ $i -lt 150 ]; do 'z'() { :; }; s=$s$?; i=$((i + 1)); done 2>&1 | sort | uniq -c; echo "${#s} ${s%%0*}" | cut -c1-8
echo 'end'
''()
