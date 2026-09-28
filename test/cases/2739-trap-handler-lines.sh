# An ERR / DEBUG handler's text numbers its lines from the line the trap fires at (bash
# doesn't reset line_number for them): a command on its line k reports trapped + k-1 —
# also once the handler runs again (compiled) — and a function it defines keeps those
# lines when called later. A signal trap's handler counts from 1 (fuzz F40).
trap 'f() {

foo
}
echo "L=$LINENO"

bar' ERR
false; f
false; f
trap - ERR
trap 'g() {

foo2
}
echo "U=$LINENO"
bar2' USR1
kill -USR1 $$; g
trap - USR1
h() { false; }
trap 'echo "A=$LINENO $((LINENO))"
nope
echo "B=$LINENO $((LINENO + 0))"' ERR
h
h; echo
eval 'false'
printf 'false\n' > s2739.sh; . ./s2739.sh
i=0; while [ $i -lt 150 ]; do false; i=$((i + 1)); done > o2739 2>&1; sort o2739 | uniq -c
trap - ERR
trap 'k() {
foo3
}' ERR
h; k
rm -f s2739.sh o2739
