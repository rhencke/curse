# A loop in sourced/eval'd text whose last line opens a here-document (`do cat <<E; done
# | …`, `done <<E`): when it turns hot (100 iterations) it runs compiled from its own text
# — which must take the body lines that follow, or the body is missing (an end-of-file
# warning, empty input) from the 100th iteration on. (POSIX: dash agrees.)
cat > s2766.sh <<'X'
i=0; while [ $i -lt 150 ]; do cat <<E; i=$((i + 1)); done | sort | uniq -c
hello
E
i=0; while [ $i -lt 150 ]; do read -r l; i=$((i + 1)); done <<E; echo "$i $l"
one
E
for j in 1 2; do
	i=0; while [ $i -lt 150 ]; do cat <<A <<B; i=$((i + 1)); done | sort | uniq -c
a $j
A
b
B
done
X
. ./s2766.sh
eval "$(cat s2766.sh)"
f() { . ./s2766.sh; }; f
rm -f s2766.sh
