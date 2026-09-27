# bash looks at the value before it expands a strip/subst/case operator's pattern (and
# replacement): #/##/%/%% leave a NULL or empty value alone, / // ^ ^^ , ,, ~ ~~ only an
# unset one — the pattern's $(…) never runs, an error in it never shows. curse expanded the
# pattern first (fuzz F21).
: ${A#$(echo 1 >&2)}
: ${A##$(echo 2 >&2)}
: ${A%$(echo 3 >&2)}
: ${A%%$(echo 4 >&2)}
: ${A/x/$(echo 5 >&2)}
: ${A/$(echo 6 >&2)/y}
: ${A//$(echo 7 >&2)}
: ${A/#$(echo 7a >&2)}
: ${A^$(echo 8 >&2)}
: ${A,,$(echo 9 >&2)}
: ${A~$(echo 9a >&2)}
E=; : ${E#$(echo 10 >&2)}
E=; : ${E/$(echo 11 >&2)}
E=; : ${E^^$(echo 11a >&2)}
E=; : ${E/x/$(echo 11b >&2)}
a=(); : ${a[@]#$(echo 12 >&2)}
a=(); : ${a[*]/$(echo 13 >&2)}
: ${@#$(echo 14 >&2)}
: ${*/x/$(echo 15 >&2)}
a=(''); : ${a[@]#$(echo 16 >&2)}
a=(''); : ${a[@]/$(echo 16a >&2)}
a=('' ''); : ${a[@]#$(echo 17 >&2)}
: ${a[5]#$(echo 18 >&2)}
a[3]=; : ${a[3]/$(echo 18a >&2)}
: "${A#$(echo 19 >&2)}"
B=A; : ${!B#$(echo 21 >&2)}
: ${A#${U?no such}}; echo "no error $?"
declare -A h; : ${h[@]#$(echo 27 >&2)}
A=xy; echo ${A#$(echo 24 >&2)x}
: "${A%$(echo 25 >&2)}"
set -- '' ''; : ${@#$(echo 26 >&2)}
x=${Z/$(echo 28 >&2)}; echo "assign $?"
f() { local L; : ${L#$(echo 29 >&2)}; echo "fn ${L/$(echo 30 >&2)}"; }; f
eval ': ${A2#$(echo 31 >&2)}'
printf ': ${A3%%$(echo 32 >&2)}\n' > s2718.sh; . ./s2718.sh; rm -f s2718.sh
trap ': ${A4/$(echo 33 >&2)}' USR1; kill -USR1 $$; trap - USR1
n=0; for ((i = 0; i < 150; i++)); do : ${A5#$((n += 1))}; : ${A#$((n += 1))}; done; echo "hot $n"
(set -u; : ${A6#$(echo 34 >&2)}); echo "nounset $?"
