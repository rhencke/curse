# ${!…}: the text after `!` up to an operator character is the name; unless it is just
# `!` (then $! with that operator) it must start a name, a digit or one of # @ * — else
# bash's "bad substitution" (valid_brace_expansion_word), status 1. curse read `${! a}`,
# `${!.x}`, `${!"x"}` as an empty expansion, status 0 (fuzz F8).
echo "1 ${! a}"; echo "s=$?"
echo "s=$?"
echo "2 ${!%x}"; echo "s=$?"
echo "3 ${!.x}"
echo "4 ${! }"
echo "5 ${!	a}"
echo t${! x
}
echo "s=$?"
echo "7 ${!/}" "9 ${!,}" "10 ${!^x}" "11 ${!~}" "16 ${!}"
echo "8 ${!$x}"
echo "12 ${!"x"}"
echo "13 ${!'x'}"
echo "14 ${!\x}"
echo ${! a} unquoted
f() { echo "${! b}"; echo "in"; }; f
echo "fn s=$?"
eval 'echo ${!-a}'; eval 'echo ${! c}'; echo "eval s=$?"
trap 'echo ${!:x}' USR1; kill -USR1 $$; echo "trap s=$?"
n=0; for ((i = 0; i < 150; i++)); do eval 'x=${! y}' 2>/dev/null || n=$((n + 1)); done; echo "loop $n"
