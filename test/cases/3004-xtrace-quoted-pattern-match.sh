# [[ STR == "QUOTED" ]] under set -x: the pattern compared is the operand, never the text
# traced for it (interp compared the traced form, every character backslashed); and the
# trace backslashes each character of the locale â€” in C, every byte: a high byte too
# (fuzz F92).
export LC_ALL=C
s=$'a\x81b'
set -x
[[ $s == "ab" ]]; echo $?
[[ $s != "ab" ]]; echo $?
[[ $s == "a"* ]]; echo $?
[[ ab == "ab" ]]; echo $?
set +x
f() { [[ $1 == "$2" ]]; }
i=0; while [ $i -lt 150 ]; do set -x; f "$s" "ab"; r=$?; set +x; echo $r; i=$((i + 1)); done 2>/dev/null | sort | uniq -c
