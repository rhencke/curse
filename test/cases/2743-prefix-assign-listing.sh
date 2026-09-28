# A builtin's own prefix assignments are its temporary environment, which bash keeps apart
# from the variables it lists: `A=1 export`, `declare -p`, `set`, `compgen -v` don't show
# A (or show the variable beneath) — a named lookup (`A=1 declare -p A`) still finds it
# (fuzz F44). eval/source's are a scope of their own: listed there.
A=1 export | grep -c 'A='
A=1 export -p | grep -c ' A='
A=1 declare -x | grep -c ' A='
A=1 declare -p A
A=1 readonly | grep -c ' A='
B=0; export B; B=1 export | grep ' B='
C=0; C=1 declare | grep '^C='; C=1 set | grep '^C='; C=1 declare -p | grep ' C='
D=5 eval 'export | grep " D="'
E=1 compgen -v | grep -c '^E$'; E=1 compgen -W '$E x'
f() { A=2 export | grep -c ' A='; G=3 declare -p G; }; f
printf 'I=1 export | grep -c " I="\n' > s2743.sh; . ./s2743.sh
trap 'J=1 export | grep -c " J="' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do K=$i export | grep -c ' K='; i=$((i + 1)); done | sort | uniq -c
rm -f s2743.sh
