# A long but FLAT expression (20000 operands of one operator) is no deeper than a short one
# for bash. curse's parser/evaluator recursed per operand and failed with "stack overflow"
# (stress-attack S16).
s=$(printf '1+%.0s' $(seq 20000))
echo $((${s}1))
echo "arith: $?"
t=$(printf '1 -eq 1 && %.0s' $(seq 20000))
eval "[[ $t 1 -eq 1 ]]"; echo "dbracket: $?"
u=$(printf 'true && %.0s' $(seq 20000))
eval "$u true"; echo "and-list: $?"
# the same for the other chains: - and + mixed, * & | ^, && || in $(( )), the comma
# operator, [[ … || … ]], an || list
s=$(printf '1-2+%.0s' $(seq 10000)); echo "mixed: $((${s}1))"
s=$(printf 'a*%.0s' $(seq 5000)); a=1; echo "product: $((${s}a))"
s=$(printf '1|%.0s' $(seq 20000)); echo "bits: $((${s}2))"
s=$(printf '0&&%.0s' $(seq 20000)); echo "and: $((${s}1))"
s=$(printf '1||%.0s' $(seq 20000)); echo "or: $((${s}0))"
s=$(printf 'x+=1,%.0s' $(seq 20000)); x=0; echo "comma: $((${s}x))"
t=$(printf '1 -eq 2 || %.0s' $(seq 20000)); eval "[[ $t 1 -eq 1 ]]"; echo "dbracket or: $?"
u=$(printf 'false || %.0s' $(seq 20000)); eval "$u true"; echo "or-list: $?"
s=$(printf '1+%.0s' $(seq 20000)); for ((i = 0; i < 150; i++)); do t=$((${s}i)); done; echo "hot: $t"
