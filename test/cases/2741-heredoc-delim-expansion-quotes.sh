# A here-document delimiter is "quoted" (quote removal, a literal body) only by a quote at
# the word's own level: one inside a ${…} / $(…) / `…` belongs to that construct, so
# `<<${x"y"}` is unquoted — its body expands and the delimiter is `${x"y"}` as written
# (fuzz F42). And a command whose second token is a redirection runs at that operator's
# line, however far its word runs: `nocmd <<${a⏎b}` reports line 1.
x=1
cat <<${x"y"}
a $x
${x"y"}
cat <<$(echo "q")
b $x
$(echo "q")
cat <<'E'"F"
$x
EF
cat <<${x}'z'
c $x
${x}z
cat <<`a"b"`
d $x
`a"b"`
eval 'cat <<${x"w"}
e $x
${x"w"}'
f() { cat <<${x"v"}
f $x
${x"v"}
}; f
printf 'cat <<${x"s"}\ng $x\n${x"s"}\n' > s2741.sh; . ./s2741.sh
trap 'cat <<${x"t"}
h $x
${x"t"}' USR1; kill -USR1 $$; trap - USR1
( PATH=/nonexistent; eval 'nocmd <<${a
b}
body'; echo "st $?" )
( PATH=/nonexistent; nocmd >"a
b"; rm -f "a
b" )
i=0; while [ $i -lt 150 ]; do cat <<${x"u"}
$i
${x"u"}
i=$((i + 1)); done | tail -1
eval 'cat <<${x"y"}'
rm -f s2741.sh
