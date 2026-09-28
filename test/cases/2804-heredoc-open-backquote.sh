# A here-document body with a `…` that never closes: expanding the body fails with
# "bad substitution: no closing "`" in `…" (to the end of the body; status 1, the command
# not run) — the body isn't run up to the end (leftover L6).
cat <<E
a `echo b
E
echo "st $?"
cat <<E
x `echo c` y
E
f() { cat <<E; echo "f $?"; }
p `q
r
E
f
cat <<'E'
a `b
E
eval 'cat <<E
`x
E
echo "eval $?"'
printf 'cat <<E\n`y\nE\necho "src $?"\n' > s2804.sh; . ./s2804.sh
trap 'cat <<E
`z
E
echo "trap $?"' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do cat <<E; i=$((i + 1)); done 2>&1 | sort | uniq -c
`w $i
E
echo "loop $i"
rm -f s2804.sh
