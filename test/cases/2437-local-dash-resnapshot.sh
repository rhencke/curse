# `local -` twice in one function call (bash 5.2.21, declare.def): each one re-saves the
# CURRENT set options, so the return restores the options as they were at the last
# `local -`, not at the first. (Patch 5.2-023 keeps the first; curse is 5.2.21.)
f() { local -; set -u; local -; }; set +u; f; echo "1: $-"; set +u
g() { local -; set -f; local -; set -u; }; set +f +u; g; echo "2: $-"; set +f +u
h() { local -; set -C; local -; set +C; }; set +C; h; echo "3: $-"; set +C
k() { local -; set -u; local x -; set -f; }; set +u +f; k; echo "4: $-"; set +u +f
m() { local -; local -; set -u; }; set +u; m; echo "5: $-"
n() { local -; set -e; local -; set +e; }; set +e; n; echo "6: $-"; set +e
shopt -s localvar_inherit
p() { local -; set -u; local -; }; set +u; p; echo "7: $-"; set +u
