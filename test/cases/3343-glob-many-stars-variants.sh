# A run of many `*`s in a pattern is one `*` (bash's matcher collapses it): in a
# pathname expansion that matches, in [[ ]], case, ${x#…}/${x%…}/${x/…}, mixed with
# `?`s (each still one character), with extglob, through a function and eval, and over and
# over. curse handed an ERE of every `*` to the regex engine: SIGSEGV on 100000, minutes
# on 20000 (stress-attack S13).
p=$(printf '%.0s*' $(seq 100000))
mkdir d && cd d && touch aa bb cab
echo ${p}a
echo "${p}b": ${p}b
[[ abcx == ${p}x ]]; echo "dbracket: $?"
[[ abcx == ${p}y ]]; echo "dbracket miss: $?"
case abcx in ${p}c${p}) echo "case: match" ;; esac
x=abcxyz
echo "strip: ${x#${p}c} ${x%x${p}} ${x/c${p}/R} ${x##${p}}."
q=$(printf '%.0s*?' $(seq 50000))
[[ abc == $q ]]; echo "star-question 50000 vs 3 chars: $?"
[[ $(printf '%.0sa' $(seq 50000)) == $q ]]; echo "star-question 50000 vs 50000 chars: $?"
shopt -s extglob
[[ abc == ${p}@(c|d) ]]; echo "extglob: $?"
echo ${p}+(b); echo ${p}@(ab|b)
f() { echo $1; [[ cab == $1 ]]; echo "function: $?"; }
f "${p}b"
eval 'echo eval: ${p}a'
n=0
for ((k = 0; k < 50; k++)); do [[ abc$k == ${p}$k ]] && n=$((n + 1)); done
echo "hot loop: $n of 50"
cd .. && rm -r d
