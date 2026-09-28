# A process substitution writes to its own pipe, never into the command substitution it
# was expanded in: `$(nosuch <(echo leak))` is empty — nobody reads the <(…) (fuzz F89).
# (The <(…) job inherited the buffered $(…) capture as its output.)
x=$(nosuch <(echo leak) 2>/dev/null); echo "[$x]"
x=$(: <(echo leak)); echo "[$x]"
x=$(true <(echo a) <(echo b)); echo "[$x]"
x=$(cat <(echo ok)); echo "[$x]"
x=$(echo b | cat <(echo c) -); echo "[$x]"
x=$(echo a > >(cat)); echo "[$x]"
f() { : <(echo inf); }; x=$(f); echo "[$x]"
eval 'x=$(: <(echo ev))'; echo "[$x]"
x=`: <(echo bq)`; echo "[$x]"
trap 'x=$(: <(echo tr)); echo "trap [$x]"' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do x=$(: <(echo "leak $i")); printf '[%s]' "$x"; i=$((i + 1)); done | tr -d '[]' | wc -c
