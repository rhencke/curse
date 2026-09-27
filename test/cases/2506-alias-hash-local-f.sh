# alias.def: with no aliases at all, `alias -p …` (and bare `alias`) returns success at
# once — operands unseen: `alias -p a=b` defines nothing, `alias -p -- -a` isn't "not found".
# hash.def list_hashed_filename_targets: -t fails if ANY name wasn't found.
# declare.def with local_var: `local -f NAME` prints the function, -fr/-fx set its
# attributes, and a bare `local -f`/`local -F` lists this frame's locals (-F valueless).
alias -p a=b; echo "st=$?"; alias
alias -p -- -a; echo "st=$?"
alias -p -; echo "st=$?"
alias x=y; alias -p a=b; echo "st=$?"; alias -p
alias -p -- -a; echo "st=$?"
unalias -a; alias -p q=r; echo "st=$?"; alias
hash ls cat
hash -t ls nosuch; echo "st=$?"
hash -t nosuch ls; echo "st=$?"
hash -t ls cat; echo "st=$?"
g() { echo g; }
f() { local a=1 b; local -f g; echo "st=$?"; local -f nosuch; echo "st=$?"; local -F g; echo "st=$?"
	local -f; echo "--"; local -F; echo "--"; local -fr zz; echo "st=$?"; }
f
h() { local -fx g; echo "x=$?"; local -fr g; g() { echo re; }; }; h; g
k() { local -F g; hash -t nosuch ls >/dev/null 2>&1; echo "$?"; }
for ((i = 0; i < 150; i++)); do r=$(k; alias -p z=1 2>&1); done; echo "$r"
