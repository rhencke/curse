# A $( … ) inside "…" is read exactly like an unquoted one (bash's parse_comsub runs for
# both): its body's syntax error fails the whole line before any of it runs, and a
# here-document it opens takes its body from the lines that follow.
S=${THIS_SH:-bash}
t=${TMPDIR:-/tmp}/c2422.$$; mkdir -p "$t"; cd "$t" || exit 1
e() { sed 's/^[^:]*: line \([0-9]*\): /L\1: /'; }
r() { printf '%b' "$1" > s.sh; $S s.sh 2>&1 | e; echo "st=${PIPESTATUS[0]}"; }

echo "-- a syntax error in a quoted \$( … ) body: nothing on the line runs"
r 'echo a; echo "$(if)"; echo b\necho c'
r 'echo a; echo "x$(for)y"; echo b'
r 'echo a\necho "$(echo ok)" "$(case)"\necho b'
r 'x="$(echo fine)"; echo "$x"'
echo "-- a here-document opened in a quoted \$( … )"
r 'x="$(cat <<EOF)"\nhello\nEOF\necho "[$x]"\ny=$(cat <<EOF)\nworld\nEOF\necho "[$y]"'
r 'echo "<$(cat <<-EOF)>" after\n\tone\n\ttwo\n\tEOF\necho next'
r 'printf "%s|" "$(cat <<A; cat <<B)"\n1\nA\n2\nB\necho'
echo "-- expansions inside \"…\" keep their own quoting"
echo "$(echo ")")" "$((1+2))" "${u:-"}"}" "`echo \"q\"`"
echo "$( (echo sub) )" "$(echo "$(echo "deep")")"
