# set -v: a line read inside a $( … ) / <( … ) body isn't echoed (bash's parse_comsub reads
# it with shell_eof_token set) — its here-document lines are, and each document again,
# as stored, when the substitution ends; `…` and $(( … )) lines echo as usual. The same
# for eval'd and sourced text (leftover L19). (All of it on stderr: merged here.)
exec 2>&1
set -v
x=$(echo a
echo b)
echo "$x"
y=`echo c
echo d`
z="$(
echo e
)"
a=$((1 +
2))
c=$(cat <<E
h1
E
cat <<-F
	h2
	F
)
echo "$(echo "m
n")" $(( 1
))
eval 'x=$(echo a
echo b)
echo "$x"'
printf 'y=$(echo c\necho d)\necho "$y"\n' > s2818.sh
. ./s2818.sh
f() { z=$(echo e
echo f); echo "$z"; }
f
i=0; while [ $i -lt 150 ]; do w=$(echo $i
); i=$((i + 1)); done
echo "$w"
set +v
rm -f s2818.sh
