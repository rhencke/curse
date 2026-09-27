# `set -oX…`: the validity check (internal_getopt's "o;") takes the rest of the word as
# -o's name, so a bad letter there (`set -o0`) first fails when the flags are applied —
# change_flag's "invalid option" + usage, status 1, after `-o` listed the options (no name
# follows). curse looked the letter up as a flag and indexed a table with nil: a Lua
# error escaped and killed the script (fuzz F1).
set -o0 >/dev/null; echo "s=$?"
set +o0 >/dev/null; echo "s=$?"
set -oZ pipefail; echo "s=$? $SHELLOPTS"
set +o pipefail
set -o0 x; echo "s=$? $#"
set -oi >/dev/null; echo "s=$? ${-//[^i]/}"
set +oi >/dev/null; echo "s=$? ${-//[^i]/}"
set -o? >/dev/null; echo "s=$?"
set -oe >/dev/null; echo "s=$? ${-//[^e]/}"; set +e
f() { set -o0 >/dev/null; echo "f=$?"; }; f
eval 'set -o0 >/dev/null'; echo "eval=$?"
printf 'set +oq >/dev/null\necho "source=$?"\n' > set2700.sh; . ./set2700.sh; rm -f set2700.sh
trap 'set -o0 >/dev/null; echo "trap=$?"' USR1; kill -USR1 $$
r=; for ((i = 0; i < 150; i++)); do set -o0 >/dev/null 2>&1; r=$r$?; done; echo "loop ${#r} ${r//1/}."
