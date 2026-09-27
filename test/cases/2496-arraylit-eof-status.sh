# A word inside a NAME=( … ) literal that hits end of input — an unclosed quote,
# backquote, ${ or $( — is bash's parse_string_error in parse_compound_assignment:
# status 1 and a DISCARD (like the literal's own missing `)`), not a syntax error's 2.
# A non-interactive posix shell takes FORCE_EOF instead: it exits, status 1.
exec 2>&1
for body in 'x=(a "b c' 'x=(a `' "x=(a 'b" 'x=(a ${b' 'declare -a x=(a "b' 'x=(a $(echo' 'x="b c' 'x=(a'; do
	printf '%s\n' "$body" > uq.sh
	source ./uq.sh; echo "source [$body] $?"
	eval "$body"; echo "eval [$body] $?"
done
printf 'echo hi\nx=(a "b c\n' > top.sh
"$THIS_SH" top.sh; echo "top $?"
printf 'set -o posix\neval %s\necho not-reached $?\n' "'x=(a \"b'" > px.sh
"$THIS_SH" px.sh; echo "posix eval $?"
printf 'x=(a "b\n' > uq.sh
printf 'set -o posix\nsource ./uq.sh\necho not-reached $?\n' > px.sh
"$THIS_SH" px.sh; echo "posix source $?"
n=0
for i in $(seq 160); do eval 'y=(a "b' 2>/dev/null; n=$((n + $?)); done; echo "n=$n"
f() { local i s=0; for ((i=0; i<160; i++)); do source ./uq.sh 2>/dev/null; s=$((s + $?)); done; echo "s=$s"; }; f
rm -f uq.sh top.sh px.sh
